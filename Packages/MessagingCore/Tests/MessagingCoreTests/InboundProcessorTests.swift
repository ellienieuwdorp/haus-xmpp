import Foundation
import Testing
import MessageStore
import XMPPProtocol
import OMEMO
@testable import MessagingCore

struct InboundProcessorTests {
    private let account = "alice@localhost", peer = "bob@localhost"

    private func fixture() async throws -> (MessageStore, InboundProcessor) {
        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "inbound-\(UUID()).sqlite"))
        try await store.acquireTransportOwnership()
        try await store.upsertChat(accountID: account, chatID: peer, title: "Bob")
        // A legacy peer message keeps its stanza ID as an unauthenticated wire ID.
        try await store.insertMessage(StoredMessage(id: "t", accountID: account, chatID: peer, senderID: peer, body: "hi", encryptionProfile: "legacy", wireID: "w"))
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        let client = XMPPClient(labCertificateAuthority: nil)
        return (store, InboundProcessor(encryption: encryption, client: client, account: account))
    }

    /// The app and the extension no longer have their own inbound switches: the same events
    /// through the same processor leave the same projection, whichever loop drove them.
    @Test func appAndExtensionPathsProjectIdenticalState() async throws {
        let xml = try XMPPClient.reactionXML(to: peer, targetID: "w", reactions: ["👍"], id: "r1")
        let reaction = try #require(XMPPClient.decodeOutgoingReactionXML(xml, from: account))

        let (appStore, appProcessor) = try await fixture()
        #expect(try await appProcessor.process(.reaction(reaction)) == .stored)
        #expect(try await appProcessor.process(.groupPresence(room: "room@localhost")) == .ignored)
        #expect(try await appProcessor.process(.reaction(reaction)) == .stored) // replay is idempotent

        let (extensionStore, extensionProcessor) = try await fixture()
        let (events, continuation) = AsyncStream<XMPPEvent>.makeStream()
        continuation.yield(.reaction(reaction))
        continuation.yield(.groupPresence(room: "room@localhost"))
        continuation.yield(.reaction(reaction))
        continuation.yield(.state(.disconnected(nil)))
        await #expect(throws: BackgroundSynchronizationError.connectionEnded) {
            try await consumeBackgroundEvents(events, processor: extensionProcessor)
        }

        // Arrival time is the only field that legitimately differs between two runs.
        let fromApp = try await appStore.reactionsForChat(accountID: account, chatID: peer, messageIDs: ["t"]).mapValues { $0.map { [$0.id, $0.actorID, $0.targetWireID] + $0.reactions } }
        let fromExtension = try await extensionStore.reactionsForChat(accountID: account, chatID: peer, messageIDs: ["t"]).mapValues { $0.map { [$0.id, $0.actorID, $0.targetWireID] + $0.reactions } }
        #expect(fromApp == fromExtension)
        #expect(fromApp == ["t": [["r1", account, "w", "👍"]]])
        #expect(try await appStore.events(accountID: account, chatID: peer, messageID: "t").map(\.kind) == [.reaction])
    }

    /// A plain receipt from the peer projects onto our own message; one for the peer's own message is refused.
    @Test func peerReceiptsProjectOntoOwnMessagesOnly() async throws {
        let (store, processor) = try await fixture()
        try await store.insertMessage(StoredMessage(id: "mine", accountID: account, chatID: peer, senderID: account, body: "sent", isOutgoing: true, encryptionProfile: "legacy", wireID: "mine"))
        let delivered = XMPPReceipt(id: "d1", from: peer + "/phone", to: account, targetID: "mine", kind: .delivered)
        let displayed = XMPPReceipt(id: "d2", from: peer + "/phone", to: account, targetID: "mine", kind: .displayed)
        let forged = XMPPReceipt(id: "d3", from: peer + "/phone", to: account, targetID: "w", kind: .displayed)
        #expect(try await processor.process(.receipt(delivered)) == .stored)
        #expect(try await processor.process(.receipt(displayed)) == .stored)
        #expect(try await processor.process(.receipt(forged)) == .stored) // ignored, not fatal
        #expect(try await store.events(accountID: account, chatID: peer, messageID: "mine").map(\.kind) == [.delivered, .displayed])
        #expect(try await store.events(accountID: account, chatID: peer, messageID: "t").isEmpty)
    }

    /// A stanza without a durable disposition withholds the next barrier and ends the stream.
    @Test func undisposedInboundRefusesTheBarrier() async throws {
        let (store, processor) = try await fixture()
        try await store.close() // persistence now fails outright
        let xml = try XMPPClient.reactionXML(to: peer, targetID: "w", reactions: ["👍"], id: "r2")
        let reaction = try #require(XMPPClient.decodeOutgoingReactionXML(xml, from: account))
        await #expect(throws: (any Error).self) { try await processor.process(.reaction(reaction)) }
        await #expect(throws: InboundProcessor.Failure.unsavedInbound) {
            try await processor.process(.streamManagementBarrier(XMPPInboundToken(session: UUID(), sequence: 1)))
        }
    }
}
