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
    #expect(try await store.claimNextOutgoing(accountID: "b")?.message.accountID == "b")
}

@Test func processRecoveryPreservesQueueAndNeverReplaysUncertainSend() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var store: MessageStore? = try MessageStore(url: url)
    try await store!.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    for id in ["crashed", "queued"] { try await store!.enqueueOutgoing(outgoing(id)) }
    let interrupted = try #require(await store!.claimNextOutgoing(accountID: "a"))
    store = nil
    let reopened = try MessageStore(url: url)
    #expect(try await reopened.messages(accountID: "a", chatID: "peer").first { $0.id == "crashed" }?.transportState == .unconfirmed)
    #expect(try await reopened.claimNextOutgoing(accountID: "a")?.message.id == "queued")
    #expect(try await reopened.claimNextOutgoing(accountID: "a") == nil)
    #expect(try await !reopened.finishOutgoingSubmission(interrupted))
    try await reopened.retryOutgoing(accountID: "a", messageID: "crashed")
    let retry = try #require(await reopened.claimNextOutgoing(accountID: "a"))
    #expect(retry.message.id == interrupted.message.id)
    #expect(retry.attemptID != interrupted.attemptID)
    #expect(try await !reopened.releaseUnsentSubmission(interrupted))
    #expect(try await reopened.finishOutgoingSubmission(retry))
    #expect(try await !reopened.finishOutgoingSubmission(retry))
    #expect(try await reopened.claimNextOutgoing(accountID: "a") == nil)
}

@Test func invalidTransitionsAndExplicitRecoveryAreAccountScoped() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
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
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    try await store.enqueueOutgoing(outgoing("1"))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.claimNextOutgoing(accountID: "a")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.claimNextOutgoing(accountID: "a")?.message.id == "1")
}

@Test func migrationFromV1PreservesHistoryStarsPinsWithoutReplayingLegacyMessages() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let sql = """
        CREATE TABLE chats(account_id TEXT NOT NULL,id TEXT NOT NULL,title TEXT NOT NULL,pinned INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(account_id,id));
        CREATE TABLE messages(account_id TEXT NOT NULL,id TEXT NOT NULL,chat_id TEXT NOT NULL,sender_id TEXT NOT NULL,body TEXT NOT NULL,sent_at REAL NOT NULL,outgoing INTEGER NOT NULL,starred INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(account_id,id),FOREIGN KEY(account_id,chat_id) REFERENCES chats(account_id,id));
        INSERT INTO chats VALUES('a','peer','Peer',1);
        INSERT INTO messages VALUES('a','legacy','peer','a','hello',100,1,1);
        PRAGMA user_version=1;
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let store = try MessageStore(url: url)
    let chat = try #require(await store.chats(accountID: "a").first)
    #expect(chat.isPinned && chat.lastMessage?.isStarred == true)
    #expect(chat.lastMessage?.body == "hello")
    #expect(chat.lastMessage?.transportState == nil)
    #expect(try await store.claimNextOutgoing(accountID: "a") == nil)
    await #expect(throws: MessageStoreError.invalidTransition) { try await store.enqueueOutgoing(outgoing("legacy")) }
    try await store.enqueueOutgoing(outgoing("new"))
    #expect(try await store.claimNextOutgoing(accountID: "a")?.message.id == "new")
}

@Test func concurrentClaimsHaveDistinctWorkAndInvalidBodiesAreRejected() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    for body in ["", String(repeating: "x", count: 65_537)] {
        await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueOutgoing(outgoing("invalid", body: body)) }
    }
    #expect(try await store.messages(accountID: "a", chatID: "peer").isEmpty)
    try await store.enqueueOutgoing(outgoing("one"))
    try await store.enqueueOutgoing(outgoing("two"))
    async let first = store.claimNextOutgoing(accountID: "a")
    async let second = store.claimNextOutgoing(accountID: "a")
    let claims = try await [first, second].compactMap { $0 }
    #expect(Set(claims.map { $0.message.id }) == ["one", "two"])
    #expect(Set(claims.map(\.attemptID)).count == 2)
}
