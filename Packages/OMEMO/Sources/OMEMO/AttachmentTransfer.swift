import CryptoKit
import Foundation
import MessageStore
import OMEMOCrypto
import XMPPProtocol

/// Bytes of a shared file cross the network only as XEP-0454 ciphertext; this is the one place
/// that turns downloaded bytes back into a file, and it refuses anything that does not
/// authenticate (GCM tag) and match the hashes the authenticated message promised.
public enum AttachmentTransfer {
    public enum Failure: Error, Equatable { case cipherHashMismatch, authenticationFailed, plainHashMismatch, tooLarge, unencrypted }
    public static let maximumBytes = 32 * 1024 * 1024

    public static func open(_ downloaded: Data, key: Data, iv: Data, expectedCipherHash: Data?, expectedPlainHash: Data?) throws -> Data {
        guard downloaded.count <= maximumBytes + 16 else { throw Failure.tooLarge }
        if let expectedCipherHash, Data.sha256(downloaded) != expectedCipherHash { throw Failure.cipherHashMismatch }
        let plaintext: Data
        do { plaintext = try AttachmentCrypto.open(EncryptedAttachment(ciphertext: downloaded, key: key, iv: iv), maximumBytes: maximumBytes) }
        catch { throw Failure.authenticationFailed }
        if let expectedPlainHash, !expectedPlainHash.isEmpty, Data.sha256(plaintext) != expectedPlainHash { throw Failure.plainHashMismatch }
        return plaintext
    }

    /// Seal a file for upload: key and IV are generated once here and must be stored before the first PUT.
    public static func seal(_ plaintext: Data) throws -> (ciphertext: Data, key: Data, iv: Data) {
        let sealed = try AttachmentCrypto.seal(plaintext, maximumBytes: maximumBytes)
        return (sealed.ciphertext, sealed.key, sealed.iv)
    }
}

extension OMEMOService {
    /// Key and IV at rest, bound to the account like the ratchet state. Empty key material
    /// (an unencrypted source) seals to a marker so the row is still non-empty.
    public nonisolated func sealAttachmentSecret(account: String, key: Data?, iv: Data?) throws -> Data {
        guard (key == nil) == (iv == nil), key.map({ $0.count == 32 }) ?? true, iv.map({ $0.count == 12 }) ?? true else { throw OMEMOError.invalidContent }
        return try protection.seal((iv ?? Data()) + (key ?? Data()), account: account)
    }

    /// Nil means the file was shared without encryption; callers may still download it.
    public nonisolated func openAttachmentSecret(account: String, secret: Data) throws -> (key: Data, iv: Data)? {
        let material = try protection.open(secret, account: account)
        if material.isEmpty { return nil }
        guard material.count == 44 else { throw OMEMOError.invalidContent }
        return (Data(material.suffix(32)), Data(material.prefix(12)))
    }

    /// The wire form of a stored attachment, for the outgoing envelope.
    nonisolated func fileSharing(for attachment: StoredAttachment, account: String) throws -> MessageContent.FileSharing {
        guard attachment.uploadState == .uploaded, let url = attachment.url, let hash = Data(hex: attachment.hash), hash.count == 32 else { throw OMEMOError.unavailable }
        let secret = try openAttachmentSecret(account: account, secret: attachment.secret)
        return MessageContent.FileSharing(name: attachment.name, mediaType: attachment.mediaType, size: attachment.size, width: attachment.width, height: attachment.height,
                                          hash: hash, url: url, key: secret?.key, iv: secret?.iv, cipherHash: attachment.cipherHash.flatMap { Data(hex: $0) })
    }

    /// The stored form of a received file; nothing is downloaded here.
    nonisolated func storedAttachment(_ file: MessageContent.FileSharing, account: String) throws -> StoredAttachment {
        StoredAttachment(name: file.name, mediaType: file.mediaType, size: file.size, width: file.width, height: file.height,
                         hash: file.hash.hexString, cipherHash: file.cipherHash?.hexString,
                         secret: try sealAttachmentSecret(account: account, key: file.key, iv: file.iv), url: file.url)
    }
}
