import Foundation
import Darwin
import SQLite3
import Testing
@testable import MessageStore

/// The schema this build writes. A schema bump changes this one literal.
private let currentSchemaVersion: Int32 = 25

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

    /// v24 adds where a returned send's reason lives; a v23 outbox keeps its rows and states and can record one.
    @Test func aVersion23OutboxGainsRejectionsAndKeepsItsWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "rejection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let old = try MessageStore(url: url)
        try await old.acquireTransportOwnership()
        try await old.upsertChat(accountID: "self", chatID: "peer", title: "Peer")
        try await old.enqueueOutgoing(StoredMessage(id: "m", accountID: "self", chatID: "peer", senderID: "self", body: "hi", isOutgoing: true))
        try await old.finishOutgoingSubmission(#require(await old.claimNextOutgoing(accountID: "self")))
        try await old.close()
        #expect(sqliteExecute(url: url, sql: "ALTER TABLE outbox DROP COLUMN rejection; ALTER TABLE outbox DROP COLUMN returned; ALTER TABLE outgoing_updates DROP COLUMN rejection; ALTER TABLE outgoing_updates DROP COLUMN returned; PRAGMA user_version=23"))

        let store = try MessageStore(url: url)
        try await store.acquireTransportOwnership()
        #expect(try await store.message(accountID: "self", messageID: "m")?.transportState == .unconfirmed)
        #expect(try await store.rejectOutgoing(accountID: "self", chatID: "peer", wireID: "m", rejection: "item-not-found") != nil)
        #expect(try await store.message(accountID: "self", messageID: "m")?.rejection == "item-not-found")
        try await store.close()
    }

    /// v25 adds the plain-text device ID of each state row and the retired own devices; a v24 row keeps its state and
    /// has no recorded ID until a build reads it.
    @Test func aVersion24StateRowGainsADeviceIDColumnAndTheRetiredTable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "device-id-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let old = try MessageStore(url: url)
        try await old.saveEncryptionState(accountID: "self", expectedRevision: nil, data: Data([1, 2]))
        try await old.close()
        #expect(sqliteExecute(url: url, sql: "ALTER TABLE encryption_state DROP COLUMN device_id; DROP TABLE retired_own_devices; PRAGMA user_version=24"))

        let store = try MessageStore(url: url)
        #expect(try await store.encryptionState(accountID: "self") == EncryptionState(revision: 1, data: Data([1, 2])))
        #expect(try await store.retiredOwnDevices(accountID: "self").isEmpty)
        try await store.recordEncryptionDeviceID(accountID: "self", deviceID: 42)
        #expect(try await store.encryptionState(accountID: "self")?.deviceID == 42)
        try await store.close()
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
        // Sealed with the typed spelling as associated data: the reader is told which spelling to open it with.
        #expect(try await store.encryptionState(accountID: account) == EncryptionState(revision: 1, data: Data([1, 2, 3]), sealedAccount: typed))
        // A collision keeps both identities: the normal spelling's is untouched, the other stays where it was.
        #expect(try await store.encryptionState(accountID: "other@example.org")?.data == Data([5]))
        #expect(try await store.encryptionState(accountID: "Other@Example.org")?.data == Data([4]))
        #expect(try await store.chats(accountID: typed).isEmpty)
        try await store.close()
    }

    /// Both spellings of one account hold the same archived message (signed in once as typed, once lowercase), and
    /// the file already has a foreign-key violation unrelated to addresses. Neither blocks the rewrite: the normal
    /// copy is reachable, the typed copy stays intact with its chat, and the store is stamped v23.
    @Test func collidingMessagesAndUnrelatedViolationsDoNotBlockTheRewrite() async throws {
        try await withEncryptedStore(account: "ellie@example.org") { old, url in
            let typed = "Ellie@Example.org", account = "ellie@example.org", sentAt = Date(timeIntervalSince1970: 1_700_000_000)
            for owner in [typed, account] {
                try await old.upsertChat(accountID: owner, chatID: "bob@example.org", title: "Bob")
                try await old.insertMessage(StoredMessage(id: "archived", accountID: owner, chatID: "bob@example.org", senderID: "bob@example.org",
                                                          body: owner, sentAt: sentAt, isOutgoing: false))
            }
            try await old.upsertChat(accountID: typed, chatID: "Carol@Example.org", title: "Carol@Example.org")
            try await old.insertMessage(StoredMessage(id: "only-typed", accountID: typed, chatID: "Carol@Example.org", senderID: typed,
                                                      body: "hello", sentAt: sentAt, isOutgoing: true))
            try await old.close()
            #expect(sqliteExecute(url: url, sql: """
                PRAGMA foreign_keys=OFF; INSERT INTO outbox(account_id,message_id,state) VALUES('carol@example.org','orphan','queued');
                PRAGMA user_version=21;
                """))
            let store = try MessageStore(url: url)
            #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["\(MessageStore.currentSchemaVersion)"]])
            #expect(try await store.messages(accountID: account, chatID: "bob@example.org").map(\.body) == [account])
            #expect(try await store.messages(accountID: typed, chatID: "bob@example.org").map(\.body) == [typed])
            #expect(try await store.messages(accountID: account, chatID: "carol@example.org").map(\.id) == ["only-typed"])
            // Titled with the address it was started with, which follows the chat into normal form.
            #expect(try await store.chats(accountID: account).first { $0.id == "carol@example.org" }?.title == "carol@example.org")
            try await store.close()
        }
    }

    /// A rewrite that would leave a row pointing at nothing is rolled back whole. The store still opens, keeps every
    /// row where it was, and stays below v23 so a later build tries again rather than stranding the typed spelling.
    @Test func aRewriteThatBreaksAForeignKeyIsRolledBackAndRetried() async throws {
        try await withEncryptedStore(account: "Ellie@Example.org", chats: [("bob@example.org", "Bob")]) { old, url in
            let typed = "Ellie@Example.org"
            try await old.insertMessage(StoredMessage(id: "m1", accountID: typed, chatID: "bob@example.org", senderID: typed,
                                                      body: "hi", sentAt: Date(timeIntervalSince1970: 1_700_000_000), isOutgoing: true))
            try await old.close()
            // An outbox row under the normal spelling with no message: the typed one cannot move onto it, and stays
            // pointing at a message that did move.
            #expect(sqliteExecute(url: url, sql: """
                INSERT INTO outbox(account_id,message_id,state) VALUES('Ellie@Example.org','m1','queued');
                PRAGMA foreign_keys=OFF; INSERT INTO outbox(account_id,message_id,state) VALUES('ellie@example.org','m1','queued');
                PRAGMA user_version=21;
                """))
            let store = try MessageStore(url: url)
            // The rewrite is rolled back; the v22 migration before it stands.
            #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["22"]])
            #expect(try await store.messages(accountID: typed, chatID: "bob@example.org").map(\.id) == ["m1"])
            #expect(try await store.encryptionState(accountID: typed)?.data == Data([0]))
            try await store.close()
        }
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
