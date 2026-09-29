import Foundation
import Testing
import MessageStore
import XMPPProtocol
import OMEMO
@testable import MessagingCore

/// Retractions obey the same inbound rules as reactions.
struct RevisionResumptionTests {
    private let account = "alice@localhost", peer = "bob@localhost"

    private func fixture() async throws -> (MessageStore, OMEMOService) {
        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "revision-\(UUID()).sqlite"))
        try await store.acquireTransportOwnership()
        try await store.upsertChat(accountID: account, chatID: peer, title: "Bob")
        try await store.insertMessage(.init(id: "mine", accountID: account, chatID: peer, senderID: account, body: "mine", isOutgoing: true, encryptionProfile: "legacy", wireID: "mine"))
        try await store.insertMessage(.init(id: "theirs", accountID: account, chatID: peer, senderID: peer, body: "theirs", encryptionProfile: "legacy", wireID: "w"))
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        return (store, encryption)
    }

    @Test func inboundPlainRetractionProjectsOnlyForTheSender() async throws {
        let (store, encryption) = try await fixture()
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
