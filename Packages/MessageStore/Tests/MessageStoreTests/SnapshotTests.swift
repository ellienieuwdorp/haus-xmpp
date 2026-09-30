import Foundation
import CSQLite
import Testing
@testable import MessageStore

/// The pre-upgrade snapshot path: an older build's store is opened without migrating, copied under the lease, and only
/// then migrated. Other processes open `currentOnly` and must leave an older store exactly as it is.
struct SnapshotTests {
    private let previousVersion = 21

    /// The previous build's store (a real schema-21 file, `writePreviousReleaseStore`) with its three messages in the
    /// main file and `walMessages` more committed through a connection that stays open, so they exist only as WAL
    /// frames. Returns that connection; close it with `sqlite3_close`.
    private func previousBuildStore(at url: URL, walMessages: Int) async throws -> OpaquePointer? {
        try writePreviousReleaseStore(at: url)
        var writer: OpaquePointer?
        #expect(sqlite3_open(url.path, &writer) == SQLITE_OK)
        #expect(sqlite3_exec(writer, "PRAGMA wal_autocheckpoint=0", nil, nil, nil) == SQLITE_OK)
        for index in 0..<walMessages {
            let sql = "INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing) VALUES('Ellie@Example.org','wal-\(index)','bob@example.org','bob@example.org','late',1790000100,0)"
            #expect(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
        }
        return writer
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    @Test func snapshotIncludesUncheckpointedFramesAndLeavesTheSourceAsTheOldBuildWroteIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite"), copy = directory.appending(path: "snapshot.sqlite")
        let writer = try await previousBuildStore(at: url, walMessages: 5)
        defer { sqlite3_close(writer) }
        let walBefore = try #require(bytes(URL(filePath: url.path + "-wal")))
        #expect(!walBefore.isEmpty)
        let mainBefore = bytes(url)

        let store = try MessageStore(url: url, schema: .asIs)
        #expect(store.openedSchemaVersion == previousVersion)
        await #expect(throws: MessageStoreError.transportOwnershipRequired) { _ = try await store.writeSnapshot(to: copy) }
        try await store.acquireTransportOwnership()
        let summary = try await store.writeSnapshot(to: copy)
        try await store.close()

        #expect(summary.schemaVersion == previousVersion)
        #expect(summary.rowCounts["messages"] == 8)
        // The copy is a standalone file with every committed row, the WAL frames included.
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-shm"))
        #expect(sqliteRows(url: copy, sql: "PRAGMA journal_mode") == [["delete"]])
        #expect(sqliteRows(url: copy, sql: "SELECT id FROM messages ORDER BY id").flatMap { $0 } ==
                ["old-0", "old-1", "old-2", "wal-0", "wal-1", "wal-2", "wal-3", "wal-4"])
        #expect(sqliteRows(url: copy, sql: "PRAGMA user_version") == [["\(previousVersion)"]])
        #expect(sqliteRows(url: copy, sql: "PRAGMA integrity_check") == [["ok"]])
        // Reading never checkpointed, migrated or restamped the source: the main file is byte for byte what the old
        // build left, and its uncheckpointed frames are still in its WAL.
        #expect(bytes(url) == mainBefore)
        #expect(bytes(URL(filePath: url.path + "-wal"))?.prefix(walBefore.count) == walBefore)
        #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["\(previousVersion)"]])
        #expect(sqliteRows(url: url, sql: "PRAGMA journal_mode") == [["wal"]])
        try MessageStore.verifySnapshot(at: copy, matches: summary)
    }

    @Test func verificationRejectsACopyThatDiffersFromItsSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite"), copy = directory.appending(path: "snapshot.sqlite")
        sqlite3_close(try await previousBuildStore(at: url, walMessages: 0))
        let store = try MessageStore(url: url, schema: .asIs)
        try await store.acquireTransportOwnership()
        let summary = try await store.writeSnapshot(to: copy)
        try await store.close()
        #expect(sqliteExecute(url: copy, sql: "DELETE FROM messages WHERE id='old-0'"))
        #expect(throws: MessageStoreError.snapshotMismatch("row counts differ: messages")) {
            try MessageStore.verifySnapshot(at: copy, matches: summary)
        }
        #expect(sqliteExecute(url: copy, sql: "PRAGMA user_version=23"))
        #expect(throws: MessageStoreError.snapshotMismatch("schema 23 != 21")) { try MessageStore.verifySnapshot(at: copy, matches: summary) }
    }

    /// The notification extension's open: an older store is refused before anything is written to it, and neither
    /// that open nor the snapshot path creates a store that is not there.
    @Test func currentOnlyRefusesAnOlderStoreWithoutWritingToIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        sqlite3_close(try await previousBuildStore(at: url, walMessages: 0))
        let before = bytes(url)
        #expect(throws: MessageStoreError.upgradeRequired(previousVersion)) { _ = try MessageStore(url: url, schema: .currentOnly) }
        #expect(bytes(url) == before)
        #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["\(previousVersion)"]])
        let missing = directory.appending(path: "absent.sqlite")
        #expect(throws: (any Error).self) { _ = try MessageStore(url: missing, schema: .currentOnly) }
        #expect(throws: (any Error).self) { _ = try MessageStore(url: missing, schema: .asIs) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func upgradeAfterTheSnapshotNeedsTheLeaseAndReachesTheCurrentSchema() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        sqlite3_close(try await previousBuildStore(at: url, walMessages: 2))
        let store = try MessageStore(url: url, schema: .asIs)
        await #expect(throws: MessageStoreError.transportOwnershipRequired) { try await store.upgradeSchema() }
        try await store.acquireTransportOwnership()
        try await store.upgradeSchema()
        #expect(try await store.messages(accountID: "ellie@example.org", chatID: "bob@example.org").count == 5)
        try await store.close()
        #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["\(MessageStore.currentSchemaVersion)"]])
        try await MessageStore(url: url, schema: .currentOnly).close()
    }

    /// A process that opened the store before a restore swapped the file never gets the lease over the new file.
    @Test func aStoreWhoseFileWasReplacedIsRefusedTheLease() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite"), other = directory.appending(path: "other.sqlite")
        try await MessageStore(url: url).close()
        try await MessageStore(url: other).close()
        let stale = try MessageStore(url: url, schema: .currentOnly)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: other, to: url)
        await #expect(throws: MessageStoreError.replaced) { try await stale.acquireTransportOwnership() }
        try await stale.close()
        // The refused store did not keep the lease: a store over the new file takes it.
        let fresh = try MessageStore(url: url, schema: .currentOnly)
        try await fresh.acquireTransportOwnership()
        try await fresh.close()
    }

    /// What restoring older data would roll back: chats where an encrypted message was sent since the snapshot.
    @Test func chatsWithEncryptedSendsSinceADate() async throws {
        try await withEncryptedStore(account: "ellie@example.org", chats: [("a@example.org", "Alice"), ("b@example.org", "Bob"),
                                                                           ("c@example.org", "Carol"), ("d@example.org", "Dan")]) { store, _ in
            let since = Date(timeIntervalSince1970: 1_700_000_000)
            for (chat, outgoing, profile, offset) in [("a@example.org", true, "legacy", 10.0), ("b@example.org", true, nil, 10),
                                                     ("c@example.org", true, "modern", -10), ("d@example.org", false, "modern", 10)] as [(String, Bool, String?, Double)] {
                try await store.insertMessage(StoredMessage(id: chat, accountID: "ellie@example.org", chatID: chat,
                                                            senderID: outgoing ? "ellie@example.org" : chat, body: "x",
                                                            sentAt: since.addingTimeInterval(offset), isOutgoing: outgoing, encryptionProfile: profile))
            }
            #expect(try await store.chatsWithEncryptedSends(accountID: "ellie@example.org", since: since) == ["Alice"])
        }
    }
}
