import Foundation
import Testing
@testable import MessageStore

// Every table the migrations create is declared in `AccountTable`, and each lifecycle surface treats a store holding
// one row in every table (Fixtures/account-tables.sql) as the declarations say.
@Suite struct AccountTablePolicyTests {
    private static let alice = "alice@example.org", bob = "bob@example.org"

    // What is wrong with the store at `url` against `AccountTable`, each as the change that fixes it.
    static func undeclaredTables(at url: URL) -> [String] {
        let tables = sqliteRows(url: url, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").map { $0[0] }
        var problems: [String] = []
        for table in tables {
            if AccountTable(rawValue: table) == nil {
                let name = table.split(separator: "_").enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
                problems.append("""
                    Table `\(table)` has no AccountTable case. In Packages/MessageStore/Sources/MessageStore/AccountTables.swift add \
                    `case \(name) = "\(table)"` and place it in `policy` with its transfer (copy, or omit with a reason) and sign-out \
                    (keep with a reason, or delete) policy; then add one row of it to \
                    Packages/MessageStore/Tests/MessageStoreTests/Fixtures/account-tables.sql.
                    """)
            }
            if sqliteRows(url: url, sql: "SELECT 1 FROM pragma_table_info('\(table)') WHERE name='account_id'").isEmpty {
                problems.append("""
                    Table `\(table)` has no account_id column. Give it one: erasing an account, storedAccountIDs and the AccountTable \
                    policies find an account's rows by that column.
                    """)
            }
        }
        for table in AccountTable.allCases where !tables.contains(table.rawValue) {
            problems.append("AccountTable.\(table) names `\(table.rawValue)`, which no migration creates. Remove the case.")
        }
        return problems
    }

    private static func seed(_ url: URL, account: String) throws {
        let fixture = try #require(Bundle.module.url(forResource: "account-tables", withExtension: "sql", subdirectory: "Fixtures"))
        let sql = try String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: "{account}", with: account)
        #expect(sqliteExecute(url: url, sql: sql), "Fixtures/account-tables.sql applies to a migrated store")
    }

    private static func counts(_ url: URL, account: String) -> [AccountTable: Int] {
        Dictionary(uniqueKeysWithValues: AccountTable.allCases.map { table in
            (table, Int(sqliteRows(url: url, sql: "SELECT count(*) FROM \"\(table.rawValue)\" WHERE account_id='\(account)'").first?.first ?? "") ?? -1)
        })
    }

    // A migrated store seeded for both accounts, holding the transport lease.
    private static func withSeededStore(_ operation: (MessageStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "account-tables-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: url)
        do {
            try await store.acquireTransportOwnership()
            for account in [alice, bob] { try seed(url, account: account) }
            try await operation(store, url)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test func everyTableIsDeclared() async throws {
        try await Self.withSeededStore { _, url in
            for problem in Self.undeclaredTables(at: url) { Issue.record(Comment(rawValue: problem)) }
        }
    }

    @Test func theFixtureHasARowInEveryTable() async throws {
        try await Self.withSeededStore { _, url in
            #expect(sqliteRows(url: url, sql: "PRAGMA foreign_key_check") == [])
            for account in [Self.alice, Self.bob] {
                for (table, count) in Self.counts(url, account: account) where count != 1 {
                    Issue.record("Fixtures/account-tables.sql writes \(count) rows of \(account) to `\(table.rawValue)`; write exactly one.")
                }
            }
        }
    }

    // The proof that `everyTableIsDeclared` catches a migration nobody declared: one table keyed by account, one not.
    @Test func anUndeclaredTableIsNamedWithWhatToDeclare() async throws {
        try await Self.withSeededStore { _, url in
            #expect(sqliteExecute(url: url, sql: "CREATE TABLE message_drafts (account_id TEXT NOT NULL, chat_id TEXT NOT NULL, body TEXT NOT NULL); CREATE TABLE draft_parts (draft INTEGER, body TEXT)"))
            let problems = Self.undeclaredTables(at: url).filter { $0.contains("`message_drafts`") || $0.contains("`draft_parts`") }
            #expect(problems.count == 3)
            #expect(problems.contains { $0.hasPrefix("Table `draft_parts` has no AccountTable case.") && $0.contains("`case draftParts = \"draft_parts\"`") })
            #expect(problems.contains { $0.hasPrefix("Table `draft_parts` has no account_id column.") })
            #expect(problems.contains { $0.hasPrefix("Table `message_drafts` has no AccountTable case.") && $0.contains("`case messageDrafts = \"message_drafts\"`")
                && $0.contains("Fixtures/account-tables.sql") })
        }
    }

    // A pre-upgrade snapshot and a transfer's source copy are the whole store.
    @Test func aSnapshotCopiesEveryTable() async throws {
        try await Self.withSeededStore { store, url in
            let copy = url.deletingLastPathComponent().appending(path: "copy.sqlite")
            _ = try await store.writeSnapshot(to: copy)
            for account in [Self.alice, Self.bob] { #expect(Self.counts(copy, account: account) == Self.counts(url, account: account)) }
        }
    }

    @Test func aTransferCopyKeepsWhatItCopiesAndLosesWhatItOmits() async throws {
        try await Self.withSeededStore { store, url in
            let copy = url.deletingLastPathComponent().appending(path: "copy.sqlite")
            _ = try await store.writeSnapshot(to: copy)
            _ = try MessageStore.removeDeviceLocalRows(fromSnapshotAt: copy)
            for account in [Self.alice, Self.bob] {
                let after = Self.counts(copy, account: account)
                for table in AccountTable.allCases {
                    switch table.policy.transfer {
                    case .copy: #expect(after[table] == 1, "a transfer copies `\(table.rawValue)`")
                    case .omit: #expect(after[table] == 0, "a transfer omits `\(table.rawValue)`")
                    }
                }
            }
            #expect(sqliteRows(url: copy, sql: "PRAGMA foreign_key_check") == [])
        }
    }

    @Test func signOutKeepsWhatItKeepsAndRemovesWhatItDeletes() async throws {
        try await Self.withSeededStore { store, url in
            let other = Self.counts(url, account: Self.bob)
            try await store.removeRowsAtSignOut(accountID: Self.alice)
            let after = Self.counts(url, account: Self.alice)
            for table in AccountTable.allCases {
                switch table.policy.signOut {
                case .keep: #expect(after[table] == 1, "sign-out keeps `\(table.rawValue)`")
                case .delete: #expect(after[table] == 0, "sign-out deletes `\(table.rawValue)`")
                }
            }
            #expect(Self.counts(url, account: Self.bob) == other, "another account's rows stay")
        }
    }

    // An extension run may be writing the rows; without the lease nothing is removed.
    @Test func signOutRefusesWithoutTheLease() async throws {
        try await Self.withSeededStore { store, url in
            let before = Self.counts(url, account: Self.alice)
            try await store.releaseTransportOwnership()
            await #expect(throws: MessageStoreError.transportOwnershipRequired) { try await store.removeRowsAtSignOut(accountID: Self.alice) }
            #expect(Self.counts(url, account: Self.alice) == before)
        }
    }

    // An account with encryption state is refused; without it, every table loses the account's row.
    @Test func erasingAnAccountEmptiesEveryTable() async throws {
        try await Self.withSeededStore { store, url in
            let other = Self.counts(url, account: Self.bob)
            await #expect(throws: MessageStoreError.invalidTransition) { try await store.eraseLocalAccount(accountID: Self.alice) }
            #expect(sqliteExecute(url: url, sql: "DELETE FROM encryption_state WHERE account_id='\(Self.alice)'"))
            try await store.eraseLocalAccount(accountID: Self.alice)
            #expect(Self.counts(url, account: Self.alice).values.allSatisfy { $0 == 0 }, "\(Self.counts(url, account: Self.alice))")
            #expect(Self.counts(url, account: Self.bob) == other)
        }
    }
}
