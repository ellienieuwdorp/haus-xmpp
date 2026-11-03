import XCTest
import SQLite3
import Foundation
import MessageStore
import MessagingCore
@testable import HausXMPP

extension AccountTransferTests {
    // One row in every table (the MessageStore fixture account-tables.sql): what `AccountTable` copies arrives, what
    // it omits stays behind.
    func testEveryTableArrivesOrStaysAsItsTransferPolicySays() async throws {
        let source = try makeInstall(), target = try makeInstall()
        let store = try source.openStore()
        let seeded = "seed@localhost"
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "account-tables", withExtension: "sql"))
        let sql = try String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: "{account}", with: seeded)
        func counts(_ database: URL) throws -> [AccountTable: Int] {
            let rows = try StoreSnapshotSummary(snapshotAt: database).rowCounts
            return Dictionary(uniqueKeysWithValues: AccountTable.allCases.map { ($0, rows[$0.rawValue] ?? -1) })
        }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.locations.install.database.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)
        XCTAssertEqual(try counts(source.locations.install.database), Dictionary(uniqueKeysWithValues: AccountTable.allCases.map { ($0, 1) }))

        let code = TransferCode.generate()
        let archive = source.transfer.archive(of: try await export(source, store: store, code: code))
        let fresh = try target.openStore()
        let staged = try target.transfer.stage(archive: archive, code: code)
        try await fresh.acquireTransportOwnership()
        try await target.transfer.commit(staged, store: fresh, now: now)

        let arrived = try counts(target.locations.install.database)
        for table in AccountTable.allCases {
            switch table.policy.transfer {
            case .copy: XCTAssertEqual(arrived[table], 1, "a transfer copies `\(table.rawValue)`")
            case .omit: XCTAssertEqual(arrived[table], 0, "a transfer omits `\(table.rawValue)`")
            }
        }
    }
}
