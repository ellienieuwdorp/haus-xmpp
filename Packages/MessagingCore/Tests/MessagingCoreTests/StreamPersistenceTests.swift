import Foundation
import Testing
import MessageStore
import XMPPProtocol
import OMEMO
@testable import MessagingCore

struct StreamPersistenceTests {
    private func fixture() async throws -> (MessageStore, StreamPersistence) {
        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "stream-adapter-\(UUID()).sqlite"))
        try await store.acquireTransportOwnership()
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        return (store, StreamPersistence(store: store, accountID: "alice@localhost", encryption: encryption))
    }

    private func snapshot(revision: Int = 1, account: String = "alice@localhost", journal: [XMPPStreamJournalEntry] = []) -> XMPPStreamManagementSnapshot {
        .init(revision: revision, accountID: account, fullJID: account + "/device", streamID: "opaque",
              expiresAt: nil, inboundHandled: 0, outboundSent: UInt64(journal.count), outboundAcknowledged: 0, journal: journal)
    }

    @Test func snapshotAccountAndRevisionAreFenced() async throws {
        let (store, adapter) = try await fixture()
        try await adapter.save(snapshot(), expectedRevision: nil, acknowledgedMessageIDs: [])
        #expect(try await adapter.load() == snapshot())
        await #expect(throws: XMPPStreamManagementError.self) {
            try await adapter.save(snapshot(revision: 2, account: "mallory@localhost"), expectedRevision: 1, acknowledgedMessageIDs: [])
        }
        await #expect(throws: MessageStoreError.self) {
            try await adapter.save(snapshot(), expectedRevision: nil, acknowledgedMessageIDs: [])
        }
        #expect(try await store.streamManagementState(accountID: "mallory@localhost") == nil)
        #expect(try await adapter.load()?.revision == 1)
    }

    @Test func corruptInnerRevisionFailsClosed() async throws {
        let (store, adapter) = try await fixture()
        _ = try await store.saveStreamManagement(accountID: "alice@localhost", expectedRevision: nil,
                                                 data: JSONEncoder().encode(snapshot(revision: 90)))
        await #expect(throws: XMPPStreamManagementError.self) { _ = try await adapter.load() }
    }

    @Test func plaintextAndUnknownCiphertextNeverResume() async throws {
        let (_, adapter) = try await fixture()
        let plain = XMPPStreamJournalEntry(sequence: 1, xml: "<message to='bob@localhost' id='x'><body>clear</body></message>", messageID: "x")
        #expect(try await !adapter.permitsResumption(snapshot(journal: [plain])))
        let envelope = XMPPOMEMOEnvelope(profile: .legacy, senderDeviceID: 1,
                                         keys: [.init(deviceID: 2, keyExchange: false, data: Data([1]))],
                                         iv: Data(repeating: 0, count: 12), payload: Data([2]))
        let wire = try XMPPClient.encryptedMessageXML(to: "bob@localhost", envelope: envelope, id: "missing")
        #expect(try await !adapter.permitsResumption(snapshot(journal: [.init(sequence: 1, xml: wire, messageID: "missing")])))
        #expect(try await !adapter.permitsResumption(snapshot(account: "mallory@localhost")))
    }

    @Test func journaledUpdatesResumeOnlyAsTheirExactSealedWire() async throws {
        let (store, adapter) = try await fixture()
        try await store.upsertChat(accountID: "alice@localhost", chatID: "bob@localhost", title: "Bob")
        try await store.insertMessage(.init(id: "target", accountID: "alice@localhost", chatID: "bob@localhost", senderID: "bob@localhost", body: "x",
                                            encryptionProfile: "legacy", wireID: "wire-target"))
        _ = try await store.enqueueReaction(.init(id: "r1", accountID: "alice@localhost", chatID: "bob@localhost", targetMessageID: "target",
                                                  targetWireID: "wire-target", actorID: "alice@localhost", reactions: ["👍"]))
        let xml = try XMPPClient.reactionXML(to: "bob@localhost", targetID: "wire-target", reactions: ["👍"], id: "r1")
        // Unsealed: nothing may be replayed under this ID yet.
        let entry = XMPPStreamJournalEntry(sequence: 1, xml: xml, messageID: "r1")
        #expect(try await !adapter.permitsResumption(snapshot(journal: [entry])))
        try await store.sealQueuedUpdate(accountID: "alice@localhost", updateID: "r1", wire: Data(xml.utf8))
        #expect(try await adapter.permitsResumption(snapshot(journal: [entry])))
        // One drifted entry anywhere in the journal refuses the whole resumption.
        let drifted = XMPPStreamJournalEntry(sequence: 2, xml: xml.replacingOccurrences(of: "👍", with: "❤️"), messageID: "r1")
        #expect(try await !adapter.permitsResumption(snapshot(journal: [entry, drifted])))
        // IQ entries keep no bytes, are never replayed and never consulted.
        let iq = XMPPStreamJournalEntry(sequence: 2, kind: .iq, xml: nil, messageID: nil)
        #expect(try await adapter.permitsResumption(snapshot(journal: [entry, iq])))
    }

    @Test func iqEntriesWithoutBytesRoundTripThroughTheStore() async throws {
        let (_, adapter) = try await fixture()
        let journaled = snapshot(journal: [.init(sequence: 1, kind: .message, xml: "<message id='m'/>", messageID: "m"),
                                           .init(sequence: 2, kind: .iq, xml: nil, messageID: nil),
                                           .init(sequence: 3, kind: .presence, xml: "<presence/>", messageID: nil)])
        try await adapter.save(journaled, expectedRevision: nil, acknowledgedMessageIDs: [])
        #expect(try await adapter.load() == journaled)
    }

    @Test func unacknowledgedReceiptAndMarkerInTheJournalStillPermitResumption() async throws {
        let (store, adapter) = try await fixture()
        try await store.upsertChat(accountID: "alice@localhost", chatID: "bob@localhost", title: "Bob")
        try await store.insertMessage(.init(id: "target", accountID: "alice@localhost", chatID: "bob@localhost", senderID: "bob@localhost", body: "x",
                                            encryptionProfile: "legacy", wireID: "wire-target"))
        let receipt = try #require(try await store.enqueueReceipt(accountID: "alice@localhost", chatID: "bob@localhost", targetMessageID: "target", kind: .receipt))
        let marker = try #require(try await store.enqueueReceipt(accountID: "alice@localhost", chatID: "bob@localhost", targetMessageID: "target", kind: .marker))
        let receiptXML = try XMPPClient.receiptXML(to: "bob@localhost", targetID: "wire-target", kind: .delivered, id: receipt)
        let markerXML = try XMPPClient.receiptXML(to: "bob@localhost", targetID: "wire-target", kind: .displayed, id: marker)
        let journal = [XMPPStreamJournalEntry(sequence: 1, xml: receiptXML, messageID: receipt), XMPPStreamJournalEntry(sequence: 2, xml: markerXML, messageID: marker)]
        #expect(try await !adapter.permitsResumption(snapshot(journal: journal)))
        try await store.sealQueuedUpdate(accountID: "alice@localhost", updateID: receipt, wire: Data(receiptXML.utf8))
        try await store.sealQueuedUpdate(accountID: "alice@localhost", updateID: marker, wire: Data(markerXML.utf8))
        #expect(try await adapter.permitsResumption(snapshot(journal: journal)))
        let swapped = XMPPStreamJournalEntry(sequence: 2, xml: receiptXML.replacingOccurrences(of: receipt, with: marker), messageID: marker)
        #expect(try await !adapter.permitsResumption(snapshot(journal: [journal[0], swapped])))
    }
}
