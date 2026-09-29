import Foundation
import Darwin
import SQLite3
import Testing
@testable import MessageStore

/// The schema this build writes. A schema bump changes this one literal.
private let currentSchemaVersion: Int32 = 23

struct MigrationTests {
    @Test func openingStampsTheCurrentSchemaAndRefusesANewerOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "schema-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        try await MessageStore(url: url).close()
        var db: OpaquePointer?, statement: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == currentSchemaVersion)
        sqlite3_finalize(statement)
        // A database written by a newer build is refused, never downgraded.
        #expect(sqlite3_exec(db, "PRAGMA user_version=\(currentSchemaVersion + 1);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(throws: MessageStoreError.unsupportedSchema(Int(currentSchemaVersion) + 1)) { _ = try MessageStore(url: url) }
    }

    /// A v21 store written by a build that kept typed capitals: the account `Ellie@Example.org`, and chats with
    /// `Bob@Example.org` (started by hand) and `bob@example.org` (the server's spelling on his replies). Opening it
    /// normalises every key, merges the two chats without losing a message, keeps the later read pointer and the
    /// encryption identity, and never overwrites an identity already saved under the normal spelling.
    @Test func addressesMigrateToNormalFormAndSpellingDuplicatesMerge() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "addresses-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let typed = "Ellie@Example.org", account = "ellie@example.org", start = Date(timeIntervalSince1970: 1_700_000_000)
        let old = try MessageStore(url: url)
        try await old.acquireTransportOwnership()
        try await old.saveEncryptionState(accountID: typed, expectedRevision: nil, data: Data([1, 2, 3]))
        try await old.saveEncryptionState(accountID: "Other@Example.org", expectedRevision: nil, data: Data([4]))
        try await old.saveEncryptionState(accountID: "other@example.org", expectedRevision: nil, data: Data([5]))
        for (chat, sender, offset) in [("Bob@Example.org", typed, 0.0), ("bob@example.org", "bob@example.org", 60), ("Bob@Example.org", "Bob@Example.org", 120)] {
            try await old.upsertChat(accountID: typed, chatID: chat, title: "Bob")
            try await old.insertMessage(StoredMessage(id: "m\(Int(offset))", accountID: typed, chatID: chat, senderID: sender, body: "hi",
                                                      sentAt: start.addingTimeInterval(offset), isOutgoing: sender == typed))
        }
        try await old.setPinned(accountID: typed, chatID: "Bob@Example.org", pinned: true)
        try await old.markChatRead(accountID: typed, chatID: "Bob@Example.org")
        try await old.markChatRead(accountID: typed, chatID: "bob@example.org")
        try await old.close()
        #expect(sqliteExecute(url: url, sql: "PRAGMA user_version=21"))

        let store = try MessageStore(url: url)
        let chats = try await store.chats(accountID: account)
        #expect(chats.map(\.id) == ["bob@example.org"])
        #expect(chats.first?.isPinned == true)
        let messages = try await store.messages(accountID: account, chatID: "bob@example.org")
        #expect(messages.map(\.id) == ["m0", "m60", "m120"])
        #expect(Set(messages.map(\.senderID)) == [account, "bob@example.org"])
        // The pointer from the chat started by hand (at m120) is later than the other's (m60).
        #expect(try await store.unreadCounts(accountID: account)["bob@example.org"] ?? 0 == 0)
        #expect(try await store.encryptionState(accountID: account)?.data == Data([1, 2, 3]))
        // A collision keeps both identities: the normal spelling's is untouched, the other stays where it was.
        #expect(try await store.encryptionState(accountID: "other@example.org")?.data == Data([5]))
        #expect(try await store.encryptionState(accountID: "Other@Example.org")?.data == Data([4]))
        #expect(try await store.chats(accountID: typed).isEmpty)
        try await store.close()
    }

    @Test func migrationClosesSQLiteAndHoldsLockAcrossRename() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID())")
        let source = root.appending(path: "old"), destination = root.appending(path: "new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let db = source.appending(path: "messages.sqlite")
        let store = try MessageStore(url: db)
        try await store.acquireTransportOwnership()
        try await store.saveEncryptionState(accountID: "synthetic", expectedRevision: nil, data: Data([7, 8, 9]))
        try await store.closeForMigration {
            // Closing the final SQLite connection checkpoints committed data. Some Apple
            // SQLite builds retain WAL files, so verify a main-file-only copy instead.
            try FileManager.default.copyItem(at: db, to: root.appending(path: "checkpoint.sqlite"))
            try FileManager.default.moveItem(at: source, to: destination)
            let descriptor = Darwin.open(destination.appending(path: "messages.sqlite.transport-lock").path, O_RDWR | O_NOFOLLOW)
            #expect(descriptor >= 0)
            defer { Darwin.close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK)
        }
        await #expect(throws: MessageStoreError.closed) { try await store.encryptionState(accountID: "synthetic") }
        let checkpoint = try MessageStore(url: root.appending(path: "checkpoint.sqlite"))
        #expect(try await checkpoint.encryptionState(accountID: "synthetic")?.data == Data([7, 8, 9]))
        try await checkpoint.close()
        let moved = try MessageStore(url: destination.appending(path: "messages.sqlite"))
        try await moved.acquireTransportOwnership()
        #expect(try await moved.encryptionState(accountID: "synthetic")?.data == Data([7, 8, 9]))
        try await moved.close()
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }

    @Test func failedMoveLeavesClosedSourceRecoverableAndUnlocked() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "migration-failure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: db)
        try await store.acquireTransportOwnership()
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.closeForMigration { throw MessageStoreError.invalidValue }
        }
        let reopened = try MessageStore(url: db)
        try await reopened.acquireTransportOwnership()
        try await reopened.close()
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }
}
