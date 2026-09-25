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

    private func initializedFixture() async throws -> (MessageStore, OMEMOService, InboundProcessor) {
        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "inbound-\(UUID()).sqlite"))
        try await store.acquireTransportOwnership()
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        try await encryption.initialize(account: account, transport: NullTransport(account: account))
        return (store, encryption, InboundProcessor(encryption: encryption, client: XMPPClient(labCertificateAuthority: nil), account: account))
    }

    /// Another device's message without a key for this one is a placeholder, not retained work: the chat needs no
    /// review, the barrier stays acknowledgeable, and a redelivery adds nothing.
    @Test func excludedMessageReturnsExcludedAndKeepsTheBarrierAcknowledgeable() async throws {
        let (store, _, processor) = try await initializedFixture()
        let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 4242, keys: [], payload: Data([1, 2, 3]))
        let message = XMPPEncryptedMessage(id: "m1", from: peer + "/x", to: account, originID: nil, envelope: envelope, hasFallbackBody: true)
        #expect(try await processor.process(.encryptedMessage(message)) == .excluded(reason: .notForThisDevice))
        #expect(try await store.messages(accountID: account, chatID: peer).map(\.unreadableReason) == [.notForThisDevice])
        #expect(try await processor.process(.streamManagementBarrier(XMPPInboundToken(session: UUID(), sequence: 1))) == .acknowledged)
        #expect(try await processor.process(.encryptedMessage(message)) == .excluded(reason: .notForThisDevice))
        #expect(try await store.messages(accountID: account, chatID: peer).count == 1)
        #expect(try await store.pendingEncryptedIncoming(accountID: account).isEmpty)
        // An update-shaped envelope (no hint) is excluded silently.
        let other = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 4242, keys: [], payload: Data([4, 5, 6]))
        let silent = XMPPEncryptedMessage(id: "m2", from: peer + "/x", to: account, originID: nil, envelope: other)
        #expect(try await processor.process(.encryptedMessage(silent)) == .excluded(reason: .notForThisDevice))
        #expect(try await store.messages(accountID: account, chatID: peer).count == 1)
        #expect(try await processor.process(.streamManagementBarrier(XMPPInboundToken(session: UUID(), sequence: 2))) == .acknowledged)
    }

    /// Keys that address this device twice can never be decrypted safely: excluded with the decrypt-failure class,
    /// recorded as malformed content. (A trusted peer device is not needed to reach this arm.)
    @Test func undecryptableMessageReturnsExcludedDecryptFailed() async throws {
        let (store, encryption, processor) = try await initializedFixture()
        let local = try await encryption.localIdentity(account: account, profile: .legacy)
        let key = XMPPOMEMOKey(deviceID: local.deviceID, keyExchange: false, data: Data([9, 9, 9]))
        let envelope = XMPPOMEMOEnvelope(profile: .legacy, senderDeviceID: 4242, keys: [key, key], iv: Data(repeating: 1, count: 12), payload: Data([1, 2, 3]))
        let message = XMPPEncryptedMessage(id: "d1", from: peer + "/x", to: account, originID: nil, envelope: envelope)
        #expect(try await processor.process(.encryptedMessage(message)) == .excluded(reason: .decryptFailed))
        #expect(try await store.messages(accountID: account, chatID: peer).map(\.unreadableReason) == [.malformedContent])
        #expect(try await processor.process(.streamManagementBarrier(XMPPInboundToken(session: UUID(), sequence: 1))) == .acknowledged)
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
