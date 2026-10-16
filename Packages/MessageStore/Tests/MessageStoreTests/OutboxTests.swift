import Foundation
import Testing
import CSQLite
@testable import MessageStore

private func fixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("messages.sqlite")
}
private func outgoing(_ id: String, account: String = "a", time: Double = 100, body: String = "hello") -> StoredMessage {
    StoredMessage(id: id, accountID: account, chatID: "peer", senderID: account, body: body,
                  sentAt: Date(timeIntervalSince1970: time), isOutgoing: true)
}

@Test func enqueueIsAtomicIdempotentAndFIFOAcrossAccounts() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    await #expect(throws: MessageStoreError.self) { try await store.enqueueOutgoing(outgoing("first")) }
    for account in ["a", "b"] { try await store.upsertChat(accountID: account, chatID: "peer", title: "Peer") }
    #expect(try await store.enqueueOutgoing(outgoing("first", time: 200)))
    #expect(try await store.enqueueOutgoing(outgoing("second", time: 100)))
    #expect(try await store.enqueueOutgoing(outgoing("first", account: "b")))
    try await store.setStarred(accountID: "a", messageID: "first", starred: true)
    #expect(try await !store.enqueueOutgoing(outgoing("first", time: 200)))
    await #expect(throws: MessageStoreError.conflictingIdentity) {
        try await store.enqueueOutgoing(outgoing("first", time: 200, body: "different"))
    }
    let first = try #require(await store.claimNextOutgoing(accountID: "a"))
    #expect(first.message.id == "first")
    #expect(first.message.isStarred)
    #expect(first.message.transportState == .submitting)
    #expect(try await !store.enqueueOutgoing(outgoing("first", time: 200)))
    #expect(try await store.claimNextOutgoing(accountID: "a")?.message.id == "second")
    #expect(try await store.claimNextOutgoing(accountID: "a") == nil)
    let other = try #require(await store.claimNextOutgoing(accountID: "b"))
    #expect(other.message.accountID == "b" && !other.message.isStarred)
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.enqueueOutgoing(outgoing("oversized", body: String(repeating: "x", count: 65_537)))
    }
}

@Test func invalidTransitionsAndExplicitRecoveryAreAccountScoped() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    for account in ["a", "b"] {
        try await store.upsertChat(accountID: account, chatID: "peer", title: "Peer")
        try await store.enqueueOutgoing(outgoing("1", account: account))
    }
    await #expect(throws: MessageStoreError.invalidTransition) { try await store.retryOutgoing(accountID: "a", messageID: "1") }
    let a = try #require(await store.claimNextOutgoing(accountID: "a"))
    _ = try await store.claimNextOutgoing(accountID: "b")
    await #expect(throws: MessageStoreError.invalidTransition) { try await store.failQueuedOutgoing(accountID: "a", messageID: "1") }
    try await store.recoverInterruptedSubmissions(accountID: "a")
    #expect(try await store.messages(accountID: "a", chatID: "peer").first?.transportState == .unconfirmed)
    #expect(try await store.claimNextOutgoing(accountID: "a") == nil) // an uncertain send is never replayed on its own
    #expect(try await store.messages(accountID: "b", chatID: "peer").first?.transportState == .submitting)
    #expect(try await !store.finishOutgoingSubmission(a))
    try await store.retryOutgoing(accountID: "a", messageID: "1")
    try await store.failQueuedOutgoing(accountID: "a", messageID: "1")
    #expect(try await store.messages(accountID: "a", chatID: "peer").first?.transportState == .failed)
    #expect(try await store.claimNextOutgoing(accountID: "a") == nil)
    try await store.retryOutgoing(accountID: "a", messageID: "1")
    let unsent = try #require(await store.claimNextOutgoing(accountID: "a"))
    #expect(try await store.releaseUnsentSubmission(unsent))
    #expect(try await !store.finishOutgoingSubmission(unsent))
    #expect(try await store.claimNextOutgoing(accountID: "a") != nil)
}

@Test func canceledClaimDoesNotConsumeQueuedWork() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    try await store.enqueueOutgoing(outgoing("1"))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.claimNextOutgoing(accountID: "a")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.claimNextOutgoing(accountID: "a")?.message.id == "1")
}

/// A process suspended holding the transport lock is killed, so a release whose bookkeeping fails must still free it.
@Test func failedReleaseStillFreesTheTransportLockForTheNextOwner() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let owner = try MessageStore(url: url)
    let contender = try MessageStore(url: url)
    try await owner.acquireTransportOwnership()
    // What the app's expiring background time checks; other tests may hold locks too, so only this side is certain.
    #expect(MessageStore.processHoldsTransportLock)
    try await owner.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    try await owner.enqueueOutgoing(outgoing("1"))
    _ = try #require(await owner.claimNextOutgoing(accountID: "a"))
    // Another connection keeps the database busy past the busy timeout, so marking the submission cannot commit.
    var other: OpaquePointer?
    try #require(sqlite3_open(url.path, &other) == SQLITE_OK)
    defer { sqlite3_close(other) }
    try #require(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    do {
        try await owner.releaseTransportOwnership()
        Issue.record("release committed while another connection held the write lock")
    } catch MessageStoreError.database(let code, _) {
        #expect(code == SQLITE_BUSY)
    }
    #expect(await !owner.holdsTransportOwnership)
    try await contender.acquireTransportOwnership()
    try #require(sqlite3_exec(other, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    // Left as it was for the next owner, which marks it uncertain before sending anything.
    #expect(try await contender.messages(accountID: "a", chatID: "peer").first?.transportState == .submitting)
    try await contender.recoverInterruptedSubmissions(accountID: "a")
    #expect(try await owner.messages(accountID: "a", chatID: "peer").first?.transportState == .unconfirmed)
    try await contender.close()
    try await owner.close()
}
