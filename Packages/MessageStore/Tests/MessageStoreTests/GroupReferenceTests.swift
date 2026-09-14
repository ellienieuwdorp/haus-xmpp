import Foundation
import Testing
@testable import MessageStore

private func withGroupStore(_ operation: (MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try MessageStore(url: directory.appendingPathComponent("groups.sqlite"))
    do {
        try await store.acquireTransportOwnership()
        try await operation(store)
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    } catch {
        try await store.close()
        try FileManager.default.removeItem(at: directory)
        throw error
    }
}
@Test func groupSealDoesNotMisrepresentOriginAsRoomAssignedReference() async throws {
    try await withGroupStore { store in
        try await store.upsertChat(accountID: "self", chatID: "room", title: "Room")
        _ = try await store.enqueueOutgoing(.init(id: "own", accountID: "self", chatID: "room", senderID: "self", body: "Group", isOutgoing: true))
        try await store.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([1]))
        try await store.sealQueuedOutgoing(accountID: "self", messageID: "own", profile: "modern", expectedRevision: 1, state: Data([2]), wire: Data([3]), authenticateWireID: false)
        #expect(try await store.reactionReference(accountID: "self", messageID: "own") == nil)
        #expect(try await store.message(accountID: "self", messageID: "own")?.wireIDAuthenticated == false)
        #expect(try await !store.reconcileArchivedOutgoing(accountID: "self", messageID: "own", expectedEncryptedWire: Data([0]), groupRoom: "room", roomStanzaID: "room-id"))
        #expect(try await store.reactionReference(accountID: "self", messageID: "own") == nil)
        #expect(try await store.reconcileArchivedOutgoing(accountID: "self", messageID: "own", expectedEncryptedWire: Data([3]), groupRoom: "room", roomStanzaID: "room-id"))
        #expect(try await store.reactionReference(accountID: "self", messageID: "own") == "room-id")
        await #expect(throws: MessageStoreError.conflictingIdentity) {
            try await store.reconcileArchivedOutgoing(accountID: "self", messageID: "own", expectedEncryptedWire: Data([3]), groupRoom: "room", roomStanzaID: "changed")
        }
    }
}
@Test func groupReferenceAndReactionCommitTogetherWithoutFakeMessagesAndCollisionsSuppressProjection() async throws {
    try await withGroupStore { store in
        try await store.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([1]))
        let target = StoredMessage(id: "target", accountID: "self", chatID: "room", senderID: "alice", body: "Target", encryptionProfile: "modern")
        try await store.commitEncryptedIncoming(accountID: "self", sender: "alice", digest: "cipher", expectedRevision: 1, state: Data([2]), message: target, groupRoom: "room", roomStanzaID: "room-id")
        let reaction = AuthenticatedReaction(id: "reaction", chatID: "room", actorID: "bob", targetWireID: "room-id", reactions: ["👍"], updatedAt: Date())
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.commitEncryptedIncoming(accountID: "self", sender: "bob", digest: "rx", expectedRevision: 2, state: Data([3]), message: nil, reaction: reaction)
        }
        #expect(try await store.encryptionState(accountID: "self")?.revision == 2)
        try await store.commitEncryptedIncoming(accountID: "self", sender: "bob", digest: "rx", expectedRevision: 2, state: Data([3]), message: nil, reaction: reaction, groupRoom: "room")
        #expect(try await store.messages(accountID: "self", chatID: "room").count == 1)
        #expect(try await store.reactionsForChat(accountID: "self", chatID: "room", messageIDs: ["target"])["target"]?.first?.actorID == "bob")
        #expect(try await store.reactionTarget(accountID: "self", chatID: "another-room", wireID: "room-id") == nil)
        let collision = StoredMessage(id: "collision", accountID: "self", chatID: "room", senderID: "carol", body: "Different", encryptionProfile: "modern")
        try await store.commitEncryptedIncoming(accountID: "self", sender: "carol", digest: "cipher2", expectedRevision: 3, state: Data([4]), message: collision, groupRoom: "room", roomStanzaID: "room-id")
        #expect(try await store.reactionTarget(accountID: "self", chatID: "room", wireID: "room-id") == nil)
        #expect(try await store.reactionsForChat(accountID: "self", chatID: "room", messageIDs: ["target"]).isEmpty)
    }
}

@Test func unsupportedArchiveReceiptsAreAccountScopedIdempotentAndBounded() async throws {
    try await withGroupStore { store in
        for number in 0...1000 {
            try await store.recordArchiveRejection(accountID: "self", archiveID: "room", messageID: "entry-\(number)", reason: "unverifiableEncryptedGroup")
        }
        #expect(try await !store.hasArchiveRejection(accountID: "self", archiveID: "room", messageID: "entry-0"))
        #expect(try await store.hasArchiveRejection(accountID: "self", archiveID: "room", messageID: "entry-1000"))
        #expect(try await !store.hasArchiveRejection(accountID: "other", archiveID: "room", messageID: "entry-1000"))
        try await store.recordArchiveRejection(accountID: "self", archiveID: "room", messageID: "entry-1000", reason: "unverifiableEncryptedGroup")
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.recordArchiveRejection(accountID: "self", archiveID: "room", messageID: "secret", reason: "unbounded arbitrary content")
        }
    }
}
