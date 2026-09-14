import Foundation
import Testing
@testable import MessageStore

private func reactionURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "messages.sqlite")
}
private func target(_ store: MessageStore, id: String = "target", actor: String = "peer", wire: String = "wire", authenticated: Bool = true) async throws {
    try await store.upsertChat(accountID: "self", chatID: "peer", title: "Peer")
    try await store.insertMessage(StoredMessage(id: id, accountID: "self", chatID: "peer", senderID: actor, body: "Message", encryptionProfile: "modern", wireID: wire, wireIDAuthenticated: authenticated))
}
private func update(_ id: String = "reaction", reactions: [String] = ["👍"]) -> StoredReactionUpdate {
    .init(id: id, accountID: "self", chatID: "peer", targetMessageID: "target", targetWireID: "wire", actorID: "self", reactions: reactions, createdAt: Date(timeIntervalSince1970: 100))
}

@Test func reactionOutboxAtomicallySealsExactCiphertextAndServerAckFencesSocketCompletion() async throws {
    let url = try reactionURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await target(store)
    #expect(try await store.enqueueReaction(update()))
    #expect(try await !store.enqueueReaction(update()))
    #expect(try await store.messages(accountID: "self", chatID: "peer").count == 1)
    #expect(try await store.reactions(accountID: "self", chatID: "peer", messageID: "target").first?.reactions == ["👍"])
    #expect(try await store.claimNextReaction(accountID: "self", updateIDs: ["reaction"]) == nil)
    try await store.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([1]))
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await store.sealQueuedReaction(accountID: "self", updateID: "reaction", expectedRevision: 0, state: Data([2]), wire: Data([3]))
    }
    #expect(try await store.encryptedReaction(accountID: "self", updateID: "reaction") == nil)
    #expect(try await store.encryptionState(accountID: "self")?.revision == 1)
    try await store.sealQueuedReaction(accountID: "self", updateID: "reaction", expectedRevision: 1, state: Data([2]), wire: Data([3]))
    let submission = try #require(await store.claimNextReaction(accountID: "self", updateIDs: ["reaction"]))
    #expect(try await store.claimNextReaction(accountID: "self", updateIDs: ["reaction"]) == nil)
    try await store.saveStreamManagement(accountID: "self", expectedRevision: nil, data: Data([4]), acknowledgedMessageIDs: ["reaction"])
    #expect(try await !store.finishReactionSubmission(accountID: "self", updateID: "reaction", attemptID: submission.attemptID))
    #expect(try await store.reactionUpdate(accountID: "self", updateID: "reaction")?.transportState == .serverAccepted)
    await #expect(throws: MessageStoreError.invalidTransition) { try await store.retryReaction(accountID: "self", updateID: "reaction") }
    #expect(try await store.encryptedReaction(accountID: "self", updateID: "reaction") == Data([3]))
}

@Test func reactionRecoveryPreservesExactBytesAndExplicitRetryRejectsLateClaim() async throws {
    let url = try reactionURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership(); try await target(store)
    try await store.enqueueReaction(update())
    try await store.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([1]))
    try await store.sealQueuedReaction(accountID: "self", updateID: "reaction", expectedRevision: 1, state: Data([2]), wire: Data([99]))
    let old = try #require(await store.claimNextReaction(accountID: "self", updateIDs: ["reaction"]))
    let reopened = try MessageStore(url: url)
    #expect(try await reopened.reactionUpdate(accountID: "self", updateID: "reaction")?.transportState == .submitting)
    try await store.recoverInterruptedSubmissions(accountID: "self")
    #expect(try await store.queuedReactions(accountID: "self").isEmpty)
    try await store.retryReaction(accountID: "self", updateID: "reaction")
    let next = try #require(await store.claimNextReaction(accountID: "self", updateIDs: ["reaction"]))
    #expect(old.attemptID != next.attemptID)
    #expect(try await !store.finishReactionSubmission(accountID: "self", updateID: "reaction", attemptID: old.attemptID))
    #expect(try await store.encryptedReaction(accountID: "self", updateID: "reaction") == Data([99]))
    #expect(try await store.releaseUnsentReactionSubmission(accountID: "self", updateID: "reaction", attemptID: next.attemptID))
    #expect(try await store.reconcileArchivedReaction(accountID: "self", updateID: "reaction", expectedEncryptedWire: Data([99])))
    #expect(try await store.reactionUpdate(accountID: "self", updateID: "reaction")?.transportState == .serverAccepted)
}

@Test func receivedReactionsCommitRatchetReplayAndActorScopedFullSetWithoutVisibleBubble() async throws {
    let url = try reactionURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([1]))
    let first = AuthenticatedReaction(id: "first", chatID: "peer", actorID: "peer", targetWireID: "wire", reactions: ["👍", "❤️"], updatedAt: Date(timeIntervalSince1970: 100))
    try await store.retainEncryptedIncoming(accountID: "self", sender: "peer", digest: "d1", wire: Data([2]))
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.commitEncryptedIncoming(accountID: "self", sender: "attacker", digest: "d1", expectedRevision: 1, state: Data([3]), message: nil, reaction: first)
    }
    #expect(try await store.encryptionState(accountID: "self")?.revision == 1)
    #expect(try await store.pendingEncryptedIncoming(accountID: "self").count == 1)
    try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d1", expectedRevision: 1, state: Data([3]), message: nil, reaction: first)
    #expect(try await store.chats(accountID: "self").isEmpty)
    try await target(store)
    #expect(try await store.reactions(accountID: "self", chatID: "peer", messageID: "target").first?.reactions == ["❤️", "👍"].sorted())
    let clear = AuthenticatedReaction(id: "clear", chatID: "peer", actorID: "peer", targetWireID: "wire", reactions: [], updatedAt: Date(timeIntervalSince1970: 102))
    try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d2", expectedRevision: 2, state: Data([4]), message: nil, reaction: clear)
    // A late old event and reused event ID cannot resurrect a newer withdrawn set.
    try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d3", expectedRevision: 3, state: Data([5]), message: nil, reaction: first)
    let forgedReplacement = AuthenticatedReaction(id: "clear", chatID: "peer", actorID: "peer", targetWireID: "wire", reactions: ["😂"], updatedAt: Date(timeIntervalSince1970: 999))
    try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d4", expectedRevision: 4, state: Data([6]), message: nil, reaction: forgedReplacement)
    #expect(try await store.reactions(accountID: "self", chatID: "peer", messageID: "target").first?.reactions == [])
    #expect(try await store.reactions(accountID: "other", chatID: "peer", messageID: "target").isEmpty)
    #expect(try await store.messages(accountID: "self", chatID: "peer").count == 1)
    #expect(try await store.pendingEncryptedIncoming(accountID: "self").isEmpty)
}

@Test func reactionAssociationsRejectUnauthenticatedOrAmbiguousCrossActorWireIDs() async throws {
    let url = try reactionURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await target(store, id: "untrusted", authenticated: false)
    #expect(try await store.reactionTarget(accountID: "self", chatID: "peer", wireID: "wire") == nil)
    await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueReaction(update()) }
    try await target(store)
    #expect(try await store.enqueueReaction(update()))
    try await target(store, id: "collision", actor: "self")
    #expect(try await store.reactionTarget(accountID: "self", chatID: "peer", wireID: "wire") == nil)
    #expect(try await store.reactions(accountID: "self", chatID: "peer", messageID: "target").isEmpty)
    await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueReaction(update("second")) }
}

@Test func bulkTimelineReactionsKeepLatestActorSetsAndRejectOffPageAmbiguity() async throws {
    let url = try reactionURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await target(store)
    try await target(store, id: "second", wire: "second-wire")
    try await target(store, id: "untrusted", wire: "untrusted-wire", authenticated: false)
    try await store.enqueueReaction(update())
    try await store.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([1]))
    var revision = 1
    for (id, wire, values, time) in [
        ("peer-old", "wire", ["❤️"], 100.0), ("peer-clear", "wire", [], 102.0),
        ("peer-late", "wire", ["😂"], 101.0), ("second-reaction", "second-wire", ["🔥"], 103.0),
        ("untrusted-reaction", "untrusted-wire", ["👍"], 104.0)
    ] {
        let reaction = AuthenticatedReaction(id: id, chatID: "peer", actorID: "peer", targetWireID: wire,
                                             reactions: values, updatedAt: Date(timeIntervalSince1970: time))
        try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: id,
                                                expectedRevision: revision, state: Data([UInt8(revision + 1)]), message: nil, reaction: reaction)
        revision += 1
    }
    let requested: Set<String> = ["target", "second", "untrusted", "missing"]
    let bulk = try await store.reactionsForChat(accountID: "self", chatID: "peer", messageIDs: requested)
    #expect(bulk["target"] == (try await store.reactions(accountID: "self", chatID: "peer", messageID: "target")))
    #expect(bulk["target"]?.count == 2)
    #expect(bulk["target"]?.first(where: { $0.actorID == "peer" })?.reactions == [])
    #expect(bulk["target"]?.first(where: { $0.actorID == "self" })?.reactions == ["👍"])
    #expect(bulk["second"]?.first?.reactions == ["🔥"])
    #expect(bulk["untrusted"] == nil && bulk["missing"] == nil)
    #expect(try await store.reactionsForChat(accountID: "other", chatID: "peer", messageIDs: requested).isEmpty)
    #expect(try await store.reactionsForChat(accountID: "self", chatID: "other", messageIDs: requested).isEmpty)
    #expect(try await store.reactionsForChat(accountID: "self", chatID: "peer", messageIDs: []).isEmpty)
    // Not in requested page, but still makes the authenticated origin association ambiguous.
    try await target(store, id: "off-page-collision", actor: "self")
    let collision = try await store.reactionsForChat(accountID: "self", chatID: "peer", messageIDs: requested)
    #expect(collision["target"] == nil)
    #expect(collision["second"]?.first?.reactions == ["🔥"])
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.reactionsForChat(accountID: "self", chatID: "peer", messageIDs: Set((0...1000).map(String.init)))
    }
}
