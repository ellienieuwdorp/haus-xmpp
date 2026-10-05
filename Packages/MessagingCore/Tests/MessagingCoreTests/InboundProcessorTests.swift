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

    /// The extension's loop hands every event to the shared processor and ends only on disconnect.
    @Test func backgroundEventsFeedTheProcessorAndEndOnDisconnect() async throws {
        let xml = try XMPPClient.reactionXML(to: peer, targetID: "w", reactions: ["👍"], id: "r1")
        let reaction = try #require(XMPPClient.decodeOutgoingReactionXML(xml, from: account))
        let (store, processor) = try await fixture()
        let (events, continuation) = AsyncStream<XMPPEvent>.makeStream()
        continuation.yield(.reaction(reaction))
        continuation.yield(.groupPresence(room: "room@localhost"))
        continuation.yield(.reaction(reaction)) // replay is idempotent
        continuation.yield(.state(.disconnected(nil)))
        await #expect(throws: BackgroundSynchronizationError.connectionEnded) {
            try await consumeBackgroundEvents(events, processor: processor)
        }
        let projected = try await store.eventsForChat(accountID: account, chatID: peer, messageIDs: ["t"]).mapValues { $0.compactMap(AuthenticatedReaction.init).map { [$0.id, $0.actorID, $0.targetWireID] + $0.reactions } }
        #expect(projected == ["t": [["r1", account, "w", "👍"]]])
        #expect(try await store.events(accountID: account, chatID: peer, messageID: "t").map(\.kind) == [.reaction])
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

    /// A stanza our server held for this session (offline storage, a hibernated stream's queue) is placed at the time
    /// the server stamped, not when the resumed stream delivered it.
    @Test func ourServersStampIsTheTimeOfALiveMessage() async throws {
        let (store, _, processor) = try await initializedFixture()
        let held = Date(timeIntervalSince1970: 1_790_000_000), room = "room@conference.localhost"
        var direct = XMPPEncryptedMessage(id: "m1", from: peer + "/x", to: account, originID: nil,
                                          envelope: XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 4242, keys: [], payload: Data([1])), hasFallbackBody: true)
        direct.serverStamp = held
        var group = try XMPPEncryptedGroupMessage(id: "m2", room: room, occupant: room + "/bob", sender: peer,
                                                  envelope: XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 4242, keys: [], payload: Data([2])), hasFallbackBody: true)
        group.serverStamp = held.addingTimeInterval(60)
        #expect(try await processor.process(.encryptedMessage(direct)) == .excluded(reason: .notForThisDevice))
        #expect(try await processor.process(.encryptedGroupMessage(group)) == .excluded(reason: .notForThisDevice))
        #expect(try await store.messages(accountID: account, chatID: peer).map(\.sentAt) == [held])
        #expect(try await store.messages(accountID: account, chatID: room).map(\.sentAt) == [held.addingTimeInterval(60)])
    }

    private func addressedCiphertext(_ encryption: OMEMOService) async throws -> [XMPPEvent] {
        let (direct, group) = try await unknownSenderEnvelopes(account: account, encryption: encryption)
        let room = "room@conference.localhost"
        return [.encryptedMessage(XMPPEncryptedMessage(id: "k1", from: peer + "/x", to: account, originID: nil, envelope: direct)),
                .encryptedGroupMessage(try XMPPEncryptedGroupMessage(id: "k2", room: room, occupant: room + "/bob", sender: peer, envelope: group))]
    }

    /// Ciphertext that cannot be decrypted yet (the sender's keys are unreachable offline) is retained for later keys or
    /// trust. That is a durable disposition, so the barrier stays acknowledgeable.
    @Test func retainedCiphertextKeepsTheBarrierAcknowledgeable() async throws {
        let (store, encryption, processor) = try await initializedFixture()
        for (sequence, event) in try await addressedCiphertext(encryption).enumerated() {
            let outcome = try await processor.process(event)
            guard case .retained = outcome else { Issue.record("\(event): \(outcome)"); continue }
            #expect(try await processor.process(.streamManagementBarrier(XMPPInboundToken(session: UUID(), sequence: UInt64(sequence + 1)))) == .acknowledged)
        }
        #expect(try await store.pendingEncryptedIncoming(accountID: account).count == 2)
    }

    /// A stanza without a durable disposition (a plain update not saved, ciphertext neither decrypted nor retained)
    /// withholds the next barrier and ends the stream.
    @Test func undisposedInboundRefusesTheBarrier() async throws {
        let xml = try XMPPClient.reactionXML(to: peer, targetID: "w", reactions: ["👍"], id: "r2")
        let reaction = try #require(XMPPClient.decodeOutgoingReactionXML(xml, from: account))
        for index in 0..<3 {
            let (store, encryption, processor) = try await initializedFixture()
            let event = index == 0 ? XMPPEvent.reaction(reaction) : try await addressedCiphertext(encryption)[index - 1]
            try await store.close() // persistence now fails outright
            await #expect(throws: (any Error).self) { try await processor.process(event) }
            await #expect(throws: InboundProcessor.Failure.unsavedInbound) {
                try await processor.process(.streamManagementBarrier(XMPPInboundToken(session: UUID(), sequence: 1)))
            }
        }
    }
}
