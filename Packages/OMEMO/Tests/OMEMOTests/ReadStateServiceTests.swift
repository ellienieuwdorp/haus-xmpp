import Foundation
import XCTest
import MessageStore
import XMPPProtocol
@testable import OMEMO

// XCTest's assertion autoclosures cannot await; these evaluate first, like ServiceTests' helpers.
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
private func expectTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a, file: file, line: line) }
private func expectFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(a, file: file, line: line) }
private func expectNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(a, file: file, line: line) }
private func expectNotNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotNil(a, file: file, line: line) }
private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

/// Read state across devices of one account: another device's XEP-0333 `displayed` (SCE or plain) moves this device's
/// read pointer; the same marker still reaches the peer as a receipt; the peer's marker never moves a pointer.
@MainActor
final class ReadStateServiceTests: XCTestCase {
    /// Alice has two devices; Bob writes to her and both copies arrive (the second as a received carbon).
    private struct TwoDevices {
        let f: ServiceFixture
        let secondStore: MessageStore
        let second: OMEMOService
        let bobMessageID: String
        let onFirst: StoredMessage
        let onSecond: StoredMessage
    }

    private func twoDevices() async throws -> TwoDevices {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let (secondStore, second) = try await f.addSecondAliceDevice()
        try await f.bStore.upsertChat(accountID: f.bob, chatID: f.alice, title: "Alice")
        let sent = StoredMessage(id: UUID().uuidString, accountID: f.bob, chatID: f.alice, senderID: f.bob, body: "Read me", isOutgoing: true)
        _ = try await f.bStore.enqueueOutgoing(sent)
        try await f.b.prepareQueuedMessages(account: f.bob, transport: f.bTransport)
        let envelope = try await f.b.outgoingEnvelope(account: f.bob, messageID: sent.id)
        let direct = XMPPEncryptedMessage(id: sent.id, from: f.bob + "/phone", to: f.alice + "/phone", originID: sent.id, envelope: envelope)
        expectTrue(try await f.a.receive(account: f.alice, message: direct, transport: f.aTransport))
        let carbon = XMPPEncryptedMessage(id: sent.id, from: f.bob + "/phone", to: f.alice + "/tablet", originID: sent.id, envelope: envelope, provenance: .receivedCarbon)
        expectTrue(try await second.receive(account: f.alice, message: carbon, transport: f.aTransport))
        let onFirst = try unwrap(try await f.aStore.messages(accountID: f.alice, chatID: f.bob).first)
        let onSecond = try unwrap(try await secondStore.messages(accountID: f.alice, chatID: f.bob).first)
        return TwoDevices(f: f, secondStore: secondStore, second: second, bobMessageID: sent.id, onFirst: onFirst, onSecond: onSecond)
    }

    func testOwnEncryptedDisplayedMarkerFromAnotherDeviceAdvancesThePointer() async throws {
        let t = try await twoDevices(), f = t.f
        expectEqual(try await f.aStore.unreadCounts(accountID: f.alice), [f.bob: 1])
        expectEqual(try await f.aStore.pendingNotifications(accountID: f.alice).claimed.count, 1)
        // The second device shows the message and sends its marker inside SCE, to Bob and to Alice's own devices.
        expectNotNil(try await t.second.queueReceipt(account: f.alice, chatID: f.bob, messageID: t.onSecond.id, kind: .marker))
        let prepared = try await t.second.prepareAvailableUpdates(account: f.alice, transport: f.aTransport)
        let first = f.a, bob = f.b, alice = f.alice, bobAccount = f.bob, aTransport = f.aTransport, bTransport = f.bTransport
        try await t.second.flushUpdates(account: f.alice, updateIDs: prepared.messageIDs) { update, prepared in
            guard case .encrypted(let recipient, let envelope) = prepared else { return XCTFail("a direct marker is an envelope") }
            let peerCopy = XMPPEncryptedMessage(id: update.id, from: alice + "/tablet", to: bobAccount + "/phone", originID: update.id, envelope: envelope)
            _ = try await bob.receive(account: bobAccount, message: peerCopy, transport: bTransport)
            // The session answer (a key transport, no payload) is Bob's alone.
            guard update.kind == .marker else { return }
            // Our own copy comes back as a sent carbon (or from our archive).
            let own = XMPPEncryptedMessage(id: update.id, from: alice + "/tablet", to: recipient, originID: update.id, envelope: envelope, provenance: .sentCarbon)
            let changed = try await first.receive(account: alice, message: own, transport: aTransport)
            expectTrue(changed)
        }
        let pointer = try await f.aStore.readPointer(accountID: f.alice, chatID: f.bob)
        expectEqual(pointer?.messageID, t.onFirst.id)
        expectEqual(try await f.aStore.unreadCounts(accountID: f.alice), [:])
        expectEqual(try await f.aStore.readNotificationMessageIDs(accountID: f.alice, messageIDs: [t.onFirst.id]), [t.onFirst.id])
        // For Bob it is still Alice's read receipt on his message, and it moves no pointer of his.
        let events = try await f.bStore.events(accountID: f.bob, chatID: f.alice, messageID: t.bobMessageID)
        expectEqual(events.map(\.kind), [.displayed])
        expectEqual(events.map(\.actorID), [f.alice])
        expectNil(try await f.bStore.readPointer(accountID: f.bob, chatID: f.alice))
    }

    func testOwnPlainDisplayedMarkerAdvancesAndAPeersDoesNot() async throws {
        let t = try await twoDevices(), f = t.f
        // A peer's plain marker about Alice's own message is a receipt; it never reads Alice's chat for her.
        let peerMarker = XMPPReceipt(id: "peer-marker", from: f.bob + "/phone", to: f.alice, targetID: t.bobMessageID, kind: .displayed)
        _ = try await f.a.receivePlaintextReceipt(account: f.alice, receipt: peerMarker)
        expectNil(try await f.aStore.readPointer(accountID: f.alice, chatID: f.bob))
        // A plain delivery receipt from our own other device is not a read.
        let delivered = XMPPReceipt(id: "own-received", from: f.alice + "/tablet", to: f.bob, targetID: t.bobMessageID, kind: .delivered, provenance: .sentCarbon)
        expectFalse(try await f.a.receivePlaintextReceipt(account: f.alice, receipt: delivered))
        expectNil(try await f.aStore.readPointer(accountID: f.alice, chatID: f.bob))
        // Conversations sends markers in the clear even in OMEMO chats: our own copy, from a carbon, reads the chat.
        let own = XMPPReceipt(id: "own-displayed", from: f.alice + "/tablet", to: f.bob, targetID: t.bobMessageID, kind: .displayed, provenance: .sentCarbon)
        expectTrue(try await f.a.receivePlaintextReceipt(account: f.alice, receipt: own))
        expectEqual(try await f.aStore.readPointer(accountID: f.alice, chatID: f.bob)?.messageID, t.onFirst.id)
    }

    func testDisplayedSyncItemsResolveThroughTheArchiveStanzaID() async throws {
        let t = try await twoDevices(), f = t.f
        // The first device saw Bob's message live without an archive id; our archive's copy names it.
        let envelope = try await f.b.outgoingEnvelope(account: f.bob, messageID: t.bobMessageID)
        var archived = XMPPEncryptedMessage(id: t.bobMessageID, from: f.bob + "/phone", to: f.alice, originID: t.bobMessageID, envelope: envelope, provenance: .receivedCarbon)
        archived.archiveStanzaID = "arch-1"
        expectFalse(try await f.a.receive(account: f.alice, message: archived, transport: f.aTransport))
        expectEqual(try await f.aStore.archiveStanzaID(accountID: f.alice, messageID: t.onFirst.id), "arch-1")
        // Our own chat is ignored; a known id reads the chat.
        expectFalse(try await f.a.receiveDisplayedSync(account: f.alice, items: [XMPPDisplayedItem(chat: f.alice, stanzaID: "arch-1", by: f.alice)]))
        expectTrue(try await f.a.receiveDisplayedSync(account: f.alice, items: [XMPPDisplayedItem(chat: f.bob, stanzaID: "arch-1", by: f.alice)]))
        expectEqual(try await f.aStore.readPointer(accountID: f.alice, chatID: f.bob)?.messageID, t.onFirst.id)
    }
}
