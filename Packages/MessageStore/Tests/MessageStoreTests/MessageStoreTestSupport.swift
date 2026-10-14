import Foundation
import Testing
import CSQLite
@testable import MessageStore

/// A fresh store in a temporary directory, holding the transport lease, with an encryption state for `account` so
/// authenticated commits can follow and `chats` (id, title) already created. Closed and removed afterwards.
func withEncryptedStore(account: String, chats: [(String, String)] = [], _ operation: (MessageStore, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let store = try MessageStore(url: url)
    do {
        try await store.acquireTransportOwnership()
        try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([0]))
        for (id, title) in chats { try await store.upsertChat(accountID: account, chatID: id, title: title) }
        try await operation(store, url)
        try await store.close()
    } catch { try? await store.close(); throw error }
}

/// Every row of `sql` read straight from the database file, each column as text ("NULL" for null).
func sqliteRows(url: URL, sql: String) -> [[String]] {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var result: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        result.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "NULL" })
    }
    return result
}

/// Runs `sql` straight against the database file, as an older or newer build would have left it.
func sqliteExecute(url: URL, sql: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { return false }
    defer { sqlite3_close(db) }
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}

/// Writes a store a previous build left, from its real dump: schema 21 is the 045ca73 build's (three synthetic messages
/// of `Ellie@Example.org`, as typed, with `bob@example.org`), schema 23 the f563365 build's (the same three, already
/// `ellie@example.org`, plus a group message), schema 24 that store as main at 4df394a migrates it, schema 25 as main
/// at 8115529 migrates that. In
/// write-ahead-log mode, as every one of those builds keeps it.
func writePreviousReleaseStore(at url: URL, schema: Int = 21) throws {
    let fixture = try #require(Bundle.module.url(forResource: "schema-\(schema)", withExtension: "sql", subdirectory: "Fixtures"))
    #expect(sqliteExecute(url: url, sql: try String(contentsOf: fixture, encoding: .utf8) + "PRAGMA journal_mode=WAL;"))
    #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["\(schema)"]])
}
