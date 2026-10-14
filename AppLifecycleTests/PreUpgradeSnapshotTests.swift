import XCTest
import Foundation
import SQLite3
import MessageStore
import MessagingCore
import XMPPProtocol
@testable import HausXMPP

/// The pre-upgrade snapshot, its restore and the way back, through `PreUpgradeSnapshot` with isolated locations: a
/// temporary App Group root, throwaway preference domains and Keychain services of their own. Never the app's real
/// data. The previous build's store is a real file: schema 21 (`schema-21.sql`, dumped from the 21ba6b0 MessageStore),
/// schema 23 (`schema-23.sql`, from the 6664869 MessageStore), schema 24
/// (`schema-24.sql`, that store as main at 58b543a migrates it) or schema 25 (`schema-25.sql`, as main at 7159f37
/// migrates that).
@MainActor final class PreUpgradeSnapshotTests: XCTestCase {
    private let typed = "Ellie@Example.org"
    private let account = "ellie@example.org"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Everything a previous build left: a schema-21 store with a row still in its WAL, preferences in both domains,
    /// the account record and a push registration in the Keychain (both under the address as typed), the logout
    /// tombstone, and attachment and avatar folders of the typed spelling.
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
            // Preference suites named by a path inside the temporary root keep their plists there, so removing the
            // root removes them (cfprefsd writes a removed suite back when the host app exits).
            let names = domains ?? (root.appending(path: "app-preferences").path, root.appending(path: "group-preferences").path)
            locations = PreUpgradeSnapshot.Locations(
                groupRoot: root, messaging: messaging,
                appDefaults: .init(defaults: UserDefaults(suiteName: names.0)!, name: names.0),
                groupDefaults: .init(defaults: UserDefaults(suiteName: names.1)!, name: names.1),
                keychain: .init(accountService: "haus.xmpp.snapshot-test.\(scope).account", accountKey: "primary",
                                pushService: "haus.xmpp.snapshot-test.\(scope).push", snapshotService: "haus.xmpp.snapshot-test.\(scope).snapshot"),
                accessGate: root.appending(path: "notification-access-disabled"), installation: installation)
        }

        var snapshots: PreUpgradeSnapshot { PreUpgradeSnapshot(locations: locations) }

        /// Another install of this build over the same data (a reinstall, or this build after the previous one).
        func reinstalled(as installation: String) throws -> Installation {
            try Installation(installation: installation, root: root, keychainID: id,
                             domains: (locations.appDefaults.name, locations.groupDefaults.name))
        }

        func remove() {
            sqlite3_close(walWriter)
            for domain in [locations.appDefaults, locations.groupDefaults] {
                domain.defaults.removePersistentDomain(forName: domain.name)
                domain.defaults.synchronize()
            }
            try? FileManager.default.removeItem(at: root)
            let names = locations.keychain
            let snapshotServices = ([PreUpgradeHold.generation] + PreUpgradeHold.olderGenerations).map(names.snapshotService(generation:))
            for service in [names.accountService, names.pushService] + snapshotServices {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
            }
        }
    }

    private func makeInstallation(_ installation: String = "/install/A") throws -> Installation {
        let made = try Installation(installation: installation)
        addTeardownBlock { made.remove() }
        return made
    }

    private var typedAttachments: (Installation) -> URL {
        { AttachmentFiles.root(directory: $0.locations.messaging, account: self.typed) }
    }
    private var typedAvatars: (Installation) -> URL {
        { AvatarStore.directory(root: $0.locations.messaging, account: self.typed) }
    }

    /// A push registration as saved in the Keychain; sorted keys, so the same record always has the same bytes.
    private func pushRecord(_ owner: String, node: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(PushRegistrationState(accountID: owner, configuration: try XMPPPushConfiguration(serviceJID: "push.example.org", node: node),
                                                       journal: PushRegistrationJournal()))
    }

    /// The spelling a previous build keyed the account by: 21ba6b0 (schema 21) as typed, 6664869 (23) and main at
    /// 58b543a (24) and 7159f37 (25) in normal form.
    private func owner(_ schema: Int) -> String { schema < 23 ? typed : account }

    /// The generation whose names a previous build's backup code uses: nil (the unnumbered names) up to 6664869 (23),
    /// the schema it writes from main at 58b543a (24) on.
    private func generation(ofBuildAt schema: Int) -> Int? { schema >= PreUpgradeHold.firstNumberedGeneration ? schema : nil }

    private func previousBuildData(in installation: Installation, schema: Int = 21) async throws {
        let locations = installation.locations, owner = owner(schema)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "schema-\(schema)", withExtension: "sql"))
        XCTAssertEqual(sqliteExec(locations.database, try String(contentsOf: fixture, encoding: .utf8) + "PRAGMA journal_mode=WAL;"), SQLITE_OK)
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(schema)"])
        // The previous build's last write, still only in the WAL.
        XCTAssertEqual(sqlite3_open(locations.database.path, &installation.walWriter), SQLITE_OK)
        sqlite3_exec(installation.walWriter, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        XCTAssertEqual(sqlite3_exec(installation.walWriter, "INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing) VALUES('\(owner)','old-wal','bob@example.org','bob@example.org','in the wal',1790000100,0)", nil, nil, nil), SQLITE_OK)

        locations.appDefaults.defaults.set(owner, forKey: "lastAccount")
        locations.appDefaults.defaults.set("hash", forKey: "avatar.\(owner)")
        locations.groupDefaults.defaults.set(1, forKey: "somethingShared")
        try keychainAdd(locations.keychain.accountService, "primary", Data("{\"accountID\":\"\(owner)\"}".utf8))
        try keychainAdd(locations.keychain.pushService, owner, try pushRecord(owner, node: "old-node"))
        try Data("disabled\n".utf8).write(to: locations.accessGate)
        let attachments = AttachmentFiles.root(directory: locations.messaging, account: owner)
        let avatars = AvatarStore.directory(root: locations.messaging, account: owner)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: attachments.appending(path: "one.jpg"))
        try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
        try Data("face".utf8).write(to: avatars.appending(path: "avatar.png"))
    }

    /// The backup an older build took of its predecessor's data, in that build's own layout: by default 6664869's
    /// backup of 21ba6b0's schema-21 data in `PreUpgrade/snapshot/` with Keychain copies under the unnumbered snapshot
    /// service; with `generation` 24 and `schema` 23, main's (58b543a) backup of 6664869's data in `PreUpgrade-24/`
    /// under the service of generation 24; with `generation` 25 and `schema` 24, main's (7159f37) backup of that data in
    /// `PreUpgrade-25/`. Manifest and preference files included, written through the same public
    /// seams those builds used, from a fixture store in a scratch folder. Returns the copy's ID.
    private func olderBuildBackup(in installation: Installation, generation: Int? = nil, of schema: Int = 21) async throws -> String {
        let locations = installation.locations, owner = owner(schema)
        let scratch = installation.root.appending(path: "older-store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = scratch.appending(path: "messages.sqlite")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "schema-\(schema)", withExtension: "sql"))
        XCTAssertEqual(sqliteExec(source, try String(contentsOf: fixture, encoding: .utf8) + "PRAGMA journal_mode=WAL;"), SQLITE_OK)
        let folder = locations.directory(generation: generation).appending(path: "snapshot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try MessageStore(url: source, schema: .asIs)
        try await store.acquireTransportOwnership()
        let summary = try await store.writeSnapshot(to: folder.appending(path: "messages.sqlite"))
        try await store.close()
        for file in ["app-defaults.plist", "group-defaults.plist"] {
            XCTAssertTrue((["lastAccount": owner] as NSDictionary).write(to: folder.appending(path: file), atomically: true))
        }
        let id = UUID().uuidString, service = locations.keychain.snapshotService(generation: generation)
        try keychainAdd(service, "\(id)|account", Data("{\"accountID\":\"\(owner)\"}".utf8))
        try keychainAdd(service, "\(id)|push|\(owner)", try pushRecord(owner, node: "older-node"))
        let manifest = PreUpgradeSnapshot.Manifest(id: id, takenAt: now.addingTimeInterval(-7 * 86_400), database: summary,
                                                   installation: generation == nil ? "/install/6664869" : generation == 24 ? "/install/58b543a" : "/install/7159f37",
                                                   folders: [], notificationsDisabled: false, accountRecord: true, pushRegistrations: [owner])
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "snapshot.json"))
        try FileManager.default.removeItem(at: scratch)
        return id
    }

    /// Every row of every table, for comparing two database files by content.
    private func allRows(_ url: URL, untouched: Bool = false) -> [String] {
        sqliteRows(url, untouched: untouched, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").flatMap { table -> [String] in
            let columns = sqliteRows(url, untouched: untouched, "SELECT name FROM pragma_table_info('\(table)')").map { "quote(\($0))" }.joined(separator: "||'|'||")
            return sqliteRows(url, untouched: untouched, "SELECT \(columns) FROM \(table) ORDER BY 1").map { "\(table): \($0)" }
        }
    }

    /// What the previous build's spellings look like outside the store: untouched, or rewritten by `adopt`.
    private func assertSpellings(_ installation: Installation, rewritten: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let locations = installation.locations, files = FileManager.default
        XCTAssertEqual(locations.appDefaults.defaults.string(forKey: "lastAccount"), rewritten ? account : typed, file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.pushService), [rewritten ? account : typed], file: file, line: line)
        XCTAssertEqual(files.fileExists(atPath: typedAttachments(installation).path), !rewritten, file: file, line: line)
        XCTAssertEqual(files.fileExists(atPath: typedAvatars(installation).path), !rewritten, file: file, line: line)
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

    /// The order the owner relies on: the snapshot holds the previous build's spellings everywhere (database,
    /// preferences, Keychain, folders), and only after it and the migration are they rewritten.
    func testTheSnapshotIsTakenBeforeAnythingIsMigratedOrRewritten() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        let manifest = try XCTUnwrap(installation.snapshots.manifest)
        let copy = locations.snapshot.appending(path: "messages.sqlite")
        XCTAssertEqual(sqliteRows(copy, "PRAGMA user_version"), ["21"])
        XCTAssertEqual(sqliteRows(copy, "SELECT account_id FROM messages WHERE id='old-wal'"), [typed])
        XCTAssertEqual(manifest.database.rowCounts["messages"], 4)
        XCTAssertEqual(manifest.folders, ["attachments", "avatars"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.snapshot.appending(path: "avatars").appending(path: typedAvatars(installation).lastPathComponent).path))
        XCTAssertTrue(manifest.notificationsDisabled)
        XCTAssertEqual(manifest.pushRegistrations, [typed])
        let savedPreferences = try XCTUnwrap(NSDictionary(contentsOf: locations.snapshot.appending(path: "app-defaults.plist")))
        XCTAssertEqual(savedPreferences["lastAccount"] as? String, typed)
        // Secrets stay in the Keychain, never in the snapshot folder.
        let service = locations.keychain.snapshotService
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: service, account: "\(manifest.id)|account"), Data("{\"accountID\":\"\(typed)\"}".utf8))
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: service, account: "\(manifest.id)|push|\(typed)"), try pushRecord(typed, node: "old-node"))
        let written = try FileManager.default.subpathsOfDirectory(atPath: locations.snapshot.path)
        XCTAssertFalse(written.contains { (try? Data(contentsOf: locations.snapshot.appending(path: $0)))?.range(of: Data("old-node".utf8)) != nil })
        XCTAssertEqual(try locations.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // Then, and only then, the store migrated and the spellings outside it were rewritten.
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
        XCTAssertEqual(sqliteRows(locations.database, "SELECT DISTINCT account_id FROM messages"), [account])
        try assertSpellings(installation, rewritten: true)
    }

    func testAFailedSnapshotChangesNothingUntilTheUserChooses() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        // Something the snapshot cannot write through where its folder goes.
        try Data().write(to: locations.directory)
        guard case .snapshotFailed = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("migrated") }
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"])
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService), [])
        try assertSpellings(installation, rewritten: false)
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
        try assertSpellings(installation, rewritten: false)
    }

    /// An older build installed over a newer one (TestFlight lets testers do that) finds a store it cannot read. It
    /// refuses it with `unsupportedSchema`, which the app shows as its own screen, and changes nothing on the way: no
    /// snapshot, no migration, no rewritten spellings.
    func testANewerBuildsStoreIsRefusedAndNothingIsChanged() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        let newer = MessageStore.currentSchemaVersion + 1
        XCTAssertEqual(sqlite3_exec(installation.walWriter, "PRAGMA user_version=\(newer)", nil, nil, nil), SQLITE_OK)
        let rows = allRows(locations.database)
        do {
            _ = try await installation.snapshots.open(upgradeAllowed: true, now: now)
            XCTFail("opened a newer build's store")
        } catch {
            XCTAssertEqual(error as? MessageStoreError, .unsupportedSchema(newer))
        }
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(newer)"])
        XCTAssertEqual(allRows(locations.database), rows)
        XCTAssertNil(installation.snapshots.manifest)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService), [])
        try assertSpellings(installation, rewritten: false)
    }

    /// A launch killed part way through the snapshot left its folder and a Keychain copy: both are discarded and the
    /// snapshot is taken again from the start before anything migrates.
    func testASnapshotInterruptedByACrashIsDiscardedAndRetaken() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        let partial = locations.partial(.previousVersion)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("half a database".utf8).write(to: partial.appending(path: "messages.sqlite"))
        try keychainAdd(locations.keychain.snapshotService, "crashed|account", Data("stale".utf8))
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        let manifest = try XCTUnwrap(installation.snapshots.manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(),
                       ["\(manifest.id)|account", "\(manifest.id)|push|\(typed)"])
        XCTAssertEqual(sqliteRows(locations.snapshot.appending(path: "messages.sqlite"), "SELECT count(*) FROM messages"), ["4"])
    }

    /// A snapshot whose manifest cannot be read is kept whole, Keychain copies included: an older store is not
    /// migrated past it, and a current one opens with the backup reported as unreadable.
    func testAnUnreadableManifestNeverDeletesTheBackup() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        let items = try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted()
        XCTAssertEqual(items.count, 2)
        try Data("{ not a manifest".utf8).write(to: locations.snapshot.appending(path: "snapshot.json"))

        guard case let .ready(reopened) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await reopened.close()
        XCTAssertEqual(installation.snapshots.status(.previousVersion), .unreadable)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(), items)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.snapshot.appending(path: "messages.sqlite").path))

        // The same backup in front of a store an older build left: nothing replaces it or migrates past it.
        XCTAssertEqual(sqliteExec(locations.database, "PRAGMA user_version=21"), SQLITE_OK)
        guard case .snapshotFailed = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("migrated") }
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"])
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(), items)
    }

    /// No clock reading deletes the backup: Settings only suggests deleting it once it is two weeks old.
    func testTheBackupIsNeverDeletedOnAClockReading() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        try await store.close()
        let manifest = try XCTUnwrap(installation.snapshots.manifest)
        let later = now.addingTimeInterval(400 * 86_400)
        guard case let .ready(reopened) = try await installation.snapshots.open(upgradeAllowed: true, now: later) else { return XCTFail("not ready") }
        try await reopened.close()
        XCTAssertEqual(installation.snapshots.manifest, manifest)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: installation.locations.keychain.snapshotService).count, 2)
        XCTAssertLessThan(manifest.suggestDeletionAfter, later)
    }

    // MARK: The 6664869 build (schema 23) and main at 58b543a (24) and 7159f37 (25) as the previous version

    /// A device still running 6664869 has a store, whose store is at schema 23: it is copied whole, including what is still only
    /// in its WAL, before the migration to the current schema.
    func testAStoreTheSchema23BuildLeftIsSnapshottedBeforeMigrating() async throws {
        try await assertSnapshottedBeforeMigrating(schema: 23)
    }

    /// A store a build of main between 58b543a and 7159f37 left at schema 24 is copied whole before migrating, so that
    /// build can be installed again over a restore.
    func testAStoreTheSchema24BuildLeftIsSnapshottedBeforeMigrating() async throws {
        try await assertSnapshottedBeforeMigrating(schema: 24)
    }

    /// A store a build of main since 7159f37 left at schema 25 is at `previousReleaseSchema` (moved with schema 26,
    /// link previews): it is copied whole before the migration, so that build can be installed again over a restore.
    func testAStoreTheSchema25BuildLeftIsSnapshottedBeforeMigrating() async throws {
        try await assertSnapshottedBeforeMigrating(schema: 25)
    }

    private func assertSnapshottedBeforeMigrating(schema: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation, schema: schema)
        let locations = installation.locations
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else {
            return XCTFail("not ready", file: file, line: line)
        }
        try await store.close()
        let manifest = try XCTUnwrap(installation.snapshots.manifest, file: file, line: line)
        XCTAssertEqual(manifest.database.schemaVersion, schema, file: file, line: line)
        let copy = locations.snapshot.appending(path: "messages.sqlite")
        XCTAssertEqual(sqliteRows(copy, "PRAGMA user_version"), ["\(schema)"], file: file, line: line)
        XCTAssertEqual(sqliteRows(copy, "SELECT id FROM messages ORDER BY id"), ["group-0", "old-0", "old-1", "old-2", "old-wal"], file: file, line: line)
        XCTAssertEqual(manifest.pushRegistrations, [account], file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.snapshotService, account: "\(manifest.id)|account"),
                       Data("{\"accountID\":\"\(account)\"}".utf8), file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"], file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "SELECT count(*) FROM messages"), ["5"], file: file, line: line)
    }

    /// Such a device also holds 6664869's backup of 21ba6b0's data, in 6664869's layout. The backup of the
    /// schema-23 data replaces it: one backup remains, the old one's Keychain copies are gone with it, and nothing is
    /// left under the folder and Keychain names 6664869's own backup code acts on.
    func testTheOlderBuildsBackupIsRetiredForTheSchema23One() async throws {
        try await assertOlderBackupRetired(schema: 23, olderGeneration: nil, olderSchema: 21)
    }

    /// The same for a build of main since 58b543a, which keeps its backup (of 6664869's schema-23 data) under
    /// generation 24: the backup of the schema-24 data replaces it, and nothing is left under generation 24's names.
    func testMainsBackupIsRetiredForTheSchema24One() async throws {
        try await assertOlderBackupRetired(schema: 24, olderGeneration: 24, olderSchema: 23)
    }

    /// And for a build of main since 7159f37, which keeps its backup (of schema-24 data) under generation 25.
    func testMainsBackupIsRetiredForTheSchema25One() async throws {
        try await assertOlderBackupRetired(schema: 25, olderGeneration: 25, olderSchema: 24)
    }

    private func assertOlderBackupRetired(schema: Int, olderGeneration: Int?, olderSchema: Int,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation, schema: schema)
        let older = try await olderBuildBackup(in: installation, generation: olderGeneration, of: olderSchema)
        let locations = installation.locations
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else {
            return XCTFail("not ready", file: file, line: line)
        }
        try await store.close()
        let manifest = try XCTUnwrap(installation.snapshots.manifest, file: file, line: line)
        XCTAssertNotEqual(manifest.id, older, file: file, line: line)
        XCTAssertEqual(manifest.database.schemaVersion, schema, file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(),
                       ["\(manifest.id)|account", "\(manifest.id)|push|\(account)"], file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService(generation: olderGeneration)), [],
                       file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.directory(generation: olderGeneration).path), file: file, line: line)
    }

    /// Restoring schema-23 data, for 6664869 to be installed over it. 6664869 has this backup code too, under the
    /// unnumbered names: had the restore left its marker and this version's kept copy there, 6664869 would show the
    /// restored screen as if it were the newer build, and either choice there would hand it data it cannot open or
    /// delete this version's copy. So the restored data is exactly the backup's, in the write-ahead-log mode 6664869
    /// keeps its store in, and nothing of this build's backups is under 6664869's names. Then 6664869 runs on it, and
    /// this build, installed again, returns to its own data with the backup now holding what 6664869 wrote.
    func testRestoredSchema23DataIsLeftToThePreviousBuildAndReturnBringsThisVersionBack() async throws {
        try await assertRestoredDataIsLeftToThePreviousBuild(schema: 23)
    }

    /// The same for schema-24 data and a build of main since 58b543a, whose backup code uses generation 24's names.
    func testRestoredSchema24DataIsLeftToThePreviousBuildAndReturnBringsThisVersionBack() async throws {
        try await assertRestoredDataIsLeftToThePreviousBuild(schema: 24)
    }

    /// And for schema-25 data and a build of main since 7159f37, under generation 25's names.
    func testRestoredSchema25DataIsLeftToThePreviousBuildAndReturnBringsThisVersionBack() async throws {
        try await assertRestoredDataIsLeftToThePreviousBuild(schema: 25)
    }

    private func assertRestoredDataIsLeftToThePreviousBuild(schema: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (installation, appBefore, groupBefore) = try await restoredInstallation(schema: schema)
        let locations = installation.locations
        let copy = locations.snapshot.appending(path: "messages.sqlite")
        try assertSameDatabase(locations.database, copy, file: file, line: line)
        XCTAssertEqual(allRows(locations.database, untouched: true), allRows(copy), file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, untouched: true, "PRAGMA user_version"), ["\(schema)"], file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, untouched: true, "SELECT id FROM messages ORDER BY id"),
                       ["group-0", "old-0", "old-1", "old-2", "old-wal"], file: file, line: line)
        XCTAssertEqual(locations.appDefaults.contents as NSDictionary, appBefore, file: file, line: line)
        XCTAssertEqual(locations.groupDefaults.contents as NSDictionary, groupBefore, file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.accountService, account: "primary"),
                       Data("{\"accountID\":\"\(account)\"}".utf8), file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.pushService, account: account), try pushRecord(account, node: "old-node"),
                       file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.accessGate.path), file: file, line: line)
        // Nothing for the previous build's own backup code to find, tidy or act on.
        let previous = generation(ofBuildAt: schema)
        XCTAssertNotEqual(previous, PreUpgradeHold.generation, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.directory(generation: previous).path), file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService(generation: previous)), [], file: file, line: line)
        // This build still finds its restored state, and its extension stays away.
        XCTAssertTrue(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot), file: file, line: line)
        guard case let .restored(untouched) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else {
            return XCTFail("reopened", file: file, line: line)
        }
        XCTAssertFalse(untouched.previousVersionRan, file: file, line: line)
        XCTAssertNotNil(untouched.thisVersion, file: file, line: line)

        runPreviousBuild(on: locations.database, schema: schema)
        let reinstalled = try installation.reinstalled(as: "/install/C")
        let later = now.addingTimeInterval(86_400)
        guard case let .restored(state) = try await reinstalled.snapshots.open(upgradeAllowed: true, now: later) else {
            return XCTFail("upgraded without asking", file: file, line: line)
        }
        XCTAssertTrue(state.previousVersionRan, file: file, line: line)
        XCTAssertEqual(state.sentOnPreviousVersion, ["Bob"], file: file, line: line)
        let returned = try await reinstalled.snapshots.returnToThisVersion(now: later)
        XCTAssertEqual(returned, .done, file: file, line: line)
        guard case let .ready(store) = try await reinstalled.snapshots.open(upgradeAllowed: true, now: later) else {
            return XCTFail("not ready", file: file, line: line)
        }
        let ids = try await store.messages(accountID: account, chatID: "bob@example.org").map(\.id)
        try await store.close()
        XCTAssertTrue(ids.contains("new-1") && ids.contains("new-reply"), file: file, line: line)
        XCTAssertFalse(ids.contains("old-build-again"), file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"], file: file, line: line)
        let backup = try XCTUnwrap(reinstalled.snapshots.manifest, file: file, line: line)
        XCTAssertEqual(backup.database.schemaVersion, schema, file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.snapshot.appending(path: "messages.sqlite"), "SELECT count(*) FROM messages WHERE id='old-build-again'"), ["1"],
                       file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(),
                       ["\(backup.id)|account", "\(backup.id)|push|\(account)"], file: file, line: line)
    }

    /// After the new build changed everything in the inventory, restoring keeps the new build's state as its own
    /// copy and puts back the previous build's database byte for byte, its preferences, Keychain records, tombstone
    /// and files; the restored state names the chats the previous build will not be able to read.
    func testRestoreKeepsThisVersionsDataAndReturnsThePreviousBuildsStateExactly() async throws {
        let (installation, appBefore, groupBefore) = try await restoredInstallation()
        let locations = installation.locations
        try assertRestored(locations, appBefore: appBefore, groupBefore: groupBefore)

        // This version's state, kept whole.
        guard case let .complete(kept) = installation.snapshots.status(.thisVersion) else { return XCTFail("no kept copy") }
        let keptDatabase = locations.folder(.thisVersion).appending(path: "messages.sqlite")
        XCTAssertEqual(sqliteRows(keptDatabase, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
        XCTAssertEqual(sqliteRows(keptDatabase, "SELECT id FROM messages WHERE id LIKE 'new-%' ORDER BY id"), ["new-1", "new-reply"])
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.snapshotService, account: "\(kept.id)|account"), newAccountRecord)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.snapshotService, account: "\(kept.id)|push|\(account)"),
                       try pushRecord(account, node: "new-node"))
        let keptGroup = try XCTUnwrap(NSDictionary(contentsOf: locations.folder(.thisVersion).appending(path: "group-defaults.plist")))
        XCTAssertEqual(keptGroup["xmppResource.\(account)"] as? String, "haus-abc")

        guard case let .restored(state) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("reopened") }
        XCTAssertFalse(state.previousVersionRan)
        XCTAssertEqual(state.thisVersion, kept)
        XCTAssertEqual(state.rolledBack, ["Bob"])
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"])
    }

    /// A restore refused before any change (the lease was given up meanwhile, as a background transition does):
    /// nothing is kept, journaled or replaced, and the store does not hold the lease.
    func testARestoreWithoutTheLeaseChangesNothing() async throws {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
        let locations = installation.locations
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        sqlite3_close(installation.walWriter); installation.walWriter = nil
        try await store.acquireTransportOwnership()
        try await store.releaseTransportOwnership()
        do { _ = try await installation.snapshots.restore(store: store, now: now); XCTFail("restored without the lease") } catch {}
        let holds = await store.holdsTransportOwnership
        XCTAssertFalse(holds)
        XCTAssertEqual(installation.snapshots.status(.thisVersion), .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.partial(.thisVersion).path))
        XCTAssertFalse(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot))
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
        try await store.close()
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
        XCTAssertTrue(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot))

        guard case .restored = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not finished") }
        try assertRestored(locations, appBefore: appBefore, groupBefore: groupBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.database.path + ".restoring"))
    }

    /// Reinstalling this build before the previous one ever ran (a TestFlight update, an Xcode run) finds the
    /// restored data untouched and shows the restored state again, keeping both copies.
    func testReinstallingThisBuildKeepsTheRestoredState() async throws {
        let (installation, appBefore, groupBefore) = try await restoredInstallation()
        let locations = installation.locations
        let reinstalled = try installation.reinstalled(as: "/install/B")
        guard case let .restored(state) = try await reinstalled.snapshots.open(upgradeAllowed: true, now: now.addingTimeInterval(3_600)) else {
            return XCTFail("left the restored state")
        }
        XCTAssertFalse(state.previousVersionRan)
        XCTAssertNotNil(state.thisVersion)
        try assertRestored(locations, appBefore: appBefore, groupBefore: groupBefore)

        // "Delete backup" covers both copies and every Keychain copy.
        try reinstalled.snapshots.delete()
        XCTAssertEqual(reinstalled.snapshots.status(.previousVersion), .absent)
        XCTAssertEqual(reinstalled.snapshots.status(.thisVersion), .absent)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService), [])
    }

    /// The previous build ran on the restored data (it switches the store to write-ahead logging and writes), then
    /// this build again: returning puts this version's data back with its messages and settings, and what the previous
    /// build left becomes the backup, so nothing on the device is dropped.
    func testReturningAfterThePreviousBuildRanPutsThisVersionsDataBack() async throws {
        let (installation, _, _) = try await restoredInstallation()
        let locations = installation.locations
        let kept = try XCTUnwrap(installation.snapshots.restoredState().thisVersion)
        runPreviousBuild(on: locations.database)
        let reinstalled = try installation.reinstalled(as: "/install/C")
        guard case let .restored(state) = try await reinstalled.snapshots.open(upgradeAllowed: true, now: now.addingTimeInterval(86_400)) else {
            return XCTFail("upgraded without asking")
        }
        XCTAssertTrue(state.previousVersionRan)
        XCTAssertEqual(state.sentOnPreviousVersion, ["Bob"])

        let result = try await reinstalled.snapshots.returnToThisVersion(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(result, .done)
        XCTAssertFalse(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot))
        guard case let .ready(store) = try await reinstalled.snapshots.open(upgradeAllowed: true, now: now.addingTimeInterval(86_400)) else {
            return XCTFail("not ready")
        }
        let ids = try await store.messages(accountID: account, chatID: "bob@example.org").map(\.id)
        try await store.close()
        XCTAssertTrue(ids.contains("new-1") && ids.contains("new-reply"))
        XCTAssertFalse(ids.contains("old-build-again"))
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA journal_mode"), ["wal"])
        XCTAssertEqual(locations.groupDefaults.defaults.string(forKey: "xmppResource.\(account)"), "haus-abc")
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.accountService, account: "primary"), newAccountRecord)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.pushService), [account])
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.accessGate.path))
        // The previous build's data is the backup now; this version's copy and its Keychain copies are gone.
        let backup = try XCTUnwrap(reinstalled.snapshots.manifest)
        XCTAssertEqual(sqliteRows(locations.snapshot.appending(path: "messages.sqlite"), "SELECT count(*) FROM messages WHERE id='old-build-again'"), ["1"])
        XCTAssertEqual(reinstalled.snapshots.status(.thisVersion), .absent)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(),
                       ["\(backup.id)|account", "\(backup.id)|push|\(typed)"])
        XCTAssertFalse(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).contains { $0.hasPrefix(kept.id) })
    }

    /// A return killed after its journal was written finishes on the next launch; the extension stays held until then.
    func testAReturnInterruptedByACrashFinishesOnTheNextLaunch() async throws {
        let (installation, _, _) = try await restoredInstallation()
        let locations = installation.locations
        try Data("{}".utf8).write(to: locations.returnJournal)
        try FileManager.default.removeItem(at: locations.restored)
        XCTAssertTrue(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot))
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        let ids = try await store.messages(accountID: account, chatID: "bob@example.org").map(\.id)
        try await store.close()
        XCTAssertTrue(ids.contains("new-1"))
        XCTAssertFalse(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot))
        XCTAssertEqual(installation.snapshots.status(.thisVersion), .absent)
    }

    /// The other choice: this version's copy is deleted, and what the previous build left is snapshotted afresh and
    /// upgraded. The install path is the same as when the first snapshot was taken (iOS need not move the app), so
    /// only the previous build having run tells that the backup is stale.
    func testUpgradingTheRestoredDataDeletesThisVersionsCopy() async throws {
        let (installation, _, _) = try await restoredInstallation()
        let locations = installation.locations
        let first = try XCTUnwrap(installation.snapshots.manifest)
        runPreviousBuild(on: locations.database)
        let reinstalled = try installation.reinstalled(as: locations.installation)
        let result = try await reinstalled.snapshots.upgradeRestoredData(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(result, .done)
        guard case let .ready(store) = try await reinstalled.snapshots.open(upgradeAllowed: true, now: now.addingTimeInterval(86_400)) else {
            return XCTFail("not upgraded")
        }
        let ids = try await store.messages(accountID: account, chatID: "bob@example.org").map(\.id)
        try await store.close()
        XCTAssertTrue(ids.contains("old-build-again"))
        XCTAssertFalse(ids.contains("new-1"))
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["\(MessageStore.currentSchemaVersion)"])
        let fresh = try XCTUnwrap(reinstalled.snapshots.manifest)
        XCTAssertNotEqual(fresh.id, first.id)
        XCTAssertEqual(fresh.database.rowCounts["messages"], 5)
        XCTAssertEqual(sqliteRows(locations.snapshot.appending(path: "messages.sqlite"), "SELECT count(*) FROM messages WHERE id='old-build-again'"), ["1"])
        XCTAssertEqual(reinstalled.snapshots.status(.thisVersion), .absent)
        XCTAssertFalse(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot))
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(),
                       ["\(fresh.id)|account", "\(fresh.id)|push|\(typed)"])
    }

    /// This version's kept copy cannot be read: the restored state says so instead of calling it gone, and neither
    /// upgrading the restored data nor the next launch deletes it; only Delete backup does.
    func testAnUnreadableKeptCopyIsReportedAndOnlyDeleteBackupRemovesIt() async throws {
        let (installation, _, _) = try await restoredInstallation()
        let locations = installation.locations
        let keptDatabase = locations.folder(.thisVersion).appending(path: "messages.sqlite")
        try Data("{ not a manifest".utf8).write(to: locations.folder(.thisVersion).appending(path: "snapshot.json"))
        guard case let .restored(state) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("reopened") }
        XCTAssertNil(state.thisVersion)
        XCTAssertTrue(state.thisVersionUnreadable)

        let result = try await installation.snapshots.upgradeRestoredData(now: now)
        XCTAssertEqual(result, .done)
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not upgraded") }
        try await store.close()
        XCTAssertEqual(installation.snapshots.status(.thisVersion), .unreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptDatabase.path))

        try installation.snapshots.delete()
        XCTAssertEqual(installation.snapshots.status(.thisVersion), .absent)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService), [])
    }

    // MARK: Replies saved before the upgrade

    /// A launch killed after queueing the saved replies but before removing their file queues them again on the next
    /// launch: each goes into the outbox once, including one saved by a build that gave replies no ID. A reply older
    /// than a day is never queued.
    func testASavedReplyIsQueuedOnceWhenTheLaunchIsKilledBeforeItsFileIsRemoved() async throws {
        let installation = try makeInstallation()
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else { return XCTFail("not ready") }
        let destination = try await receivedMessage(in: store)
        let payload = try JSONSerialization.data(withJSONObject: [
            // As the previous feature build saved it: no ID.
            ["destination": destination.payload, "text": "Saved without an ID", "savedAt": now.timeIntervalSinceReferenceDate],
            ["id": UUID().uuidString, "destination": destination.payload, "text": "Saved with an ID", "savedAt": now.timeIntervalSinceReferenceDate + 60],
            ["id": UUID().uuidString, "destination": destination.payload, "text": "Saved two days ago", "savedAt": now.timeIntervalSinceReferenceDate - 2 * 86_400],
        ])
        try FileManager.default.createDirectory(at: installation.locations.directory, withIntermediateDirectories: true)
        try payload.write(to: installation.locations.savedReplies)

        let enqueued = Enqueued()
        let snapshots = installation.snapshots, later = now.addingTimeInterval(3_600)
        let first = await snapshots.queueSavedReplies(account: account, store: store, now: later) { try await enqueued.enqueue($0, in: store) }
        XCTAssertEqual(first, .init(queued: 2, rejected: 0, expired: 1))
        XCTAssertTrue(installation.snapshots.savedReplies.isEmpty)
        // Killed before the file was removed: the next launch finds it again.
        try payload.write(to: installation.locations.savedReplies)
        let second = await snapshots.queueSavedReplies(account: account, store: store, now: later) { try await enqueued.enqueue($0, in: store) }
        XCTAssertEqual(second, .init(queued: 2, rejected: 0, expired: 1))

        XCTAssertEqual(enqueued.bodies, ["Saved without an ID", "Saved with an ID"])
        let queued = try await store.queuedOutgoing(accountID: account).map(\.body).sorted()
        XCTAssertEqual(queued, ["Saved with an ID", "Saved without an ID"])
        try await store.close()
    }

    /// Replies saved before the upgrade never outlive the backup or the account: Delete backup removes them all, and
    /// signing out removes that account's.
    func testDeleteBackupAndSignOutRemoveSavedReplies() async throws {
        let installation = try makeInstallation()
        let snapshots = installation.snapshots
        let mine = try XCTUnwrap(NotificationDestination(accountID: account, messageID: UUID().uuidString))
        let other = try XCTUnwrap(NotificationDestination(accountID: "mallory@example.org", messageID: UUID().uuidString))
        try snapshots.saveReply(.init(destination: mine.payload, text: "mine", savedAt: now))
        try snapshots.saveReply(.init(destination: other.payload, text: "other", savedAt: now))

        try snapshots.removeSavedReplies(of: account)
        XCTAssertEqual(snapshots.savedReplies.map(\.text), ["other"])
        try snapshots.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.locations.savedReplies.path))
    }

    // MARK: Helpers

    /// The outbox itself, noting what reached it.
    @MainActor private final class Enqueued {
        private(set) var bodies: [String] = []
        func enqueue(_ message: StoredMessage, in store: MessageStore) async throws {
            bodies.append(message.body)
            try await store.enqueueOutgoing(message)
        }
    }

    /// An incoming encrypted message a notification could name, and that notification's destination.
    private func receivedMessage(in store: MessageStore) async throws -> NotificationDestination {
        let id = UUID().uuidString
        try await store.upsertChat(accountID: account, chatID: "bob@example.org", title: "Bob")
        try await store.insertMessage(StoredMessage(id: id, accountID: account, chatID: "bob@example.org", senderID: "bob@example.org",
                                                    body: "Synthetic", sentAt: now, isOutgoing: false, encryptionProfile: "legacy"))
        return try XCTUnwrap(NotificationDestination(accountID: account, messageID: id))
    }

    private var newAccountRecord: Data { Data("{\"accountID\":\"ellie@example.org\",\"security\":\"directTLS\"}".utf8) }

    /// Previous build's data, snapshotted and upgraded, changed as the new build does, then restored.
    private func restoredInstallation(schema: Int = 21) async throws -> (Installation, NSDictionary, NSDictionary) {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation, schema: schema)
        let locations = installation.locations
        let appBefore = locations.appDefaults.contents as NSDictionary, groupBefore = locations.groupDefaults.contents as NSDictionary
        guard case let .ready(store) = try await installation.snapshots.open(upgradeAllowed: true, now: now) else {
            XCTFail("not ready"); return (installation, appBefore, groupBefore)
        }
        sqlite3_close(installation.walWriter); installation.walWriter = nil
        try await changeEverythingAsTheNewBuildDoes(store, locations)
        try await store.acquireTransportOwnership()
        let restored = try await installation.snapshots.restore(store: store, now: now.addingTimeInterval(60))
        XCTAssertEqual(restored.takenAt, now)
        // The store handed over is closed.
        do { _ = try await store.messages(accountID: account, chatID: "bob@example.org"); XCTFail("the handed-over store is still open") } catch {}
        return (installation, appBefore, groupBefore)
    }

    /// What the new build does to the inventory after migrating: new messages (one an encrypted reply), renamed and
    /// added preferences, a rewritten account record, a push registration under the normal spelling, the tombstone
    /// lifted, a new file.
    private func changeEverythingAsTheNewBuildDoes(_ store: MessageStore, _ locations: PreUpgradeSnapshot.Locations) async throws {
        try await store.acquireTransportOwnership()
        try await store.insertMessage(StoredMessage(id: "new-1", accountID: account, chatID: "bob@example.org", senderID: "bob@example.org",
                                                    body: "after", sentAt: now.addingTimeInterval(100), isOutgoing: false))
        try await store.insertMessage(StoredMessage(id: "new-reply", accountID: account, chatID: "bob@example.org", senderID: account,
                                                    body: "reply", sentAt: now.addingTimeInterval(110), isOutgoing: true, encryptionProfile: "legacy"))
        try await store.releaseTransportOwnership()
        locations.groupDefaults.defaults.set("haus-abc", forKey: "xmppResource.\(account)")
        try keychainSet(locations.keychain.accountService, "primary", newAccountRecord)
        try keychainSet(locations.keychain.pushService, account, try pushRecord(account, node: "new-node"))
        try FileManager.default.removeItem(at: locations.accessGate)
        let attachments = AttachmentFiles.root(directory: locations.messaging, account: account)
        try Data("new".utf8).write(to: attachments.appending(path: "two.jpg"))
    }

    /// What a previous build does on its first launch over restored data: 21ba6b0's open switches the store to
    /// write-ahead logging (6664869 opens a store at its own schema as it is), then it writes (here, an encrypted
    /// message it sent).
    private func runPreviousBuild(on database: URL, schema: Int = 21) {
        let owner = owner(schema), mode = schema < 23 ? "PRAGMA journal_mode=WAL; " : ""
        XCTAssertEqual(sqliteExec(database, mode + "INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing,encryption_profile) VALUES('\(owner)','old-build-again','bob@example.org','\(owner)','later',\(now.timeIntervalSince1970 + 3_600),1,'legacy')"), SQLITE_OK)
    }

    private func assertRestored(_ locations: PreUpgradeSnapshot.Locations, appBefore: NSDictionary, groupBefore: NSDictionary,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        try assertSameDatabase(locations.database, locations.snapshot.appending(path: "messages.sqlite"), file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, untouched: true, "SELECT id FROM messages ORDER BY id"), ["old-0", "old-1", "old-2", "old-wal"], file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, untouched: true, "SELECT DISTINCT account_id FROM messages"), [typed], file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, untouched: true, "PRAGMA user_version"), ["21"], file: file, line: line)
        XCTAssertEqual(locations.appDefaults.contents as NSDictionary, appBefore, file: file, line: line)
        XCTAssertEqual(locations.groupDefaults.contents as NSDictionary, groupBefore, file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.accountService, account: "primary"),
                       Data("{\"accountID\":\"\(typed)\"}".utf8), file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.pushService), [typed], file: file, line: line)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: locations.keychain.pushService, account: typed), try pushRecord(typed, node: "old-node"),
                       file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.accessGate.path), file: file, line: line)
        let typedFolder = AttachmentFiles.root(directory: locations.messaging, account: typed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: typedFolder.path), ["one.jpg"], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AttachmentFiles.root(directory: locations.messaging, account: account).path), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.restored.path), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.journal.path), file: file, line: line)
        // The notification extension stays away from the restored data.
        XCTAssertTrue(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot), file: file, line: line)
    }

    /// The restored file is the backup's, page for page, put back in write-ahead-log mode with no sidecars: only the
    /// 100-byte file header differs (the journal mode bytes and the change counter the switch bumps).
    private func assertSameDatabase(_ restored: URL, _ backup: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: restored).dropFirst(100), try Data(contentsOf: backup).dropFirst(100), file: file, line: line)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path + suffix), file: file, line: line)
        }
        // Write-ahead logging, read from the header: opening the file would leave the sidecars a previous build's
        // run is recognised by.
        XCTAssertEqual(Array(try Data(contentsOf: restored)[18...19]), [2, 2], file: file, line: line)
    }

    private func sqliteExec(_ url: URL, _ sql: String) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// `untouched` reads the main file without opening it as a database (no WAL frames are read and no sidecars are
    /// left, which a previous build's run is recognised by): for restored data nobody has opened since.
    private func sqliteRows(_ url: URL, untouched: Bool = false, _ sql: String) -> [String] {
        var db: OpaquePointer?, statement: OpaquePointer?
        let opened = untouched ? sqlite3_open_v2("file:\(url.path)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            : sqlite3_open(url.path, &db)
        guard opened == SQLITE_OK else { return [] }
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
        if status == errSecItemNotFound { return try keychainAdd(service, key, data) }
        XCTAssertEqual(status, errSecSuccess)
    }
}
