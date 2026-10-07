import Foundation
import Testing
@testable import MessageStore

/// `rejectOutgoing`: a server returned one of our stanzas (`<message type='error'>`).
private func withSentMessages(_ ids: [String], _ operation: (MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
    try await store.acquireTransportOwnership()
    try await store.upsertChat(accountID: "self", chatID: "peer", title: "Peer")
    try await store.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([0]))
    for (index, id) in ids.enumerated() {
        try await store.enqueueOutgoing(StoredMessage(id: id, accountID: "self", chatID: "peer", senderID: "self", body: id, isOutgoing: true))
        try await store.sealQueuedOutgoing(accountID: "self", messageID: id, profile: "modern", expectedRevision: index + 1, state: Data([UInt8(index + 1)]),
                                           wire: Data(id.utf8), authenticateWireID: true)
        let claim = try #require(await store.claimNextOutgoing(accountID: "self", messageIDs: [id]))
        try await store.finishOutgoingSubmission(claim)
    }
    try await operation(store)
    try await store.close()
}

@Test func aReturnedMessageFailsWithItsReasonWhateverTheServerAcknowledged() async throws {
    try await withSentMessages(["acked", "pending", "confirmed"]) { store in
        try await store.saveStreamManagement(accountID: "self", expectedRevision: nil, data: Data([1]), acknowledgedMessageIDs: ["acked", "confirmed"])
        try await store.recordReceipt(accountID: "self", event: MessageEvent(id: "r", chatID: "peer", actorID: "peer", targetWireID: "confirmed",
                                                                             kind: .delivered, payload: "{}", updatedAt: Date()))
        // Acknowledged by our server is still not delivered; an unacknowledged send can bounce first.
        #expect(try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "acked", rejection: "service-unavailable")
                == RejectedOutgoing(chatID: "peer", messageID: "acked", rejection: "service-unavailable"))
        #expect(try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "pending", rejection: "remote-server-timeout") != nil)
        let acked = try #require(await store.message(accountID: "self", messageID: "acked"))
        #expect(acked.transportState == .failed && acked.rejection == "service-unavailable")
        // A resumed stream redelivers a bounce it already gave us: nothing changes, so nothing is reported twice.
        #expect(try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "acked", rejection: "service-unavailable") == nil)
        // The acknowledgement that arrives after the bounce cannot turn it back into Sent.
        try await store.saveStreamManagement(accountID: "self", expectedRevision: 1, data: Data([2]), acknowledgedMessageIDs: ["pending"])
        #expect(try await store.message(accountID: "self", messageID: "pending")?.transportState == .failed)
        // The peer confirmed this one, so a late bounce from some route does not undo it. Another chat's id never matches.
        #expect(try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "confirmed", rejection: "gone") == nil)
        #expect(try await store.rejectOutgoing(accountID: "self", chatID: "stranger", wireID: "acked", rejection: "gone") == nil)
        #expect(try await store.message(accountID: "self", messageID: "confirmed")?.transportState == .serverAccepted)
        #expect(try await store.message(accountID: "self", messageID: "acked")?.rejection == "service-unavailable")
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "acked", rejection: "Visit evil.example")
        }
    }
}

@Test func ourArchivedCopyOfAReturnedMessageIsNotAcceptanceOfItsRetry() async throws {
    try await withSentMessages(["m"]) { store in
        _ = try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "m", rejection: "service-unavailable")
        // Our archive stored the attempt before the server routed (and returned) it.
        #expect(try await !store.reconcileArchivedOutgoing(accountID: "self", messageID: "m", expectedEncryptedWire: Data("m".utf8)))
        try await store.retryOutgoing(accountID: "self", messageID: "m")
        // The reason described the returned attempt; a retry that later fails locally must not repeat it.
        #expect(try await store.message(accountID: "self", messageID: "m")?.rejection == nil)
        #expect(try await !store.reconcileArchivedOutgoing(accountID: "self", messageID: "m", expectedEncryptedWire: Data("m".utf8)))
        // A queued retry has not been sent: a late copy of the old bounce leaves it to go out.
        #expect(try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "m", rejection: "gone") == nil)
        let retry = try #require(await store.claimNextOutgoing(accountID: "self", messageIDs: ["m"]))
        try await store.finishOutgoingSubmission(retry)
        try await store.saveStreamManagement(accountID: "self", expectedRevision: nil, data: Data([1]), acknowledgedMessageIDs: ["m"])
        #expect(try await store.message(accountID: "self", messageID: "m")?.transportState == .serverAccepted)
    }
}

@Test func aReturnedUpdateFailsWithoutTouchingTheMessageItNames() async throws {
    try await withSentMessages(["m"]) { store in
        try await store.insertMessage(StoredMessage(id: "target", accountID: "self", chatID: "peer", senderID: "peer", body: "Hi",
                                                    encryptionProfile: "modern", wireID: "wire", wireIDAuthenticated: true))
        try await store.enqueueReaction(.init(id: "reaction", accountID: "self", chatID: "peer", targetMessageID: "target", targetWireID: "wire",
                                             actorID: "self", reactions: ["👍"]))
        try await store.sealQueuedUpdate(accountID: "self", updateID: "reaction", expectedRevision: 2, state: Data([9]), wire: Data([9]))
        let claim = try #require(await store.claimNextUpdate(accountID: "self", updateIDs: ["reaction"]))
        try await store.finishUpdateSubmission(accountID: "self", updateID: "reaction", attemptID: claim.attemptID)
        #expect(try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "reaction", rejection: "blocked")
                == RejectedOutgoing(chatID: "peer", messageID: nil, rejection: "blocked"))
        #expect(try await store.reactionUpdate(accountID: "self", updateID: "reaction")?.transportState == .failed)
        #expect(try await !store.reconcileArchivedUpdate(accountID: "self", updateID: "reaction", expectedWire: Data([9])))
        #expect(try await store.message(accountID: "self", messageID: "m")?.transportState == .unconfirmed)
    }
}
