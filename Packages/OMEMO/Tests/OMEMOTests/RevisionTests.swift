import Foundation
import XCTest
import MessageStore
import XMPPProtocol
@testable import OMEMO

// XCTAssert autoclosures cannot await; these evaluate the awaited value first.
private func expectTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a, file: file, line: line) }
private func expectFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(a, file: file, line: line) }
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

/// Unsend (XEP-0424) and edit (XEP-0308) travel the same durable path as reactions: queued with an
/// optimistic projection, sealed once, replayable only as that exact wire, and projected on the
/// original bubble by every receiver, including our own other devices.
@MainActor
final class RevisionTests: XCTestCase {
    private let sender = "alice@localhost", recipient = "bob@localhost"

    func testRetractionAndCorrectionEnvelopesRoundTrip() throws {
        let retract = try EncryptedContent.encodeRetraction(targetWireID: "t&<1>", sender: sender, recipient: recipient, originID: "r-1", modern: true)
        let decodedRetraction = try EncryptedContent.decode(retract, sender: sender, recipient: recipient, modern: true)
        XCTAssertEqual(decodedRetraction.retraction, "t&<1>")
        XCTAssertEqual(decodedRetraction.body, "")
        XCTAssertEqual(decodedRetraction.originID, "r-1")
        let correct = try EncryptedContent.encode(body: "second thoughts", reply: nil, sender: sender, recipient: recipient, modern: true, originID: "c-1", correction: "t&<1>")
        let decodedCorrection = try EncryptedContent.decode(correct, sender: sender, recipient: recipient, modern: true)
        XCTAssertEqual(decodedCorrection.correction, "t&<1>")
        XCTAssertEqual(decodedCorrection.body, "second thoughts")
        // Legacy ciphertext has no envelope: the correction reference stays outside, and retractions go plain.
        XCTAssertEqual(try EncryptedContent.encode(body: "plain", reply: nil, sender: sender, recipient: recipient, modern: false, correction: "t"), Data("plain".utf8))
        XCTAssertThrowsError(try EncryptedContent.encodeRetraction(targetWireID: "t", sender: sender, recipient: recipient, originID: "r", modern: false)) {
            XCTAssertEqual($0 as? OMEMOError, .unsupportedMessageUpdate)
        }
    }

    /// A peer's edit replaces the original bubble's text; their unsend blanks it; neither adds a row.
    func testPeerEditAndUnsendProjectOntoTheOriginalBubbleNotASecondOne() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue("Original wording")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let original = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(original, id: outgoing.id), transport: f.bTransport))
        let target = try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first)
        XCTAssertEqual(target.wireID, outgoing.id)

        let correctionID = try await f.a.queueCorrection(account: f.alice, chatID: f.bob, messageID: outgoing.id, body: "Corrected wording")
        // Alice sees her own edit immediately, before anything is sent.
        let mine = try await f.aStore.messages(accountID: f.alice, chatID: f.bob)
        XCTAssertEqual(mine.count, 1)
        let mineEvents = try await f.aStore.events(accountID: f.alice, chatID: f.bob, messageID: outgoing.id)
        XCTAssertEqual(mine[0].applying(mineEvents).body, "Corrected wording")
        expectEqual(try await f.aStore.chats(accountID: f.alice).first?.lastMessage?.body, "Corrected wording")
        let prepared = try await f.a.prepareAvailableUpdates(account: f.alice, transport: f.aTransport)
        XCTAssertTrue(prepared.messageIDs.contains(correctionID))
        let correction = try await f.a.outgoingUpdateEnvelope(account: f.alice, updateID: correctionID)
        expectTrue(try await f.a.canReplay(account: f.alice, xml: XMPPClient.encryptedMessageXML(to: f.bob, envelope: correction, id: correctionID)))
        expectTrue(try await f.b.receive(account: f.bob, message: XMPPEncryptedMessage(id: correctionID, from: f.alice, to: f.bob, originID: correctionID, envelope: correction), transport: f.bTransport))
        let afterEdit = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        XCTAssertEqual(afterEdit.count, 1, "an edit is never a second bubble")
        let edited = afterEdit[0].applying(try await f.bStore.events(accountID: f.bob, chatID: f.alice, messageID: target.id))
        XCTAssertEqual(edited.body, "Corrected wording")
        XCTAssertTrue(edited.isEdited)
        expectEqual(try await f.bStore.chats(accountID: f.bob).first?.lastMessage?.body, "Corrected wording")

        // A retraction of the same message wins over the edit and hides the text everywhere.
        let retractionID = try await f.a.queueRetraction(account: f.alice, chatID: f.bob, messageID: outgoing.id)
        let next = try await f.a.prepareAvailableUpdates(account: f.alice, transport: f.aTransport)
        XCTAssertTrue(next.messageIDs.contains(retractionID))
        let retraction = try await f.a.outgoingUpdateEnvelope(account: f.alice, updateID: retractionID)
        expectTrue(try await f.b.receive(account: f.bob, message: XMPPEncryptedMessage(id: retractionID, from: f.alice, to: f.bob, originID: retractionID, envelope: retraction), transport: f.bTransport))
        let afterUnsend = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        XCTAssertEqual(afterUnsend.count, 1)
        let unsent = afterUnsend[0].applying(try await f.bStore.events(accountID: f.bob, chatID: f.alice, messageID: target.id))
        XCTAssertTrue(unsent.isRetracted)
        XCTAssertEqual(unsent.body, "")
        expectTrue(try await f.aStore.chats(accountID: f.alice).first?.lastMessage?.isRetracted == true)
        // Only the sender may revise: Bob cannot queue a correction of Alice's message at all.
        do { _ = try await f.b.queueCorrection(account: f.bob, chatID: f.alice, messageID: target.id, body: "hijack"); XCTFail("peer edited a foreign message") }
        catch { XCTAssertEqual(error as? OMEMOError, .unsupportedMessageUpdate) }
    }

    /// A forged `<replace>` naming someone else's message is stored as a claim but never projected.
    func testForgedCorrectionFromTheWrongActorIsNotProjected() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue("Alice's words")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        try await f.aStore.recordEvent(accountID: f.alice, event: MessageEvent(id: "forged", chatID: f.bob, actorID: f.bob, targetWireID: outgoing.id, kind: .correction,
                                                                            payload: try MessageEvent.correctionPayload("Bob's words"), updatedAt: Date()))
        let events = try await f.aStore.events(accountID: f.alice, chatID: f.bob, messageID: outgoing.id)
        XCTAssertTrue(events.isEmpty)
        let bulk = try await f.aStore.eventsForChat(accountID: f.alice, chatID: f.bob, messageIDs: [outgoing.id])
        XCTAssertTrue(bulk.isEmpty)
        let shown = try unwrap(try await f.aStore.messages(accountID: f.alice, chatID: f.bob).first).applying(events)
        XCTAssertEqual(shown.body, "Alice's words")
        XCTAssertFalse(shown.isEdited)
    }

    /// Legacy OMEMO carries the correction reference outside the ciphertext and retracts in the clear.
    func testLegacyPeersGetOuterCorrectionReferencesAndPlainRetractions() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        let outgoing = try await f.queue("Legacy original")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let original = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        // Legacy peers reference the stanza ID, which is also the origin ID this client emits.
        expectTrue(try await f.b.receive(account: f.bob, message: XMPPEncryptedMessage(id: outgoing.id, from: f.alice, to: f.bob, originID: outgoing.id, envelope: original), transport: f.bTransport))
        let target = try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first)
        XCTAssertEqual(target.wireID, outgoing.id)

        let correctionID = try await f.a.queueCorrection(account: f.alice, chatID: f.bob, messageID: outgoing.id, body: "Legacy corrected")
        let prepared = try await f.a.prepareAvailableUpdates(account: f.alice, transport: f.aTransport)
        XCTAssertTrue(prepared.messageIDs.contains(correctionID), "\(prepared.blockedChats)")
        let correction = try await f.a.outgoingUpdateEnvelope(account: f.alice, updateID: correctionID)
        XCTAssertEqual(correction.profile, .legacy)
        let bob = f.bob
        try await f.a.flushUpdates(account: f.alice, updateIDs: [correctionID]) { update, prepared in
            XCTAssertEqual(update.kind, .correction)
            XCTAssertEqual(update.targetWireID, outgoing.id)
            XCTAssertEqual(prepared, .encrypted(to: bob, envelope: correction))
        }
        let wire = try XMPPClient.encryptedMessageXML(to: f.bob, envelope: correction, id: correctionID, replaces: outgoing.id)
        expectTrue(try await f.a.canReplay(account: f.alice, xml: wire))
        expectFalse(try await f.a.canReplay(account: f.alice, xml: XMPPClient.encryptedMessageXML(to: f.bob, envelope: correction, id: correctionID, replaces: "another")))
        let inbound = try XMPPClient.decodeEncryptedMessageXML(wire.replacingOccurrences(of: "<message ", with: "<message from='\(f.alice)/phone' "))
        XCTAssertEqual(inbound.replaces, outgoing.id)
        expectTrue(try await f.b.receive(account: f.bob, message: inbound, transport: f.bTransport))
        let messages = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        XCTAssertEqual(messages.count, 1)
        let correctedEvents = try await f.bStore.events(accountID: f.bob, chatID: f.alice, messageID: target.id)
        XCTAssertEqual(messages[0].applying(correctedEvents).body, "Legacy corrected")

        let retractionID = try await f.a.queueRetraction(account: f.alice, chatID: f.bob, messageID: outgoing.id)
        let next = try await f.a.prepareAvailableUpdates(account: f.alice, transport: f.aTransport)
        XCTAssertTrue(next.messageIDs.contains(retractionID))
        let xml = String(decoding: try unwrap(try await f.aStore.updateWire(accountID: f.alice, updateID: retractionID)), as: UTF8.self)
        XCTAssertEqual(xml, try XMPPClient.retractionXML(to: f.bob, targetID: outgoing.id, id: retractionID))
        expectTrue(try await f.a.canReplay(account: f.alice, xml: xml))
        expectFalse(try await f.a.canReplay(account: f.alice, xml: xml.replacingOccurrences(of: outgoing.id, with: "other")))
        try await f.a.flushUpdates(account: f.alice, updateIDs: [retractionID]) { _, prepared in
            XCTAssertEqual(prepared, .plainRetraction(to: bob, targetID: outgoing.id))
        }
        let retraction = try unwrap(XMPPClient.decodeOutgoingRetractionXML(xml, from: f.alice))
        expectTrue(try await f.b.receivePlaintextRetraction(account: f.bob, retraction: retraction))
        let unsentEvents = try await f.bStore.events(accountID: f.bob, chatID: f.alice, messageID: target.id)
        let unsent = try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first).applying(unsentEvents)
        XCTAssertTrue(unsent.isRetracted)
        // The archive echo of our own plain retraction proves server acceptance.
        expectTrue(try await f.a.receivePlaintextRetraction(account: f.alice, retraction: XMPPRetraction(id: retractionID, from: f.alice, to: f.bob, targetID: outgoing.id, provenance: .sentCarbon)))
        expectEqual(try await f.aStore.update(accountID: f.alice, updateID: retractionID)?.transportState, .serverAccepted)
    }
}
