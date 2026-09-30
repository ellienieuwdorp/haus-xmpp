import XCTest
import Foundation
import SQLite3
import MessageStore
import MessagingCore
import XMPPProtocol
@testable import HausXMPP

/// The pre-upgrade snapshot, its restore and the way back, through `PreUpgradeSnapshot` with isolated locations: a
/// temporary App Group root, throwaway preference domains and Keychain services of their own. Never the app's real
/// data. The previous build's store is a real schema-21 file (`schema-21.sql`, dumped from the 045ca73 MessageStore).
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

        /// Another install of this build over the same data (a reinstall, or this build after the previous one).
        func reinstalled(as installation: String) throws -> Installation {
            try Installation(installation: installation, root: root, keychainID: id,
                             domains: (locations.appDefaults.name, locations.groupDefaults.name))
        }

        func remove() {
            sqlite3_close(walWriter)
            try? FileManager.default.removeItem(at: root)
            let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Preferences")
            for domain in [locations.appDefaults, locations.groupDefaults] {
                domain.defaults.removePersistentDomain(forName: domain.name)
                domain.defaults.synchronize()
                try? FileManager.default.removeItem(at: preferences.appending(path: domain.name + ".plist"))
            }
            let names = locations.keychain
            for service in [names.accountService, names.pushService, names.snapshotService] {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
            }
        }
    }

    /// cfprefsd writes an empty plist back for a removed suite some time after the test removed it, so every test
    /// class run sweeps its own suites' files (from this run and any earlier one) before, and after until cfprefsd
    /// has stopped writing them back.
    @discardableResult
    private static func removeTestPreferenceFiles() -> Int {
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Preferences")
        var removed = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        where name.hasPrefix("haus.xmpp.snapshot-test.") && name.hasSuffix(".plist") {
            if (try? FileManager.default.removeItem(at: preferences.appending(path: name))) != nil { removed += 1 }
        }
        return removed
    }

    override class func setUp() { super.setUp(); removeTestPreferenceFiles() }
    override class func tearDown() {
        var quiet = 0
        for _ in 0..<50 where quiet < 5 {
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            quiet = removeTestPreferenceFiles() == 0 ? quiet + 1 : 0
            Thread.sleep(forTimeInterval: 0.2)
        }
        super.tearDown()
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

    private func previousBuildData(in installation: Installation) async throws {
        let locations = installation.locations
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "schema-21", withExtension: "sql"))
        XCTAssertEqual(sqliteExec(locations.database, try String(contentsOf: fixture, encoding: .utf8) + "PRAGMA journal_mode=WAL;"), SQLITE_OK)
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"])
        // The previous build's last write, still only in the WAL.
        XCTAssertEqual(sqlite3_open(locations.database.path, &installation.walWriter), SQLITE_OK)
        sqlite3_exec(installation.walWriter, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        XCTAssertEqual(sqlite3_exec(installation.walWriter, "INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing) VALUES('\(typed)','old-wal','bob@example.org','bob@example.org','in the wal',1790000100,0)", nil, nil, nil), SQLITE_OK)

        locations.appDefaults.defaults.set(typed, forKey: "lastAccount")
        locations.appDefaults.defaults.set("hash", forKey: "avatar.\(typed)")
        locations.groupDefaults.defaults.set(1, forKey: "somethingShared")
        try keychainAdd(locations.keychain.accountService, "primary", Data("{\"accountID\":\"\(typed)\"}".utf8))
        try keychainAdd(locations.keychain.pushService, typed, try pushRecord(typed, node: "old-node"))
        try Data("disabled\n".utf8).write(to: locations.accessGate)
        try FileManager.default.createDirectory(at: typedAttachments(installation), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: typedAttachments(installation).appending(path: "one.jpg"))
        try FileManager.default.createDirectory(at: typedAvatars(installation), withIntermediateDirectories: true)
        try Data("face".utf8).write(to: typedAvatars(installation).appending(path: "avatar.png"))
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
    /// upgraded.
    func testUpgradingTheRestoredDataDeletesThisVersionsCopy() async throws {
        let (installation, _, _) = try await restoredInstallation()
        let locations = installation.locations
        let first = try XCTUnwrap(installation.snapshots.manifest)
        runPreviousBuild(on: locations.database)
        let reinstalled = try installation.reinstalled(as: "/install/C")
        try reinstalled.snapshots.upgradeRestoredData()
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
        XCTAssertEqual(reinstalled.snapshots.status(.thisVersion), .absent)
        XCTAssertFalse(PreUpgradeHold.isHeld(groupRoot: locations.groupRoot))
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: locations.keychain.snapshotService).sorted(),
                       ["\(fresh.id)|account", "\(fresh.id)|push|\(typed)"])
    }

    // MARK: Helpers

    private var newAccountRecord: Data { Data("{\"accountID\":\"ellie@example.org\",\"security\":\"directTLS\"}".utf8) }

    /// Previous build's data, snapshotted and upgraded, changed as the new build does, then restored.
    private func restoredInstallation() async throws -> (Installation, NSDictionary, NSDictionary) {
        let installation = try makeInstallation()
        try await previousBuildData(in: installation)
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

    /// What 045ca73 does on its first launch over restored data: its open switches the store to write-ahead logging,
    /// then it writes (here, an encrypted message it sent).
    private func runPreviousBuild(on database: URL) {
        XCTAssertEqual(sqliteExec(database, "PRAGMA journal_mode=WAL; INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing,encryption_profile) VALUES('\(typed)','old-build-again','bob@example.org','\(typed)','later',\(now.timeIntervalSince1970 + 3_600),1,'legacy')"), SQLITE_OK)
    }

    private func assertRestored(_ locations: PreUpgradeSnapshot.Locations, appBefore: NSDictionary, groupBefore: NSDictionary,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: locations.database), try Data(contentsOf: locations.snapshot.appending(path: "messages.sqlite")), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.database.path + "-wal"), file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "SELECT id FROM messages ORDER BY id"), ["old-0", "old-1", "old-2", "old-wal"], file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "SELECT DISTINCT account_id FROM messages"), [typed], file: file, line: line)
        XCTAssertEqual(sqliteRows(locations.database, "PRAGMA user_version"), ["21"], file: file, line: line)
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
        if status == errSecItemNotFound { return try keychainAdd(service, key, data) }
        XCTAssertEqual(status, errSecSuccess)
    }
}
