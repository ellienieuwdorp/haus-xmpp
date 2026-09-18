import Foundation
import Testing
@testable import MessageStore

private func receiptURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "messages.sqlite")
}
private func seed(_ store: MessageStore) async throws {
    try await store.upsertChat(accountID: "self", chatID: "peer", title: "Peer")
    try await store.insertMessage(StoredMessage(id: "mine", accountID: "self", chatID: "peer", senderID: "self", body: "Sent", sentAt: Date(timeIntervalSince1970: 100), isOutgoing: true, encryptionProfile: "modern", wireID: "mine", wireIDAuthenticated: true))
    try await store.insertMessage(StoredMessage(id: "theirs", accountID: "self", chatID: "peer", senderID: "peer", body: "First", sentAt: Date(timeIntervalSince1970: 200), encryptionProfile: "modern", wireID: "w1", wireIDAuthenticated: true))
    try await store.insertMessage(StoredMessage(id: "newer", accountID: "self", chatID: "peer", senderID: "peer", body: "Second", sentAt: Date(timeIntervalSince1970: 300), encryptionProfile: "modern", wireID: "w2", wireIDAuthenticated: true))
}
private func receipt(_ id: String, kind: MessageEventKind, actor: String = "peer", target: String = "mine", at: Double = 1000) -> MessageEvent {
    MessageEvent(id: id, chatID: "peer", actorID: actor, targetWireID: target, kind: kind, payload: "{}", updatedAt: Date(timeIntervalSince1970: at))
}

@Test func receiptsQueuePerMessageAndMarkersCoalesceOnTheNewestQueuedTarget() async throws {
    let url = try receiptURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await seed(store)
    // One receipt per peer message; repeating one is a no-op, and our own message is never a target.
    let first = try #require(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "theirs", kind: .receipt))
    #expect(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "theirs", kind: .receipt) == nil)
    let second = try #require(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "newer", kind: .receipt))
    await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "mine", kind: .receipt) }
    await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueReceipt(accountID: "self", chatID: "other", targetMessageID: "theirs", kind: .receipt) }
    #expect(try await store.queuedReceipts(accountID: "self").map(\.id) == [first, second])
    #expect(try await store.update(accountID: "self", updateID: second)?.targetWireID == "w2")
    // A queued marker is replaced by a newer target and never by an older one.
    let old = try #require(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "theirs", kind: .marker))
    let latest = try #require(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "newer", kind: .marker))
    #expect(try await store.update(accountID: "self", updateID: old) == nil)
    #expect(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "theirs", kind: .marker) == nil)
    #expect(try await store.queuedReceipts(accountID: "self").filter { $0.kind == .marker }.map(\.id) == [latest])
    // Once claimed the marker is immutable: a newer read becomes a new row.
    try await store.sealQueuedUpdate(accountID: "self", updateID: latest, wire: Data([1]))
    _ = try #require(try await store.claimNextUpdate(accountID: "self", updateIDs: [latest]))
    try await store.insertMessage(StoredMessage(id: "newest", accountID: "self", chatID: "peer", senderID: "peer", body: "Third", sentAt: Date(timeIntervalSince1970: 400), encryptionProfile: "modern", wireID: "w3", wireIDAuthenticated: true))
    let another = try #require(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "newest", kind: .marker))
    #expect(try await store.update(accountID: "self", updateID: latest)?.transportState == .submitting)
    #expect(try await store.update(accountID: "self", updateID: another)?.transportState == .queued)
    // Server acceptance promotes receipts through the same acknowledgement path as every update.
    try await store.saveStreamManagement(accountID: "self", expectedRevision: nil, data: Data([4]), acknowledgedMessageIDs: [latest])
    #expect(try await store.update(accountID: "self", updateID: latest)?.transportState == .serverAccepted)
    try await store.close()
}

@Test func receiptSwitchesAreEnforcedWhereReceiptsAreQueued() async throws {
    let url = try receiptURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await seed(store)
    #expect(try await store.accountPreferences(accountID: "self") == AccountPreferences())
    try await store.setAccountPreferences(accountID: "self", AccountPreferences(notificationPreviews: false, deliveryReceipts: false, readReceipts: true))
    #expect(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "theirs", kind: .receipt) == nil)
    #expect(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "theirs", kind: .marker) != nil)
    #expect(try await store.notificationPreviewsEnabled(accountID: "self") == false)
    try await store.setNotificationPreviews(accountID: "self", enabled: true)
    #expect(try await store.accountPreferences(accountID: "self") == AccountPreferences(notificationPreviews: true, deliveryReceipts: false, readReceipts: true))
    try await store.setAccountPreferences(accountID: "self", AccountPreferences(readReceipts: false))
    #expect(try await store.enqueueReceipt(accountID: "self", chatID: "peer", targetMessageID: "newer", kind: .marker) == nil)
    try await store.close()
}

@Test func peerReceiptsProjectOnlyOntoOwnMessagesAndKeepTheStrongestState() async throws {
    let url = try receiptURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await seed(store)
    try await store.recordReceipt(accountID: "self", event: receipt("d1", kind: .delivered))
    #expect(try await store.events(accountID: "self", chatID: "peer", messageID: "mine").map(\.kind) == [.delivered])
    // Only the peer confirms, only about our messages, and only with the fixed empty payload.
    await #expect(throws: MessageStoreError.invalidValue) { try await store.recordReceipt(accountID: "self", event: receipt("x1", kind: .displayed, actor: "self")) }
    await #expect(throws: MessageStoreError.invalidValue) { try await store.recordReceipt(accountID: "self", event: receipt("x2", kind: .displayed, target: "w1")) }
    await #expect(throws: MessageStoreError.invalidValue) { try await store.recordReceipt(accountID: "self", event: receipt("x3", kind: .reaction)) }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.recordReceipt(accountID: "self", event: MessageEvent(id: "x4", chatID: "peer", actorID: "peer", targetWireID: "mine", kind: .displayed, payload: "[]", updatedAt: Date()))
    }
    // An unknown target is retained and projects once the message arrives from the archive.
    try await store.recordReceipt(accountID: "self", event: receipt("d2", kind: .displayed, target: "later"))
    try await store.insertMessage(StoredMessage(id: "later", accountID: "self", chatID: "peer", senderID: "self", body: "Archived", sentAt: Date(timeIntervalSince1970: 500), isOutgoing: true, encryptionProfile: "modern", wireID: "later", wireIDAuthenticated: true))
    let projected = try await store.eventsForChat(accountID: "self", chatID: "peer", messageIDs: ["mine", "later", "theirs"])
    #expect(projected["mine"]?.map(\.kind) == [.delivered])
    #expect(projected["later"]?.map(\.kind) == [.displayed])
    #expect(projected["theirs"] == nil)
    // Delivered and displayed sit beside reactions in the one projection.
    try await store.recordReaction(accountID: "self", reaction: AuthenticatedReaction(id: "r1", chatID: "peer", actorID: "peer", targetWireID: "mine", reactions: ["👍"], updatedAt: Date(timeIntervalSince1970: 1001)))
    try await store.recordReceipt(accountID: "self", event: receipt("d3", kind: .displayed, at: 1002))
    #expect(try await store.events(accountID: "self", chatID: "peer", messageID: "mine").map(\.kind) == [.delivered, .displayed, .reaction])
    try await store.close()
}
