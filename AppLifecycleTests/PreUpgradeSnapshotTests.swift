import XCTest
import Foundation
import SQLite3
import MessageStore
@testable import HausXMPP

/// The pre-upgrade snapshot and its restore, through `PreUpgradeSnapshot` with isolated locations: a temporary App
/// Group root, throwaway preference domains and Keychain services of their own. Never the app's real data.
@MainActor final class PreUpgradeSnapshotTests: XCTestCase {
    private let account = "ellie@example.org"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Everything a previous build left: a schema-21 store with rows still in its WAL, preferences in both domains,
    /// the account record and a push registration in the Keychain, the logout tombstone and an attachment file.
    private final class Installation {
        let root: URL
        let id = UUID().uuidString
        let locations: PreUpgradeSnapshot.Locations
        var walWriter: OpaquePointer?

        init(installation: String = "/install/A", root existing: URL? = nil, keychainID: String? = nil, domains: (String, String)? = nil) throws {
            root = existing ?? FileManager.default.temporaryDirectory.appending(path: "pre-upgrade-\(UUID())", directoryHint: .isDirectory)
            let messaging = root.appending(path: "Messaging", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: messaging, withIntermediateDirectories: true)
            let scope = keychainID ?? id
            let names = domains ?? ("haus.xmpp.snapshot-test.\(scope).app", "haus.xmpp.snapshot-test.\(scope).group")
            locations = PreUpgradeSnapshot.Locations(
                groupRoot: root, messaging: messaging,
                appDefaults: .init(defaults: UserDefaults(suiteName: names.0)!, name: names.0),
                groupDefaults: .init(defaults: UserDefaults(suiteName: names.1)!, name: names.1),
                keychain: .init(accountService: "haus.xmpp.snapshot-test.\(scope).account", accountKey: "primary",
                                pushService: "haus.xmpp.snapshot-test.\(scope).push", snapshotService: "haus.xmpp.snapshot-test.\(scope).snapshot"),
                accessGate: root.appending(path: "notification-access-disabled"), installation: installation)
        }

        var snapshots: PreUpgradeSnapshot { PreUpgradeSnapshot(locations: locations) }

        func remove() {
            sqlite3_close(walWriter)
            try? FileManager.default.removeItem(at: root)
            for domain in [locations.appDefaults, locations.groupDefaults] { domain.defaults.removePersistentDomain(forName: domain.name) }
            let names = locations.keychain
            for service in [names.accountService, names.pushService, names.snapshotService] {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
            }
        }
    }

    private func makeInstallation(_ installation: String = "/install/A") throws -> Installation {
        let made = try Installation(installation: installation)
        addTeardownBlock { made.remove() }
        return made
    }

    private func previousBuildData(in installation: Installation) async throws {
        let locations = installation.locations
        let store = try MessageStore(url: locations.database)
        try await store.upsertChat(accountID: "Ellie@Example.org", chatID: "bob@example.org", title: "Bob")
        for index in 0..<3 {
            try await store.insertMessage(StoredMessage(id: "old-\(index)", accountID: "Ellie@Example.org", chatID: "bob@example.org",
                                                        senderID: "bob@example.org", body: "before \(index)",
                                                        sentAt: now.addingTimeInterval(Double(index)), isOutgoing: false))
        }
        try await store.close()
        XCTAssertEqual(sqliteExec(locations.database, "PRAGMA user_version=21"), SQLITE_OK)
        // The previous build's last writes, still only in the WAL.
        XCTAssertEqual(sqlite3_open(locations.database.path, &installation.walWriter), SQLITE_OK)
        sqlite3_exec(installation.walWriter, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        XCTAssertEqual(sqlite3_exec(installation.walWriter, "INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing) VALUES('Ellie@Example.org','old-wal','bob@example.org','bob@example.org','in the wal',1790000100,0)", nil, nil, nil), SQLITE_OK)

        locations.appDefaults.defaults.set("Ellie@Example.org", forKey: "lastAccount")
        locations.appDefaults.defaults.set("hash", forKey: "avatar.Ellie@Example.org")
        locations.groupDefaults.defaults.set(1, forKey: "somethingShared")
        try keychainAdd(locations.keychain.accountService, "primary", Data("{\"accountID\":\"Ellie@Example.org\"}".utf8))
        try keychainAdd(locations.keychain.pushService, "Ellie@Example.org", Data("{\"journal\":1}".utf8))
        try Data("disabled\n".utf8).write(to: locations.accessGate)
        let attachments = locations.messaging.appending(path: "attachments/abc/cache")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: attachments.appending(path: "one.jpg"))
    }

    func testAFreshInstallTakesNoSnapshot() async throws {
        let installation = try makeInstallation()
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        XCTAssertNil(installation.snapshots.manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.locations.directory.path))
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: installation.locations.keychain.snapshotService), [])
        XCTAssertEqual(sqliteRows(installation.locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
    }

    func testTheSnapshotIsTakenBeforeTheMigrationAndHoldsThePreviousBuildsState() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        let manifest = try XCTUnwrap(installation.snapshots.manifest)
        let copy = locations.snapshot.appending(path: "messages.sqlite")
        XCTAssertEqual(sqliteRows(copy, "PRAGMA user_version"), ["21"])
        XCTAssertEqual(sqliteRows(copy, "SELECT account_id FROM messages WHERE id='old-wal'"), ["Ellie@Example.org"])
        XCTAssertEqual(manifest.database.rowCounts["messages"], 4)
        XCTAssertEqual(manifest.folders, ["attachments"])
        XCTAssertTrue(manifest.notificationsDisabled)
        XCTAssertEqual(manifest.pushRegistrations, ["Ellie@Example.org"])
        // Secrets stay in the Keychain, never in the snapshot folder.
        let service = locations.keychain.snapshotService
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: service, account: "\(manifest.id)|account"),
                       Data("{\"accountID\":\"Ellie@Example.org\"}".utf8))
        let written = try FileManager.default.subpathsOfDirectory(atPath: locations.snapshot.path)
        XCTAssertFalse(written.contains { (try? Data(contentsOf: locations.snapshot.appending(path: $0)))?.range(of: Data("journal".utf8)) != nil })
        XCTAssertEqual(try locations.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // Then, and only then, the store migrated.
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
        XCTAssertEqual(sqliteRows(locations.database, "SELECT DISTINCT account_id FROM messages"), [account])
    }

    func testAFailedSnapshotBlocksTheMigrationUntilTheUserChooses() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        // Something the snapshot cannot write through where its folder goes.
        try Data().write(to: locations.directory)
        guard case .snapshotFailed = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("migrated") }
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"])
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService), [])
        // Retried once the obstacle is gone, it succeeds and migrates.
        try FileManager.default.removeItem(at: locations.directory)
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        XCTAssertNotNil(installation.snapshots.manifest)
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
    }

    func testContinuingWithoutABackupMigratesWithoutOne() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        try Data().write(to: installation.locations.directory)
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, withoutSnapshot: true, now: now) else {
            return XCTFail("not ready")
        }
        try await store.close()
        XCTAssertNil(installation.snapshots.manifest)
        XCTAssertEqual(sqliteRows(installation.locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
    }

    func testABackgroundLaunchOrABusyLeaseChangesNothing() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        guard case .deferred = try await installation.snapshots.open(upgradeAllowed: false, now: now) else { return XCTFail("upgraded") }
        let other = try MessageStore(url: locations.database, schema: .asIs)
        try await other.acquireTransportOwnership()
        guard case .busy = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("upgraded") }
        try await other.close()
        XCTAssertNil(installation.snapshots.manifest)
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"])
    }

    /// A launch killed part way through the snapshot left its folder and a Keychain copy: both are discarded and the
    /// snapshot is taken again from the start before anything migrates.
    func testASnapshotInterruptedByACrashIsDiscardedAndRetaken() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        try FileManager.default.createDirectory(at: locations.partial, withIntermediateDirectories: true)
        try Data("half a database".utf8).write(to: locations.partial.appending(path: "messages.sqlite"))
        try keychainAdd(locations.keychain.snapshotService, "crashed|account", Data("stale".utf8))
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        let manifest = try XCTUnwrap(installation.snapshots.manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.partial.path))
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(),
                       ["\(manifest.id)|account", "\(manifest.id)|push|Ellie@Example.org"])
        XCTAssertEqual(sqliteRows(locations.snapshot.appending(path: "messages.sqlite"), "SELECT count(*) FROM messages"), ["4"])
    }

    /// After the new build changed everything in the inventory, restoring puts back the previous build's database
    /// byte for byte, its preferences, Keychain records, tombstone and files, and leaves the restored state behind.
    func testRestoreReturnsThePreviousBuildsStateExactly() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        let appBefore = locations.appDefaults.contents as NSDictionary, groupBefore = locations.groupDefaults.contents as NSDictionary
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        sqlite3_close(installation.walWriter); installation.walWriter = nil
        try await changeEverythingAsTheNewBuildDoes(store, locations)

        try await store.acquireTransportOwnership()
        let restored = try await installation.snapshots.restore(store: store, now: now.addingTimeInterval(60))
        XCTAssertEqual(restored.takenAt, now)
        try assertRestored(locations, appBefore: appBefore, groupBefore: groupBefore)
        // The store handed over is closed; relaunching this install shows the restored state and opens nothing.
        do { _ = try await store.messages(accountID: account, chatID: "bob@example.org"); XCTFail("the handed-over store is still open") } catch {}
        guard case .restored(restored) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("reopened") }
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"])
    }

    /// The app was killed right after the restore journal was written (or anywhere after): the next launch finishes it.
    func testARestoreInterruptedByACrashFinishesOnTheNextLaunch() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        let appBefore = locations.appDefaults.contents as NSDictionary, groupBefore = locations.groupDefaults.contents as NSDictionary
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        sqlite3_close(installation.walWriter); installation.walWriter = nil
        try await changeEverythingAsTheNewBuildDoes(store, locations)
        try await store.close()
        try Data("{}".utf8).write(to: locations.journal)
        try Data("partly copied".utf8).write(to: URL(filePath: locations.database.path + ".restoring"))

        guard case .restored = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not finished") }
        try assertRestored(locations, appBefore: appBefore, groupBefore: groupBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.database.path + ".restoring"))
    }

    /// The previous build was installed over the restored data and used it; then this build again. The old snapshot
    /// is replaced by a fresh one of what the previous build left, and the migration runs again.
    func testAnotherInstallAfterARestoreTakesAFreshSnapshotAndUpgrades() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        sqlite3_close(installation.walWriter); installation.walWriter = nil
        try await store.acquireTransportOwnership()
        _ = try await installation.snapshots.restore(store: store, now: now)
        let first = try XCTUnwrap(installation.snapshots.manifest)
        XCTAssertEqual(sqliteExec(locations.database, "INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing) VALUES('Ellie@Example.org','old-build-again','bob@example.org','bob@example.org','later',1790000200,0)"), SQLITE_OK)

        let reinstalled = try Installation(installation: "/install/C", root: installation.root, keychainID: installation.id,
                                           domains: (locations.appDefaults.name, locations.groupDefaults.name))
        guard case let .ready(upgraded) = try await reinstalled.snapshots.open(upgradeAllowed: true, now: now.addingTimeInterval(86_400)) else {
            return XCTFail("not upgraded")
        }
        try await upgraded.close()
        let fresh = try XCTUnwrap(reinstalled.snapshots.manifest)
        XCTAssertNotEqual(fresh.id, first.id)
        XCTAssertEqual(fresh.database.rowCounts["messages"], 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.restored.path))
        XCTAssertFalse(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).contains { $0.hasPrefix(first.id) })
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
    }

    func testTheSnapshotExpiresFourteenDaysAfterItWasTaken() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        XCTAssertFalse(installation.snapshots.expireIfDue(now: now.addingTimeInterval(13 * 86_400)))
        XCTAssertNotNil(installation.snapshots.manifest)
        guard case let .ready(reopened) = try await installation.snapshots.open(upgradeAllowed: true, now: now.addingTimeInterval(14 * 86_400)) else {
            return XCTFail("not ready")
        }
        try await reopened.close()
        XCTAssertNil(installation.snapshots.manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.locations.snapshot.path))
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: installation.locations.keychain.snapshotService), [])
    }

    // MARK: Helpers

    /// What the new build does to the inventory after migrating: new messages, renamed and added preferences, a
    /// rewritten account record, a push registration moved to the normal spelling, the tombstone lifted, a new file.
    private func changeEverythingAsTheNewBuildDoes(_ store: MessageStore, _ locations: PreUpgradeSnapshot.Locations) async throws {
        try await store.acquireTransportOwnership()
        try await store.insertMessage(StoredMessage(id: "new-1", accountID: account, chatID: "bob@example.org", senderID: "bob@example.org",
                                                    body: "after", sentAt: now.addingTimeInterval(100), isOutgoing: false))
        try await store.releaseTransportOwnership()
        AccountIdentityMigration.migratePreferences(locations.appDefaults.defaults)
        locations.groupDefaults.defaults.set("haus-abc", forKey: "xmppResource.\(account)")
        try keychainSet(locations.keychain.accountService, "primary", Data("{\"accountID\":\"ellie@example.org\",\"security\":\"directTLS\"}".utf8))
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: locations.keychain.pushService] as CFDictionary)
        try keychainAdd(locations.keychain.pushService, account, Data("{\"journal\":2}".utf8))
        try FileManager.default.removeItem(at: locations.accessGate)
        try Data("new".utf8).write(to: locations.messaging.appending(path: "attachments/abc/cache/two.jpg"))
    }

    private func assertRestored(_ locations: PreUpgradeSnapshot.Locations, appBefore: NSDictionary, groupBefore: NSDictionary,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: locations.database), try Data(contentsOf: locations.snapshot.appending(path: "messages.sqlite")), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.database.path + "-wal"), file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "SELECT id FROM messages ORDER BY id"), ["old-0", "old-1", "old-2", "old-wal"], file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "SELECT DISTINCT account_id FROM messages"), ["Ellie@Example.org"], file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"], file: file, line: line)
        XCTAssertEqual(locations.appDefaults.contents as NSDictionary, appBefore, file: file, line: line)
        XCTAssertEqual(locations.groupDefaults.contents as NSDictionary, groupBefore, file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.accountService, account: "primary"),
                       Data("{\"accountID\":\"Ellie@Example.org\"}".utf8), file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.pushService), ["Ellie@Example.org"], file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.pushService, account: "Ellie@Example.org"),
                       Data("{\"journal\":1}".utf8), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.accessGate.path), file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locations.messaging.appending(path: "attachments/abc/cache").path), ["one.jpg"],
                       file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.restored.path), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.journal.path), file: file, line: line)
        XCTAssertTrue(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot), file: file, line: line)
    }

    private func sqliteExec(_ url: URL, _ sql: String) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func sqliteRows(_ url: URL, _ sql: String) -> [String] {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "NULL") }
        return rows
    }

    private func keychainAdd(_ service: String, _ key: String, _ data: Data) throws {
        let status = SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                 kSecAttrSynchronizable as String: false, kSecValueData as String: data,
                                 kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
    }

    private func keychainSet(_ service: String, _ key: String, _ data: Data) throws {
        let status = SecItemUpdate([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        XCTAssertEqual(status, errSecSuccess)
    }
}
