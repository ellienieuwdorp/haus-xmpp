import Foundation
import MessageStore
import XCTest
import XMPPProtocol
@testable import OMEMO

/// The file rides the ordinary message path: sealed once, replayable as its exact envelope,
/// and decoded on the other side into a stored attachment without touching the network.
@MainActor
final class AttachmentServiceTests: XCTestCase {
    func testUploadedFileMessageSealsReplaysAndArrivesAsAttachment() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let plain = Data("photo bytes".utf8)
        let sealed = try AttachmentTransfer.seal(plain)
        var attachment = StoredAttachment(name: "beach.jpg", mediaType: "image/jpeg", size: plain.count, width: 4, height: 3,
                                          hash: Data.sha256(plain).hexString, cipherHash: Data.sha256(sealed.ciphertext).hexString,
                                          secret: try f.a.sealAttachmentSecret(account: f.alice, key: sealed.key, iv: sealed.iv), uploadState: .pending)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: f.bob, title: "Bob")
        let message = StoredMessage(id: "file-1", accountID: f.alice, chatID: f.bob, senderID: f.alice, body: "", isOutgoing: true, attachment: attachment)
        _ = try await f.aStore.enqueueOutgoing(message)
        // Not uploaded yet: preparation leaves it alone.
        let blocked = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport).messageIDs
        XCTAssertTrue(blocked.isEmpty)
        try await f.aStore.setAttachmentUploadTask(accountID: f.alice, messageID: message.id, taskID: 1, url: "https://uploads.localhost:5281/get/beach.jpg")
        try await f.aStore.markAttachmentUploaded(accountID: f.alice, messageID: message.id)
        attachment.url = "https://uploads.localhost:5281/get/beach.jpg"; attachment.uploadState = .uploaded
        let ready = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport).messageIDs
        XCTAssertEqual(ready, [message.id])
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: message.id)
        let xml = try XMPPClient.encryptedMessageXML(to: f.bob, envelope: envelope, id: message.id)
        let replayable = try await f.a.canReplay(account: f.alice, xml: xml)
        XCTAssertTrue(replayable, "An unacked file message in the journal still permits resumption")
        // Bob decodes the metadata and the sealed key; the bytes stay on the upload server.
        let incoming = XMPPEncryptedMessage(id: message.id, from: f.alice + "/phone", to: f.bob, originID: message.id, envelope: envelope)
        do { _ = try await f.b.receive(account: f.bob, message: incoming, transport: f.bTransport) } catch {}
        for device in try await f.b.overview(account: f.bob, peer: f.alice).devices where device.active { try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted) }
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport)
        let messages = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        let stored = try XCTUnwrap(messages.first)
        XCTAssertEqual(stored.body, "")
        let received = try XCTUnwrap(stored.attachment)
        XCTAssertEqual(received.name, "beach.jpg")
        XCTAssertEqual(received.url, attachment.url)
        XCTAssertEqual(received.hash, attachment.hash)
        XCTAssertEqual(received.cipherHash, attachment.cipherHash)
        XCTAssertNil(received.uploadState)
        let secret = try XCTUnwrap(try f.b.openAttachmentSecret(account: f.bob, secret: received.secret))
        XCTAssertEqual(try AttachmentTransfer.open(sealed.ciphertext, key: secret.key, iv: secret.iv,
                                                   expectedCipherHash: Data(hex: received.cipherHash!), expectedPlainHash: Data(hex: received.hash)), plain)
    }
}
