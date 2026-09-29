import Foundation
import Testing
@testable import MessageStore

private func databaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("messages.sqlite")
}

private func message(_ id: String, account: String = "a", body: String = "hello", time: Double = 100) -> StoredMessage {
    StoredMessage(id: id, accountID: account, chatID: "peer", senderID: "peer", body: body,
                  sentAt: Date(timeIntervalSince1970: time))
}

@Test func literalSearchNeverInterpretsQueryAsSQLOrWildcards() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    try await store.upsertChat(accountID: "b", chatID: "peer", title: "Peer")
    try await store.insertMessage(message("1", body: "Save 100%_ 'quoted' tea ☕️"))
    try await store.insertMessage(message("2", body: "plain tea"))
    try await store.insertMessage(message("1", account: "b", body: "secret tea"))
    #expect(try await store.search(accountID: "a", query: "%_").map(\.id) == ["1"])
    #expect(try await store.search(accountID: "a", query: "'quoted'").map(\.id) == ["1"])
    #expect(try await store.search(accountID: "a", query: "' OR 1=1 --").isEmpty)
    #expect(try await store.search(accountID: "a", query: "TEA").count == 2)
    #expect(try await store.search(accountID: "a", query: "☕️").count == 1)
    #expect(try await store.search(accountID: "a", query: "tea", chatID: "missing").isEmpty)
}

@Test func timestampTiesPageWithoutLosingMessagesAndPinUpdatesPreserveTitle() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    for id in ["1", "2", "3"] { try await store.insertMessage(message(id)) }
    let page = try await store.messages(accountID: "a", chatID: "peer", limit: 2)
    #expect(page.map(\.id) == ["2", "3"])
    let older = try await store.messages(accountID: "a", chatID: "peer", limit: 2, before: page.first)
    #expect(older.map(\.id) == ["1"])
    try await store.setPinned(accountID: "a", chatID: "peer", pinned: true)
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Renamed")
    let chats = try await store.chats(accountID: "a")
    #expect(chats.first?.title == "Renamed")
    #expect(chats.first?.isPinned == true)
}
