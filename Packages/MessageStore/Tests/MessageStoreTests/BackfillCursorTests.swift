import Foundation
import Testing
import SQLite3
@testable import MessageStore

private func backfillStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "backfill-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "messages.sqlite")
}

private func rows(_ url: URL, _ sql: String) -> [[String]] {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var result: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        result.append((0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
        })
    }
    return result
}

private func execute(_ url: URL, _ sql: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { return false }
    defer { sqlite3_close(db) }
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}

@Test func backfillCursorRoundTripsAndUsesRevisionCAS() async throws {
    let url = try backfillStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    // Writing requires transport ownership, like the forward checkpoint.
    await #expect(throws: MessageStoreError.transportOwnershipRequired) {
        try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "a@x", expectedRevision: nil, oldestID: "m1", complete: false)
    }
    try await store.acquireTransportOwnership()
    #expect(try await store.archiveBackfillCursor(accountID: "a@x", archiveID: "a@x") == nil)
    #expect(try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "a@x", expectedRevision: nil, oldestID: "m1", complete: false) == 1)
    #expect(try await store.archiveBackfillCursor(accountID: "a@x", archiveID: "a@x") == ArchiveBackfillCursor(revision: 1, oldestID: "m1", complete: false))
    #expect(try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "a@x", expectedRevision: 1, oldestID: "m0", complete: true) == 2)
    #expect(try await store.archiveBackfillCursor(accountID: "a@x", archiveID: "a@x") == ArchiveBackfillCursor(revision: 2, oldestID: "m0", complete: true))
    // A stale run cannot rewind newer progress, and a second "first" write cannot replace an existing row.
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "a@x", expectedRevision: 1, oldestID: "stale", complete: false)
    }
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "a@x", expectedRevision: nil, oldestID: "stale", complete: false)
    }
    #expect(try await store.archiveBackfillCursor(accountID: "a@x", archiveID: "a@x")?.oldestID == "m0")
    // Rooms and accounts are separate rows.
    #expect(try await store.archiveBackfillCursor(accountID: "a@x", archiveID: "room@rooms.x") == nil)
    #expect(try await store.archiveBackfillCursor(accountID: "b@x", archiveID: "a@x") == nil)
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "room@rooms.x", expectedRevision: nil, oldestID: "", complete: false)
    }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "room@rooms.x", expectedRevision: nil,
                                                  oldestID: String(repeating: "x", count: 4097), complete: false)
    }
    try await store.close()
}

@Test func schemaSixteenUpgradesV15FilesIdempotently() async throws {
    let url = try backfillStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await MessageStore(url: url).close()
    #expect(rows(url, "SELECT name FROM sqlite_master WHERE type='table' AND name='archive_backfill'") == [["archive_backfill"]])

    // Reopening keeps the version and the table's rows (the CREATE is not repeated destructively).
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "a@x", expectedRevision: nil, oldestID: "m1", complete: false)
    try await store.close()
    try await MessageStore(url: url).close()
    #expect(rows(url, "SELECT revision,oldest_id,complete FROM archive_backfill") == [["1", "m1", "0"]])

    // A v15 file (no table) upgrades and keeps its other rows.
    let v15 = try MessageStore(url: url)
    try await v15.upsertChat(accountID: "a@x", chatID: "peer@x", title: "Peer")
    try await v15.close()
    #expect(execute(url, "DROP TABLE archive_backfill; PRAGMA user_version=15;"))
    let upgraded = try MessageStore(url: url)
    #expect(try await upgraded.archiveBackfillCursor(accountID: "a@x", archiveID: "a@x") == nil)
    #expect(try await upgraded.chats(accountID: "a@x").map(\.title) == ["Peer"])
    try await upgraded.close()
    #expect(rows(url, "SELECT name FROM sqlite_master WHERE type='table' AND name='archive_backfill'") == [["archive_backfill"]])
}

@Test func newestArchivePageSavesBothCursorsTogetherAndReplacesAnOrphanedBackfillRow() async throws {
    let url = try backfillStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    await #expect(throws: MessageStoreError.transportOwnershipRequired) {
        try await store.saveNewestArchivePage(accountID: "a@x", archiveID: "a@x", cursor: "n2", oldestID: "n1", complete: false)
    }
    try await store.acquireTransportOwnership()
    #expect(try await store.saveNewestArchivePage(accountID: "a@x", archiveID: "a@x", cursor: "n2", oldestID: "n1", complete: false) == 1)
    #expect(try await store.archiveCheckpoint(accountID: "a@x", archiveID: "a@x") == ArchiveCheckpoint(revision: 1, cursor: "n2"))
    #expect(try await store.archiveBackfillCursor(accountID: "a@x", archiveID: "a@x") == ArchiveBackfillCursor(revision: 1, oldestID: "n1", complete: false))
    // Only the first page of an archive: with a checkpoint in place nothing changes.
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await store.saveNewestArchivePage(accountID: "a@x", archiveID: "a@x", cursor: "n9", oldestID: "n8", complete: true)
    }
    #expect(try await store.archiveCheckpoint(accountID: "a@x", archiveID: "a@x")?.cursor == "n2")
    #expect(try await store.archiveBackfillCursor(accountID: "a@x", archiveID: "a@x")?.oldestID == "n1")

    // A backfill row with no checkpoint (an earlier build's interrupted first sync) is replaced, not kept behind a gap.
    _ = try await store.saveArchiveBackfillCursor(accountID: "a@x", archiveID: "room@rooms.x", expectedRevision: nil, oldestID: "old", complete: true)
    #expect(try await store.saveNewestArchivePage(accountID: "a@x", archiveID: "room@rooms.x", cursor: "r9", oldestID: "r5", complete: false) == 1)
    #expect(try await store.archiveBackfillCursor(accountID: "a@x", archiveID: "room@rooms.x") == ArchiveBackfillCursor(revision: 2, oldestID: "r5", complete: false))
    #expect(try await store.archiveCheckpoint(accountID: "a@x", archiveID: "room@rooms.x")?.cursor == "r9")
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.saveNewestArchivePage(accountID: "a@x", archiveID: "b@x", cursor: "", oldestID: "n1", complete: false)
    }
    #expect(try await store.archiveCheckpoint(accountID: "a@x", archiveID: "b@x") == nil)
    try await store.close()
}
