import Foundation
import Testing
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
