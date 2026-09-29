import Foundation
import SQLite3
import Testing
@testable import MessageStore

@Test func migrationV13AddsAvatarHashAndKeepsChats() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "avatar-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    // A pre-v13 store: today's schema minus the column, as an upgrade from main would see it.
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    try await store.close()
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "ALTER TABLE chats DROP COLUMN avatar_hash; PRAGMA user_version=11;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    let migrated = try MessageStore(url: url)
    try await migrated.acquireTransportOwnership()
    #expect(try await migrated.chats(accountID: "a").map { ($0.title, $0.avatarHash) }.first! == ("Peer", nil))
    try await migrated.setAvatarHash(accountID: "a", chatID: "peer", hash: "abc123")
    #expect(try await migrated.chats(accountID: "a").first?.avatarHash == "abc123")
    try await migrated.close()
    // The avatars-only tree stamped v12 with the column already present: the migration must not add it again.
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "PRAGMA user_version=12;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let reopened = try MessageStore(url: url)
    #expect(try await reopened.chats(accountID: "a").first?.avatarHash == "abc123")
    try await reopened.setAvatarHash(accountID: "a", chatID: "peer", hash: nil)
    #expect(try await reopened.chats(accountID: "a").first?.avatarHash == nil)
    try await reopened.close()
}
