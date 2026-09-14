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
}
