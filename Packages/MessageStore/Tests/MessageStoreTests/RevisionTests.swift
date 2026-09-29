import Foundation
import Testing
@testable import MessageStore

/// Retractions and corrections are message events: queued with their optimistic projection, shown
/// only when the actor is the message's sender, and folded into the message by `applying(_:)`.
private func revisionURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "messages.sqlite")
}
private func seed(_ store: MessageStore) async throws {
    try await store.upsertChat(accountID: "self", chatID: "peer", title: "Peer")
    try await store.insertMessage(StoredMessage(id: "theirs", accountID: "self", chatID: "peer", senderID: "peer", body: "Their words",
                                                sentAt: Date(timeIntervalSince1970: 50), encryptionProfile: "modern", wireID: "w-theirs", wireIDAuthenticated: true))
    try await store.insertMessage(StoredMessage(id: "mine", accountID: "self", chatID: "peer", senderID: "self", body: "My words",
                                                sentAt: Date(timeIntervalSince1970: 100), isOutgoing: true, encryptionProfile: "modern", wireID: "w-mine", wireIDAuthenticated: true))
}
private func event(_ id: String, actor: String, target: String, kind: MessageEventKind, body: String? = nil, at: TimeInterval = 200) throws -> MessageEvent {
    MessageEvent(id: id, chatID: "peer", actorID: actor, targetWireID: target, kind: kind,
                 payload: try body.map(MessageEvent.correctionPayload) ?? "{}", updatedAt: Date(timeIntervalSince1970: at))
}
private func shown(_ store: MessageStore, _ id: String) async throws -> StoredMessage {
    try #require(try await store.message(accountID: "self", messageID: id)).applying(try await store.events(accountID: "self", chatID: "peer", messageID: id))
}

@Test func ownRevisionsQueueOneUpdateWithAnImmediateProjection() async throws {
    let url = try revisionURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await seed(store)
    #expect(try await store.enqueueMessageUpdate(accountID: "self", id: "c1", kind: .correction, chatID: "peer", targetMessageID: "mine", body: "Better words"))
    #expect(try await !store.enqueueMessageUpdate(accountID: "self", id: "c1", kind: .correction, chatID: "peer", targetMessageID: "mine", body: "Better words"))
    await #expect(throws: MessageStoreError.conflictingIdentity) {
        try await store.enqueueMessageUpdate(accountID: "self", id: "c1", kind: .correction, chatID: "peer", targetMessageID: "mine", body: "Other words")
    }
    let edited = try await shown(store, "mine")
    #expect(edited.body == "Better words" && edited.isEdited && !edited.isRetracted)
    #expect(try await store.messages(accountID: "self", chatID: "peer").count == 2)
    #expect(try await store.chats(accountID: "self").first?.lastMessage?.body == "Better words")
    let queued = try #require(try await store.queuedUpdates(accountID: "self", kind: .correction).first)
    #expect(queued.targetMessageID == "mine" && queued.targetWireID == "w-mine" && queued.payload.flatMap(MessageEvent.correctionBody) == "Better words")
    // Only our own outgoing messages can be revised; a bodyless correction is refused.
    await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueMessageUpdate(accountID: "self", id: "x", kind: .correction, chatID: "peer", targetMessageID: "theirs", body: "hijack") }
    await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueMessageUpdate(accountID: "self", id: "x", kind: .correction, chatID: "peer", targetMessageID: "mine", body: "") }
    await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueMessageUpdate(accountID: "self", id: "x", kind: .reaction, chatID: "peer", targetMessageID: "mine") }
    // A retraction wins over any correction and empties the preview.
    #expect(try await store.enqueueMessageUpdate(accountID: "self", id: "r1", kind: .retraction, chatID: "peer", targetMessageID: "mine"))
    let unsent = try await shown(store, "mine")
    #expect(unsent.isRetracted && !unsent.isEdited && unsent.body.isEmpty)
    #expect(try await store.chats(accountID: "self").first?.lastMessage?.isRetracted == true)
    #expect(try await store.eventsForChat(accountID: "self", chatID: "peer", messageIDs: ["mine", "theirs"])["mine"]?.map(\.kind) == [.correction, .retraction])
}

@Test func onlyTheSenderMayUnsendOrRewriteAndCorrectionsMayChain() async throws {
    let url = try revisionURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await seed(store)
    // A peer's claim about our message is kept (idempotent, missing targets retained) but never projected.
    try await store.recordEvent(accountID: "self", event: try event("forged", actor: "peer", target: "w-mine", kind: .correction, body: "Hijacked"))
    try await store.recordEvent(accountID: "self", event: try event("forged-r", actor: "peer", target: "w-mine", kind: .retraction))
    let mine = try await shown(store, "mine")
    #expect(mine.body == "My words" && !mine.isEdited && !mine.isRetracted)
    #expect(try await store.eventsForChat(accountID: "self", chatID: "peer", messageIDs: ["mine"]).isEmpty)
    // A stranger is not a participant at all.
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.recordEvent(accountID: "self", event: try event("m", actor: "mallory", target: "w-theirs", kind: .correction, body: "x"))
    }
    // The peer's own message: edit, edit-of-the-edit (XEP-0308 chains), then unsend.
    try await store.recordEvent(accountID: "self", event: try event("c1", actor: "peer", target: "w-theirs", kind: .correction, body: "Second draft", at: 201))
    #expect(try await shown(store, "theirs").body == "Second draft")
    try await store.recordEvent(accountID: "self", event: try event("c2", actor: "peer", target: "c1", kind: .correction, body: "Third draft", at: 202))
    let chained = try await shown(store, "theirs")
    #expect(chained.body == "Third draft" && chained.isEdited)
    // An older correction arriving late does not overwrite the newer one.
    try await store.recordEvent(accountID: "self", event: try event("c0", actor: "peer", target: "w-theirs", kind: .correction, body: "First draft", at: 150))
    #expect(try await shown(store, "theirs").body == "Third draft")
    try await store.recordEvent(accountID: "self", event: try event("r", actor: "peer", target: "w-theirs", kind: .retraction, at: 300))
    let unsent = try await shown(store, "theirs")
    #expect(unsent.isRetracted && unsent.body.isEmpty)
}

@Test func retractionDropsThePendingAlertAndACorrectionAlertsWithItsNewText() async throws {
    let url = try revisionURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.upsertChat(accountID: "self", chatID: "peer", title: "Peer")
    try await store.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([1]))
    let first = StoredMessage(id: "n1", accountID: "self", chatID: "peer", senderID: "peer", body: "Original", sentAt: Date(timeIntervalSince1970: 10), encryptionProfile: "modern", wireID: "w1", wireIDAuthenticated: true)
    let second = StoredMessage(id: "n2", accountID: "self", chatID: "peer", senderID: "peer", body: "Second", sentAt: Date(timeIntervalSince1970: 20), encryptionProfile: "modern", wireID: "w2", wireIDAuthenticated: true)
    try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d1", expectedRevision: 1, state: Data([2]), message: first)
    try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d2", expectedRevision: 2, state: Data([3]), message: second)
    // The correction arrives as authenticated content about n2, not as a third message.
    try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d3", expectedRevision: 3, state: Data([4]), message: nil,
                                            event: try event("c", actor: "peer", target: "w2", kind: .correction, body: "Second, corrected"))
    // The unsend removes n1's pending alert.
    try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d4", expectedRevision: 4, state: Data([5]), message: nil,
                                            event: try event("r", actor: "peer", target: "w1", kind: .retraction))
    let batch = try await store.pendingNotifications(accountID: "self")
    guard case let .message(latest)? = batch.candidates.map(\.content).first else { Issue.record("no candidate"); return }
    #expect(batch.candidates.count == 1 && batch.claimed == [.message("n2")])
    #expect(latest.id == "n2" && latest.body == "Second, corrected" && latest.isEdited)
    #expect(try await store.messages(accountID: "self", chatID: "peer").count == 2)
    // An event with a bubble of its own, or from someone other than the authenticated sender, is refused.
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.commitEncryptedIncoming(accountID: "self", sender: "peer", digest: "d5", expectedRevision: 5, state: Data([6]), message: nil,
                                                event: try event("bad", actor: "self", target: "w2", kind: .retraction))
    }
}
