import Foundation
import Testing
import MessageStore
@testable import XMPPProtocol
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

    /// A session saved while the account kept its typed capitals loads, resumes and saves again once the account is
    /// named in normal form; the address migration already moved its row to the normal key.
    @Test func sessionSavedUnderTheTypedSpellingStillBelongsToTheAccount() async throws {
        let (store, adapter) = try await fixture()
        let typed = snapshot(account: "Alice@LocalHost")
        _ = try await store.saveStreamManagement(accountID: "alice@localhost", expectedRevision: nil, data: JSONEncoder().encode(typed))
        #expect(try await adapter.load() == typed)
        #expect(try await adapter.permitsResumption(typed))
        try await adapter.save(snapshot(revision: 2, account: "Alice@LocalHost"), expectedRevision: 1, acknowledgedMessageIDs: [])
        #expect(try await adapter.load()?.revision == 2)
    }

    /// A saved session that cannot be decoded (corrupt bytes, an inner revision that disagrees with its row, or contents
    /// naming another account under this account's key) is never resumed, and the fresh bind replaces it. Failing the
    /// connect instead repeated on every connect.
    @Test func unreadableSessionBindsFreshAndIsReplaced() async throws {
        for data in [Data("{".utf8), try JSONEncoder().encode(snapshot(revision: 90)),
                     try JSONEncoder().encode(snapshot(account: "mallory@localhost"))] {
            let (store, adapter) = try await fixture()
            _ = try await store.saveStreamManagement(accountID: "alice@localhost", expectedRevision: nil, data: data)
            await #expect(throws: XMPPStreamManagementUnreadable(revision: 1)) { _ = try await adapter.load() }
            let sm = StreamManagement(adapter)
            #expect(try await sm.restore(accountID: "alice@localhost") == nil)
            try await sm.enable(accountID: "alice@localhost", fullJID: "alice@localhost/device", streamID: "fresh")
            #expect(try await adapter.load()?.streamID == "fresh")
        }
    }

    /// A chat state is a hint, not a message we must deliver: it never asks the replay policy (which can vouch only
    /// for durable rows) and is never replayed. One typing notification used to turn the next connect into a bind.
    @Test func chatStatesNeverRefuseResumption() async throws {
        let (store, adapter) = try await fixture()
        let state = try XMPPChatState.xml(.composing, to: "bob@localhost", id: "typing")
        let sm = StreamManagement(adapter)
        _ = try await sm.restore(accountID: "alice@localhost")
        try await sm.enable(accountID: "alice@localhost", fullJID: "alice@localhost/device", streamID: "opaque")
        try await sm.record(state)
        #expect(try await StreamManagement(adapter).restore(accountID: "alice@localhost") != nil)

        // A session saved before hint slots journaled the same state as a message with an ID.
        let current = try #require(try await store.streamManagementState(accountID: "alice@localhost")).revision
        let legacy = snapshot(revision: current + 1, journal: [.init(sequence: 1, xml: state, messageID: "typing")])
        _ = try await store.saveStreamManagement(accountID: "alice@localhost", expectedRevision: current, data: JSONEncoder().encode(legacy))
        let resumed = StreamManagement(adapter)
        #expect(try await resumed.restore(accountID: "alice@localhost") != nil)
        #expect(try await resumed.acknowledge(0, resumed: true).isEmpty)
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
}
