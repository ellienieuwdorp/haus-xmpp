import Foundation
import Testing
import MessageStore
import XMPPProtocol
import OMEMO
@testable import MessagingCore

/// The one update drain (`OMEMOService.flushUpdates`) keeps the outbox contract of the message drain:
/// a preflight failure releases the claim before any socket use, an uncertain write is never replayed.
struct UpdateFlushTests {
    private enum Failure: Error { case socket }
    private func fixture(wire: String, _ body: (MessageStore, OMEMOService) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "update-flush-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do {
            try await store.upsertChat(accountID: "alice@localhost", chatID: "bob@localhost", title: "Bob")
            try await store.insertMessage(.init(id: "target", accountID: "alice@localhost", chatID: "bob@localhost", senderID: "bob@localhost", body: "Fixture",
                isOutgoing: false, encryptionProfile: "legacy", wireID: "wire-target"))
            _ = try await store.enqueueReaction(.init(id: "reaction", accountID: "alice@localhost", chatID: "bob@localhost", targetMessageID: "target",
                targetWireID: "wire-target", actorID: "alice@localhost", reactions: ["👍"]))
            try await store.sealQueuedUpdate(accountID: "alice@localhost", updateID: "reaction", wire: Data(wire.utf8))
            try await body(store, OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32))))
        } catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func preflightRejectionReleasesTheClaimWithoutTransport() async throws {
        // Sealed bytes that are not the update they claim to be never reach the socket.
        try await fixture(wire: "<message to='bob@localhost' id='reaction'><body>not a reaction</body></message>") { store, encryption async throws in
            await #expect(throws: OMEMOError.self) {
                try await encryption.flushUpdates(account: "alice@localhost", updateIDs: ["reaction"]) { _, _ in Issue.record("malformed wire sent") }
            }
            #expect(try await store.update(accountID: "alice@localhost", updateID: "reaction")?.transportState == .queued)
        }
    }

    @Test func uncertainWriteIsNotAutomaticallyReplayed() async throws {
        let xml = try XMPPClient.reactionXML(to: "bob@localhost", targetID: "wire-target", reactions: ["👍"], id: "reaction")
        try await fixture(wire: xml) { store, encryption async throws in
            await #expect(throws: Failure.self) {
                try await encryption.flushUpdates(account: "alice@localhost", updateIDs: ["reaction"]) { update, prepared in
                    #expect(update.kind == .reaction && prepared == .plainReaction(to: "bob@localhost", targetID: "wire-target", reactions: ["👍"]))
                    throw Failure.socket
                }
            }
            #expect(try await store.update(accountID: "alice@localhost", updateID: "reaction")?.transportState == .unconfirmed)
            try await encryption.flushUpdates(account: "alice@localhost", updateIDs: ["reaction"]) { _, _ in Issue.record("Uncertain update replayed") }
            // Only the exact sealed bytes may ever be retransmitted by stream management.
            #expect(try await encryption.canReplay(account: "alice@localhost", xml: xml))
            #expect(try await !encryption.canReplay(account: "alice@localhost", xml: xml.replacingOccurrences(of: "👍", with: "❤️")))
        }
    }
}


/// Receipts and read markers are update kinds like any other: sealed plain for a legacy peer, exact bytes on replay.
struct ReceiptFlushTests {
    private func fixture(_ body: (MessageStore, OMEMOService) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "receipt-flush-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do {
            try await store.upsertChat(accountID: "alice@localhost", chatID: "bob@localhost", title: "Bob")
            try await store.insertMessage(.init(id: "target", accountID: "alice@localhost", chatID: "bob@localhost", senderID: "bob@localhost", body: "Fixture",
                isOutgoing: false, encryptionProfile: "legacy", wireID: "wire-target"))
            try await body(store, OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32))))
        } catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func plainReceiptAndMarkerFlushAsThemselvesAndReplayOnlyAsExactBytes() async throws {
        try await fixture { store, encryption async throws in
            let receipt = try #require(try await store.enqueueReceipt(accountID: "alice@localhost", chatID: "bob@localhost", targetMessageID: "target", kind: .receipt))
            let marker = try #require(try await store.enqueueReceipt(accountID: "alice@localhost", chatID: "bob@localhost", targetMessageID: "target", kind: .marker))
            let receiptXML = try XMPPClient.receiptXML(to: "bob@localhost", targetID: "wire-target", kind: .delivered, id: receipt)
            let markerXML = try XMPPClient.receiptXML(to: "bob@localhost", targetID: "wire-target", kind: .displayed, id: marker)
            // Unsealed rows are not claimable and not replayable.
            #expect(try await !encryption.canReplay(account: "alice@localhost", xml: receiptXML))
            try await store.sealQueuedUpdate(accountID: "alice@localhost", updateID: receipt, wire: Data(receiptXML.utf8))
            try await store.sealQueuedUpdate(accountID: "alice@localhost", updateID: marker, wire: Data(markerXML.utf8))
            try await encryption.flushUpdates(account: "alice@localhost", updateIDs: [receipt, marker]) { update, prepared in
                #expect(prepared == .plainReceipt(to: "bob@localhost", targetID: "wire-target", kind: update.kind == .marker ? .displayed : .delivered))
            }
            #expect(try await store.update(accountID: "alice@localhost", updateID: marker)?.transportState == .unconfirmed)
            #expect(try await encryption.canReplay(account: "alice@localhost", xml: receiptXML))
            #expect(try await encryption.canReplay(account: "alice@localhost", xml: markerXML))
            #expect(try await !encryption.canReplay(account: "alice@localhost", xml: markerXML.replacingOccurrences(of: "wire-target", with: "other")))
            // The peer's stanza ID coming back through the archive proves server acceptance.
            let echoed = try #require(XMPPClient.decodeOutgoingReceiptXML(markerXML, from: "alice@localhost"))
            // Our own marker also reads the chat up to its target (XEP-0490 read state follows own markers too).
            #expect(try await encryption.receivePlaintextReceipt(account: "alice@localhost", receipt: echoed))
            #expect(try await store.update(accountID: "alice@localhost", updateID: marker)?.transportState == .serverAccepted)
            #expect(try await store.readPointer(accountID: "alice@localhost", chatID: "bob@localhost")?.messageID == "target")
        }
    }
}
