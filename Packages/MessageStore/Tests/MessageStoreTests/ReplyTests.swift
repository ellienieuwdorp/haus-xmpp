import Foundation
import Testing
import CSQLite
@testable import MessageStore

private func replyFixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("messages.sqlite")
}
private func replyMessage(_ reply: MessageReply?) -> StoredMessage {
    StoredMessage(id: "reply", accountID: "a", chatID: "peer", senderID: "a", body: "answer",
                  sentAt: Date(timeIntervalSince1970: 200), isOutgoing: true, reply: reply)
}

@Test func replySnapshotSurvivesReopenSearchAndRetryWithStableWireReference() async throws {
    let url = try replyFixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let quote = MessageReply(messageID: "original-local", senderID: "peer", body: "Quoted ☕️\nsecond line", wireID: "original-wire")
    var store: MessageStore? = try MessageStore(url: url)
    try await store!.acquireTransportOwnership()
    try await store!.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    try await store!.enqueueOutgoing(replyMessage(quote))
    #expect(try await !store!.enqueueOutgoing(replyMessage(quote)))
    let first = try #require(await store!.claimNextOutgoing(accountID: "a"))
    #expect(first.message.reply == quote)
    store = nil
    let reopened = try MessageStore(url: url)
    try await reopened.acquireTransportOwnership()
    try await reopened.recoverInterruptedSubmissions(accountID: "a")
    #expect(try await reopened.messages(accountID: "a", chatID: "peer").first?.reply == quote)
    #expect(try await reopened.search(accountID: "a", query: "answer").first?.reply == quote)
    #expect(try await reopened.chats(accountID: "a").first?.lastMessage?.reply == quote)
    try await reopened.retryOutgoing(accountID: "a", messageID: "reply")
    let retry = try #require(await reopened.claimNextOutgoing(accountID: "a"))
    #expect(retry.message.reply == quote)
    #expect(retry.message.id == first.message.id)
    #expect(try await reopened.search(accountID: "b", query: "answer").isEmpty)
}

@Test func changedReplyIsConflictingPayloadAndInvalidSnapshotRollsBack() async throws {
    let url = try replyFixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    for quote in [MessageReply(messageID: "", senderID: "peer", body: "quote"),
                  MessageReply(messageID: "original", senderID: "peer", body: String(repeating: "x", count: 16_385)),
                  MessageReply(messageID: "original", senderID: "peer", body: "quote", wireID: "")] {
        await #expect(throws: MessageStoreError.invalidValue) { try await store.enqueueOutgoing(replyMessage(quote)) }
    }
    #expect(try await store.messages(accountID: "a", chatID: "peer").isEmpty)
    #expect(try await store.claimNextOutgoing(accountID: "a") == nil)
    let quote = MessageReply(messageID: "original", senderID: "peer", body: "quote")
    try await store.enqueueOutgoing(replyMessage(quote))
    for changed in [nil, MessageReply(messageID: "original", senderID: "peer", body: "changed"),
                    MessageReply(messageID: "original", senderID: "peer", body: "quote", wireID: "new")] as [MessageReply?] {
        await #expect(throws: MessageStoreError.conflictingIdentity) { try await store.enqueueOutgoing(replyMessage(changed)) }
    }
}

@Test func v2MigrationPreservesQueuedWorkAndOrganizationWithoutInventingReply() async throws {
    let url = try replyFixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let sql = """
        CREATE TABLE chats(account_id TEXT NOT NULL,id TEXT NOT NULL,title TEXT NOT NULL,pinned INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(account_id,id));
        CREATE TABLE messages(account_id TEXT NOT NULL,id TEXT NOT NULL,chat_id TEXT NOT NULL,sender_id TEXT NOT NULL,body TEXT NOT NULL,sent_at REAL NOT NULL,outgoing INTEGER NOT NULL,starred INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(account_id,id),FOREIGN KEY(account_id,chat_id) REFERENCES chats(account_id,id));
        CREATE TABLE outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT,account_id TEXT NOT NULL,message_id TEXT NOT NULL,state TEXT NOT NULL,attempt_id TEXT,UNIQUE(account_id,message_id),FOREIGN KEY(account_id,message_id) REFERENCES messages(account_id,id));
        INSERT INTO chats VALUES('a','peer','Peer',1);
        INSERT INTO messages VALUES('a','legacy','peer','a','hello',100,1,1);
        INSERT INTO outbox(account_id,message_id,state) VALUES('a','legacy','queued');
        PRAGMA user_version=2;
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    let chat = try #require(await store.chats(accountID: "a").first)
    #expect(chat.isPinned && chat.lastMessage?.isStarred == true)
    #expect(chat.lastMessage?.reply == nil)
    let claim = try #require(await store.claimNextOutgoing(accountID: "a"))
    #expect(claim.message.id == "legacy" && claim.message.reply == nil)
    try await store.enqueueOutgoing(replyMessage(MessageReply(messageID: "legacy", senderID: "a", body: "hello")))
    #expect(try await store.claimNextOutgoing(accountID: "a")?.message.reply?.messageID == "legacy")
}
