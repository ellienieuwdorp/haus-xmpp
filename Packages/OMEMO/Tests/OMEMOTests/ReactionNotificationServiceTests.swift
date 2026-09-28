import Foundation
import XCTest
import MessageStore
import XMPPProtocol
@testable import OMEMO

private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
private func expectTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a, file: file, line: line) }
private func expectFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(a, file: file, line: line) }
private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

/// Plan D8 through the real receive path: only another person's authenticated (SCE) reaction to one of Alice's own
/// messages queues a reaction alert, committed together with the ratchet.
@MainActor
final class ReactionNotificationServiceTests: XCTestCase {
    private struct Setup {
        let f: ServiceFixture
        let second: OMEMOService
        let secondStore: MessageStore
        /// Alice's own message, on her first device, and its copy on her second.
        let mine: StoredMessage
        let mineOnSecond: StoredMessage
        /// Bob's message to Alice, on her first device and on Bob's.
        let bobs: StoredMessage
        let bobsOnBob: StoredMessage
        let aliceOnBob: StoredMessage
    }

    /// Alice has two trusted devices and one message each way with Bob.
    private func setup() async throws -> Setup {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let secondStore = try f.openStore("alice-second.sqlite")
        try await secondStore.acquireTransportOwnership()
        let second = OMEMOService(store: secondStore, protection: f.protection)
        try await second.initialize(account: f.alice, transport: f.aTransport)
        try await f.a.maintainLocalAdvertisement(account: f.alice, profile: .modern, transport: f.aTransport)
        for (service, account, peer, transport) in [(second, f.alice, f.bob, f.aTransport), (second, f.alice, f.alice, f.aTransport),
                                                    (f.a, f.alice, f.bob, f.aTransport), (f.a, f.alice, f.alice, f.aTransport),
                                                    (f.b, f.bob, f.alice, f.bTransport)] {
            for device in try await service.refreshDevices(account: account, peer: peer, profile: .modern, transport: transport).devices where device.active {
                try await service.setTrust(account: account, deviceID: device.id, trust: .accepted)
            }
        }
        // Alice → Bob, with the sent carbon reaching her second device.
        let queued = try await f.queue("Lunch at noon?")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let aliceEnvelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: queued.id)
        expectTrue(try await f.b.receive(account: f.bob, message: XMPPEncryptedMessage(id: queued.id, from: f.alice + "/phone", to: f.bob + "/phone",
                                                                                       originID: queued.id, envelope: aliceEnvelope), transport: f.bTransport))
        expectTrue(try await second.receive(account: f.alice, message: XMPPEncryptedMessage(id: queued.id, from: f.alice + "/phone", to: f.bob,
            originID: queued.id, envelope: aliceEnvelope, provenance: .sentCarbon), transport: f.aTransport))
        // Bob → Alice.
        try await f.bStore.upsertChat(accountID: f.bob, chatID: f.alice, title: "Alice")
        let sent = StoredMessage(id: UUID().uuidString, accountID: f.bob, chatID: f.alice, senderID: f.bob, body: "See you there", isOutgoing: true)
        _ = try await f.bStore.enqueueOutgoing(sent)
        try await f.b.prepareQueuedMessages(account: f.bob, transport: f.bTransport)
        let bobEnvelope = try await f.b.outgoingEnvelope(account: f.bob, messageID: sent.id)
        expectTrue(try await f.a.receive(account: f.alice, message: XMPPEncryptedMessage(id: sent.id, from: f.bob + "/phone", to: f.alice + "/phone",
                                                                                         originID: sent.id, envelope: bobEnvelope), transport: f.aTransport))
        let onFirst = try await f.aStore.messages(accountID: f.alice, chatID: f.bob)
        return Setup(f: f, second: second, secondStore: secondStore,
                     mine: try unwrap(onFirst.first { $0.isOutgoing }),
                     mineOnSecond: try unwrap(try await secondStore.messages(accountID: f.alice, chatID: f.bob).first),
                     bobs: try unwrap(onFirst.first { !$0.isOutgoing }),
                     bobsOnBob: try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first { $0.isOutgoing }),
                     aliceOnBob: try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first { !$0.isOutgoing }))
    }

    /// Bob reacts; each resulting envelope reaches Alice's first device. Returns what the last receive reported.
    @discardableResult
    private func bobReacts(_ s: Setup, to messageID: String, _ reactions: [String]) async throws -> [XMPPEncryptedMessage] {
        let f = s.f
        let id = try await f.b.queueReactions(account: f.bob, chatID: f.alice, messageID: messageID, reactions: reactions)
        let prepared = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
        expectTrue(prepared.messageIDs.contains(id))
        let alice = f.alice, bob = f.bob, first = f.a, aTransport = f.aTransport
        let delivered = Delivered()
        try await f.b.flushUpdates(account: f.bob, updateIDs: prepared.messageIDs) { update, prepared in
            guard case .encrypted(_, let envelope) = prepared else { return XCTFail("a direct reaction is an envelope") }
            let message = XMPPEncryptedMessage(id: update.id, from: bob + "/phone", to: alice + "/phone", originID: update.id, envelope: envelope)
            _ = try await first.receive(account: alice, message: message, transport: aTransport)
            if update.kind == .reaction { await delivered.append(message) }
        }
        return await delivered.messages
    }

    private actor Delivered {
        var messages: [XMPPEncryptedMessage] = []
        func append(_ message: XMPPEncryptedMessage) { messages.append(message) }
    }

    private func reactionAlerts(_ s: Setup) async throws -> [ReactionNotificationCandidate] {
        try await s.f.aStore.pendingNotifications(accountID: s.f.alice).reactions
    }

    func testAuthenticatedReactionToOwnMessageCreatesExactlyOneAlertAndReplaysDoNot() async throws {
        let s = try await setup(), f = s.f
        let revision = try await f.aStore.encryptionStateRevision(accountID: f.alice)
        let messages = try await bobReacts(s, to: s.aliceOnBob.id, ["👍"])
        // The alert committed together with the ratchet.
        let after = try await f.aStore.encryptionStateRevision(accountID: f.alice)
        XCTAssertNotEqual(after, revision)
        let alerts = try await reactionAlerts(s)
        expectEqual(alerts.count, 1)
        expectEqual(alerts.first?.actor.id, f.bob)
        expectEqual(alerts.first?.target.id, s.mine.id)
        expectEqual(alerts.first?.reactions, ["👍"])
        expectEqual(alerts.first?.target.body, "Lunch at noon?")
        // Posted and claimed; the same ciphertext delivered again (a replay, an archive copy) is not new.
        let batch = try await f.aStore.pendingNotifications(accountID: f.alice)
        try await f.aStore.removeNotificationCandidates(accountID: f.alice, keys: batch.claimed)
        for message in messages { expectFalse(try await f.a.receive(account: f.alice, message: message, transport: f.aTransport)) }
        expectTrue(try await reactionAlerts(s).isEmpty)
        // A real replacement alerts again, under the same actor and target.
        try await bobReacts(s, to: s.aliceOnBob.id, ["👍", "🔥"])
        expectEqual(try await reactionAlerts(s).map(\.reactions), [["🔥"]])
    }

    func testReactionsToOthersMessagesOwnReactionsAndPlaintextReactionsNeverAlert() async throws {
        let s = try await setup(), f = s.f
        // Bob reacts to his own message: authenticated, stored, but not about Alice's message.
        try await bobReacts(s, to: s.bobsOnBob.id, ["😂"])
        expectEqual(try await f.aStore.reactions(accountID: f.alice, chatID: f.bob, messageID: s.bobs.id).map(\.reactions), [["😂"]])
        // Alice's second device reacts to her own message: authenticated as Alice, so never an alert for her.
        let id = try await s.second.queueReactions(account: f.alice, chatID: f.bob, messageID: s.mineOnSecond.id, reactions: ["🎉"])
        let prepared = try await s.second.prepareAvailableUpdates(account: f.alice, transport: f.aTransport)
        expectTrue(prepared.messageIDs.contains(id))
        let alice = f.alice, first = f.a, aTransport = f.aTransport
        let ownCopies = Delivered()
        try await s.second.flushUpdates(account: f.alice, updateIDs: prepared.messageIDs) { update, prepared in
            guard update.kind == .reaction, case .encrypted(let recipient, let envelope) = prepared else { return }
            let own = XMPPEncryptedMessage(id: update.id, from: alice + "/tablet", to: recipient, originID: update.id, envelope: envelope, provenance: .sentCarbon)
            _ = try await first.receive(account: alice, message: own, transport: aTransport)
            await ownCopies.append(own)
        }
        let ownCount = await ownCopies.messages.count
        expectEqual(ownCount, 1)
        expectEqual(try await f.aStore.reactions(accountID: f.alice, chatID: f.bob, messageID: s.mine.id).map(\.actorID), [f.alice])
        // A legacy plaintext reaction from Bob to Alice's message: server-authenticated only.
        let xml = try XMPPClient.reactionXML(to: f.alice, targetID: s.mine.wireID ?? s.mine.id, reactions: ["😮"], id: "plain-1")
        let plain = try unwrap(XMPPClient.decodeOutgoingReactionXML(xml, from: f.bob))
        expectTrue(try await f.a.receivePlaintextReaction(account: f.alice, reaction: plain))
        expectEqual(try await f.aStore.reactions(accountID: f.alice, chatID: f.bob, messageID: s.mine.id).count, 2)
        expectTrue(try await reactionAlerts(s).isEmpty)
    }
}
