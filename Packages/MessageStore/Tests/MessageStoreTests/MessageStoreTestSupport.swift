import Foundation
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
