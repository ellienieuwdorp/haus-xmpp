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
