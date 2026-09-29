import Foundation
import Testing
import MessageStore
import XMPPProtocol
import OMEMO
@testable import MessagingCore

/// Retractions and corrections obey the same resumption and inbound rules as reactions.
struct RevisionResumptionTests {
    private let account = "alice@localhost", peer = "bob@localhost"

    private func fixture() async throws -> (MessageStore, OMEMOService, StreamPersistence) {
        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "revision-\(UUID()).sqlite"))
        try await store.acquireTransportOwnership()
        try await store.upsertChat(accountID: account, chatID: peer, title: "Bob")
        try await store.insertMessage(.init(id: "mine", accountID: account, chatID: peer, senderID: account, body: "mine", isOutgoing: true, encryptionProfile: "legacy", wireID: "mine"))
        try await store.insertMessage(.init(id: "theirs", accountID: account, chatID: peer, senderID: peer, body: "theirs", encryptionProfile: "legacy", wireID: "w"))
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        return (store, encryption, StreamPersistence(store: store, accountID: account, encryption: encryption))
    }

    private func snapshot(journal: [XMPPStreamJournalEntry]) -> XMPPStreamManagementSnapshot {
        .init(revision: 1, accountID: account, fullJID: account + "/device", streamID: "opaque",
              expiresAt: nil, inboundHandled: 0, outboundSent: UInt64(journal.count), outboundAcknowledged: 0, journal: journal)
    }

    /// A queued correction's envelope is sealed only when prepared: until then nothing may be replayed under its ID.
    @Test func anUnsealedCorrectionNeverResumes() async throws {
        let (store, _, adapter) = try await fixture()
        _ = try await store.enqueueMessageUpdate(accountID: account, id: "u2", kind: .correction, chatID: peer, targetMessageID: "mine", body: "better")
        let envelope = XMPPOMEMOEnvelope(profile: .legacy, senderDeviceID: 1, keys: [.init(deviceID: 2, keyExchange: false, data: Data([1]))], iv: Data(repeating: 0, count: 12), payload: Data([2]))
        let xml = try XMPPClient.encryptedMessageXML(to: peer, envelope: envelope, id: "u2", replaces: "mine")
        // A well-formed correction of ours, so only the missing seal can refuse it.
        #expect(try XMPPClient.decodeOutgoingEncryptedMessageXML(xml, from: account).replaces == "mine")
        #expect(try await !adapter.permitsResumption(snapshot(journal: [XMPPStreamJournalEntry(sequence: 1, xml: xml, messageID: "u2")])))
    }

    @Test func inboundPlainRetractionProjectsOnlyForTheSender() async throws {
        let (store, encryption, _) = try await fixture()
        let processor = InboundProcessor(encryption: encryption, client: XMPPClient(labCertificateAuthority: nil), account: account)
        #expect(try await processor.process(.retraction(XMPPRetraction(id: "x1", from: peer + "/phone", to: account, targetID: "w"))) == .stored)
        #expect(try await processor.process(.retraction(XMPPRetraction(id: "x1", from: peer + "/phone", to: account, targetID: "w"))) == .stored)
        let theirs = try #require(try await store.message(accountID: account, messageID: "theirs"))
        #expect(theirs.applying(try await store.events(accountID: account, chatID: peer, messageID: "theirs")).isRetracted)
        // The peer cannot unsend our message: the claim is kept but never shown.
        #expect(try await processor.process(.retraction(XMPPRetraction(id: "x2", from: peer + "/phone", to: account, targetID: "mine"))) == .stored)
        #expect(try await store.events(accountID: account, chatID: peer, messageID: "mine").isEmpty)
        let projected = try await store.eventsForChat(accountID: account, chatID: peer, messageIDs: ["mine", "theirs"])
        #expect(projected["mine"] == nil && projected["theirs"]?.map(\.kind) == [.retraction])
    }
}
