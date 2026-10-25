import Foundation
import MessageStore
import OMEMO
import Testing
import XMPPProtocol
@testable import MessagingCore

private func temporaryStore() throws -> (MessageStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try MessageStore(url: directory.appending(path: "messages.sqlite")), directory)
}

struct OutgoingEnqueueTests {
    @Test func aFileIsSealedOnceStagedCachedAndQueuedPendingWithoutTheLease() async throws {
        let (store, directory) = try temporaryStore()
        let files = AttachmentFiles(directory: directory, account: "alice@localhost")
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        let plaintext = Data((0..<4096).map { UInt8($0 % 251) })
        let prepared = PreparedAttachment(data: plaintext, name: "photo.jpg", mediaType: "image/jpeg", width: 64, height: 48)
        try await store.upsertChat(accountID: "alice@localhost", chatID: "bob@localhost", title: "bob@localhost")
        // No lease is taken: the extension enqueues while the app or the notification extension may own the transport.
        let message = try await OutgoingEnqueue.file(prepared, id: "share-1", account: "alice@localhost", chatID: "bob@localhost",
                                                     limit: AttachmentTransfer.maximumBytes, store: store, files: files, encryption: encryption)
        let stored = try #require(try await store.message(accountID: "alice@localhost", messageID: "share-1"))
        #expect(stored.transportState == .queued && stored.encryptionProfile == "pending" && stored.body.isEmpty)
        let attachment = try #require(stored.attachment)
        #expect(attachment.uploadState == .pending && attachment.uploadTaskID == nil && attachment.url == nil)
        #expect(attachment.hash == Data.sha256(plaintext).hexString && attachment.size == plaintext.count)
        // The staged ciphertext is the one the stored hash and key describe; the cache holds the plaintext.
        let staged = try Data(contentsOf: files.stagingURL(messageID: "share-1"))
        #expect(attachment.cipherHash == Data.sha256(staged).hexString && staged != plaintext)
        let secret = try #require(try encryption.openAttachmentSecret(account: "alice@localhost", secret: attachment.secret))
        #expect(try AttachmentTransfer.open(staged, key: secret.key, iv: secret.iv, expectedCipherHash: nil, expectedPlainHash: nil) == plaintext)
        #expect(try Data(contentsOf: files.cacheURL(attachment, messageID: "share-1")) == plaintext)
        #expect(message.id == "share-1")
        // Waiting for its PUT, it is not claimable, and the text queued after it in the chat waits behind it.
        try await OutgoingEnqueue.text("A caption", id: "share-2", account: "alice@localhost", chatID: "bob@localhost", store: store)
        #expect(try await store.queuedOutgoing(accountID: "alice@localhost").isEmpty)
        #expect(try await store.attachmentsAwaitingUpload(accountID: "alice@localhost").map(\.id) == ["share-1"])
        // A PUT outside the app's session records its URL and state in one write; then both are claimable, in order.
        try await store.recordAttachmentUploaded(accountID: "alice@localhost", messageID: "share-1", url: "https://upload.localhost/a")
        #expect(try await store.queuedOutgoing(accountID: "alice@localhost").map(\.id) == ["share-1", "share-2"])
        #expect(try await store.message(accountID: "alice@localhost", messageID: "share-1")?.attachment?.uploadState == .uploaded)
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func refusesWhatTheComposerRefuses() async throws {
        let (store, directory) = try temporaryStore()
        let files = AttachmentFiles(directory: directory, account: "alice@localhost")
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        let prepared = PreparedAttachment(data: Data(count: 2048), name: "file.bin", mediaType: "application/octet-stream", width: nil, height: nil)
        await #expect(throws: OutgoingEnqueue.Failure.fileTooLarge) {
            try await OutgoingEnqueue.file(prepared, account: "alice@localhost", chatID: "bob@localhost", limit: 1024,
                                           store: store, files: files, encryption: encryption)
        }
        await #expect(throws: OutgoingEnqueue.Failure.emptyText) {
            try await OutgoingEnqueue.text(" \n", account: "alice@localhost", chatID: "bob@localhost", store: store)
        }
        await #expect(throws: OutgoingEnqueue.Failure.textTooLong) {
            try await OutgoingEnqueue.text(String(repeating: "a", count: OutgoingEnqueue.maximumTextBytes + 1), account: "alice@localhost",
                                           chatID: "bob@localhost", store: store)
        }
        await #expect(throws: OutgoingEnqueue.Failure.invalidRecipient) {
            try await OutgoingEnqueue.text("Hi", account: "alice@localhost", chatID: "not an address", store: store)
        }
        // Nothing was written: no row, no staged file.
        #expect(try await store.queuedOutgoing(accountID: "alice@localhost").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.appending(path: "staging").path).isEmpty)
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }
}
