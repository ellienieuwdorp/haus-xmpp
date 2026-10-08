import Foundation
import MessageStore
import XCTest
import XMPPProtocol
@testable import OMEMO

final class AttachmentTests: XCTestCase {
    private let sender = "alice@localhost", recipient = "bob@localhost"
    private let plain = Data("a small photo".utf8)

    private func file() throws -> (MessageContent.FileSharing, Data) {
        let sealed = try AttachmentTransfer.seal(plain)
        let sharing = MessageContent.FileSharing(name: "photo.jpg", mediaType: "image/jpeg", size: plain.count, width: 4, height: 3, hash: Data.sha256(plain),
                                                 url: "https://uploads.localhost:5281/x/photo.jpg", key: sealed.key, iv: sealed.iv, cipherHash: Data.sha256(sealed.ciphertext))
        return (sharing, sealed.ciphertext)
    }

    func testLegacyBodyUsesAESGCMLinkAndParsesBack() throws {
        let (sharing, _) = try file()
        let data = try EncryptedContent.encode(body: "caption", reply: nil, sender: sender, recipient: recipient, modern: false, fileSharing: sharing)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("caption\naesgcm://uploads.localhost:5281/x/photo.jpg#"))
        let decoded = try EncryptedContent.decode(data, sender: sender, recipient: recipient, modern: false)
        XCTAssertEqual(decoded.body, "caption")
        XCTAssertEqual(decoded.fileSharing?.key, sharing.key)
        XCTAssertEqual(decoded.fileSharing?.iv, sharing.iv)
        XCTAssertEqual(decoded.fileSharing?.url, sharing.url)
        XCTAssertEqual(decoded.fileSharing?.hash, Data(), "Legacy links carry no plaintext hash")
        var unencrypted = sharing; unencrypted.key = nil; unencrypted.iv = nil; unencrypted.cipherHash = nil
        XCTAssertThrowsError(try EncryptedContent.encode(body: "", reply: nil, sender: sender, recipient: recipient, modern: false, fileSharing: unencrypted))
        XCTAssertNil(try EncryptedContent.decode(Data("just text".utf8), sender: sender, recipient: recipient, modern: false).fileSharing)
    }

    /// The SCE `<content>` children of a modern payload, for checking what rides inside the envelope.
    private func envelopeContent(_ data: Data) throws -> XMPPProtocol.XMLNode {
        let root = try XMPPProtocol.XMLNode.parse(standalone: data)
        return try XCTUnwrap(root.child("content", namespace: "urn:xmpp:sce:1"))
    }

    func testModernReplyWithOnlyAFileCarriesTheReferenceInsideTheEnvelopeAndNoQuote() throws {
        let (sharing, _) = try file()
        let reply = MessageReply(messageID: "local-photo", senderID: sender, body: "Photo", wireID: "wire-photo")
        let data = try EncryptedContent.encode(body: "", reply: reply, sender: sender, recipient: recipient, modern: true, originID: "m1", fileSharing: sharing)
        let content = try envelopeContent(data)
        let reference = try XCTUnwrap(content.child("reply", namespace: "urn:xmpp:reply:0"))
        XCTAssertEqual(reference.attributes["id"], "wire-photo")
        XCTAssertEqual(reference.attributes["to"], sender)
        // No quote: the body stays exactly the link (MessageContent's tests own the element grammar).
        let body = try XCTUnwrap(content.child("body", namespace: "jabber:client")?.text)
        XCTAssertTrue(body.hasPrefix("aesgcm://uploads.localhost:5281/x/photo.jpg#"))
        XCTAssertFalse(body.contains("Photo"))
        let decoded = try EncryptedContent.decode(data, sender: sender, recipient: recipient, modern: true)
        XCTAssertEqual(decoded.body, "")
        XCTAssertEqual(decoded.fileSharing?.url, sharing.url)
    }

    func testFileReplyThatCannotCarryAReferenceSendsTheBareFile() throws {
        let (sharing, _) = try file()
        let own = MessageReply(messageID: "local-photo", senderID: sender, body: "Photo", wireID: "wire-photo")
        // Legacy has no envelope: no quote before the link and no reference anywhere in the payload.
        let legacy = String(decoding: try EncryptedContent.encode(body: "", reply: own, sender: sender, recipient: recipient, modern: false, fileSharing: sharing), as: UTF8.self)
        XCTAssertTrue(legacy.hasPrefix("aesgcm://uploads.localhost:5281/x/photo.jpg#"))
        XCTAssertFalse(legacy.contains("Photo"))
        XCTAssertFalse(legacy.contains("wire-photo"))
        // A received message has no wire ID to reference, so the file goes alone.
        let received = MessageReply(messageID: "local-in", senderID: recipient, body: "Photo")
        let content = try envelopeContent(try EncryptedContent.encode(body: "", reply: received, sender: sender, recipient: recipient, modern: true, fileSharing: sharing))
        XCTAssertNil(content.child("reply", namespace: "urn:xmpp:reply:0"))
        XCTAssertFalse(try XCTUnwrap(content.child("body", namespace: "jabber:client")?.text).contains("Photo"))
    }

    func testDownloadedBytesMustAuthenticateAndMatchBothHashes() throws {
        let (sharing, ciphertext) = try file()
        XCTAssertEqual(try AttachmentTransfer.open(ciphertext, key: sharing.key!, iv: sharing.iv!, expectedCipherHash: sharing.cipherHash, expectedPlainHash: sharing.hash), plain)
        var tampered = ciphertext; tampered[0] ^= 1
        XCTAssertThrowsError(try AttachmentTransfer.open(tampered, key: sharing.key!, iv: sharing.iv!, expectedCipherHash: nil, expectedPlainHash: nil)) {
            XCTAssertEqual($0 as? AttachmentTransfer.Failure, .authenticationFailed)
        }
        XCTAssertThrowsError(try AttachmentTransfer.open(ciphertext, key: sharing.key!, iv: sharing.iv!, expectedCipherHash: nil, expectedPlainHash: Data.sha256(Data("other".utf8)))) {
            XCTAssertEqual($0 as? AttachmentTransfer.Failure, .plainHashMismatch)
        }
        XCTAssertThrowsError(try AttachmentTransfer.open(ciphertext, key: sharing.key!, iv: sharing.iv!, expectedCipherHash: Data(repeating: 0, count: 32), expectedPlainHash: nil)) {
            XCTAssertEqual($0 as? AttachmentTransfer.Failure, .cipherHashMismatch)
        }
    }

    func testAttachmentSecretIsBoundToTheAccount() throws {
        let (sharing, _) = try file()
        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "attachment-\(UUID()).sqlite"))
        let service = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 5, count: 32)))
        let stored = try service.storedAttachment(sharing, account: sender)
        XCTAssertEqual(stored.hash, sharing.hash.hexString)
        XCTAssertEqual(stored.url, sharing.url)
        XCTAssertNil(stored.uploadState)
        let opened = try XCTUnwrap(try service.openAttachmentSecret(account: sender, secret: stored.secret))
        XCTAssertEqual(opened.key, sharing.key)
        XCTAssertEqual(opened.iv, sharing.iv)
        XCTAssertThrowsError(try service.openAttachmentSecret(account: recipient, secret: stored.secret))
        XCTAssertNil(try service.openAttachmentSecret(account: sender, secret: try service.sealAttachmentSecret(account: sender, key: nil, iv: nil)))
        var uploaded = stored; uploaded.uploadState = .uploaded
        XCTAssertEqual(try service.fileSharing(for: uploaded, account: sender), sharing)
        XCTAssertThrowsError(try service.fileSharing(for: stored, account: sender), "A file that has not finished uploading has no wire form")
    }
}
