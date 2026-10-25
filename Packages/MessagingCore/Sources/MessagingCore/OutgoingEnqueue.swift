import CryptoKit
import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// Where shared files live on disk. Plaintext bytes are keyed by their hash in an account-scoped
/// cache; ciphertext waiting for a PUT is staged per message. Both are under the shared container
/// with complete-until-first-unlock protection, never inside SQLite.
public struct AttachmentFiles: Sendable {
    public let root: URL

    public init(directory: URL, account: String) {
        root = Self.root(directory: directory, account: account)
        for sub in ["cache", "staging"] {
            try? FileManager.default.createDirectory(at: root.appending(path: sub), withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
    }

    public static func root(directory: URL, account: String) -> URL {
        let scope = SHA256.hash(data: Data(account.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "attachments/\(scope)", directoryHint: .isDirectory)
    }

    public func cached(_ attachment: StoredAttachment, messageID: String) -> URL? {
        let url = cacheURL(attachment, messageID: messageID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Legacy links carry no hash, so the message ID keys the cache instead.
    public func cacheURL(_ attachment: StoredAttachment, messageID: String) -> URL {
        let key = attachment.hash.isEmpty ? "m-" + messageID : attachment.hash
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return root.appending(path: "cache/" + key + (ext.isEmpty ? "" : "." + ext))
    }

    public func stagingURL(messageID: String) -> URL { root.appending(path: "staging/\(messageID).enc") }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A file chosen for sending, already reduced to what we are willing to upload. `data` may be memory-mapped from a
/// file the preparer owns, so a large video is not copied onto the heap before it is sealed.
public struct PreparedAttachment: Sendable {
    public let data: Data
    public let name: String
    public let mediaType: String
    public let width: Int?
    public let height: Int?

    public init(data: Data, name: String, mediaType: String, width: Int?, height: Int?) {
        self.data = data; self.name = name; self.mediaType = mediaType; self.width = width; self.height = height
    }
}

/// The composer's durable enqueue, shared by the app and the share extension. Nothing here needs the transport lease:
/// each message is one `enqueueOutgoing` transaction, and the drain seals and sends it later under the lease. Text is
/// queued unsealed; a file is sealed once with XEP-0454 here, and its ciphertext and key are stored before the row, so
/// every later attempt sends the same bytes and nothing is regenerated.
public enum OutgoingEnqueue {
    /// Bodies longer than this are refused, as by the composer.
    public static let maximumTextBytes = 16_384

    public enum Failure: Error, Equatable, Sendable { case emptyText, textTooLong, invalidRecipient, fileTooLarge }

    /// Seals the file once, stores everything the send will ever need, then queues the message. It stays unsendable
    /// until its PUT succeeds. Never with a caption: Conversations shows a file only when the body is exactly its link,
    /// so a caption goes as its own message after the files (`text`).
    @discardableResult
    public static func file(_ prepared: PreparedAttachment, id: String = UUID().uuidString, account: String, chatID: String,
                            reply: MessageReply? = nil, limit: Int, store: MessageStore, files: AttachmentFiles,
                            encryption: OMEMOService) async throws -> StoredMessage {
        guard prepared.data.count <= min(limit, AttachmentTransfer.maximumBytes) else { throw Failure.fileTooLarge }
        let sealed = try AttachmentTransfer.seal(prepared.data)
        let attachment = StoredAttachment(name: prepared.name, mediaType: prepared.mediaType, size: prepared.data.count,
                                          width: prepared.width, height: prepared.height, hash: Data.sha256(prepared.data).hexString,
                                          cipherHash: Data.sha256(sealed.ciphertext).hexString,
                                          secret: try encryption.sealAttachmentSecret(account: account, key: sealed.key, iv: sealed.iv),
                                          uploadState: .pending)
        try files.write(sealed.ciphertext, to: files.stagingURL(messageID: id))
        try files.write(prepared.data, to: files.cacheURL(attachment, messageID: id))
        let message = StoredMessage(id: id, accountID: account, chatID: chatID, senderID: account, body: "", isOutgoing: true,
                                    reply: reply, encryptionProfile: "pending", attachment: attachment)
        try await store.enqueueOutgoing(message)
        return message
    }

    /// One queued, still unencrypted text row that only the drain seals. `linkPreview` is the composer's frozen own
    /// preview, stored so every retry seals the same bytes.
    @discardableResult
    public static func text(_ body: String, id: String = UUID().uuidString, account: String, chatID: String,
                            reply: MessageReply? = nil, linkPreview: StoredLinkPreview? = nil, store: MessageStore) async throws -> StoredMessage {
        let message = try textMessage(body, id: id, account: account, chatID: chatID, reply: reply, linkPreview: linkPreview)
        try await store.enqueueOutgoing(message)
        return message
    }

    /// The row `text` queues, validated against what the wire accepts, so a refused body is never stored.
    public static func textMessage(_ body: String, id: String, account: String, chatID: String, reply: MessageReply? = nil,
                                   linkPreview: StoredLinkPreview? = nil) throws -> StoredMessage {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyText }
        guard body.utf8.count <= maximumTextBytes else { throw Failure.textTooLong }
        let wireReply = reply.map { XMPPReply(id: $0.wireID, to: $0.senderID, body: $0.body) }
        guard XMPPClient.messageProblem(to: chatID, body: body, id: id, reply: wireReply) == nil else { throw Failure.invalidRecipient }
        return StoredMessage(id: id, accountID: account, chatID: chatID, senderID: account, body: body, isOutgoing: true,
                             reply: reply, encryptionProfile: "pending", linkPreview: linkPreview)
    }
}
