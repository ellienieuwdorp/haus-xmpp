import Foundation
import Security
import MessageStore
import os

/// A copy of everything the previous build reads, taken by the app before a new build changes any of it, and the way
/// back: restoring it puts that build's data, preferences and Keychain records back exactly as they were, so the
/// previous build can be installed again. docs/development/pre-upgrade-snapshot.md has the inventory and the reasons.
///
/// Layout, in the App Group container beside `Messaging/`:
/// `PreUpgrade/snapshot/` (complete; `snapshot.json` is written last, then the folder is renamed from
/// `snapshot.partial/`), `PreUpgrade/restore-journal.json` (a restore under way) and `PreUpgrade/restored.json` (the
/// data is back in the previous version's format). Secrets stay in the Keychain as separate snapshot items.
struct PreUpgradeSnapshot: Sendable {
    /// The newest schema the build this one replaces can open (it refuses anything above 21). A store at or below it
    /// is copied before migrating; one above it (a migration that stopped part way) holds nothing a previous build
    /// could read back.
    static let previousReleaseSchema = 21
    /// A snapshot is deleted this long after it was taken.
    static let lifetime: TimeInterval = 14 * 24 * 60 * 60
    /// Free space required beyond twice the database (the copy, then the migration's rewrite).
    static let spaceMargin: Int64 = 32 << 20
    static let folders = ["attachments", "avatars"]

    /// A preferences domain, read and replaced whole.
    struct DefaultsDomain: @unchecked Sendable {
        let defaults: UserDefaults
        let name: String
        var contents: [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }
        func replace(with contents: [String: Any]) { defaults.setPersistentDomain(contents, forName: name) }
    }

    /// The Keychain services this build and the previous one keep per-installation records in, and the service that
    /// holds their snapshot copies.
    struct KeychainNames: Sendable {
        let accountService: String
        let accountKey: String
        let pushService: String
        let snapshotService: String

        static let production = KeychainNames(accountService: "haus.xmpp.notification-account", accountKey: "primary",
                                              pushService: "haus.xmpp.push-registration", snapshotService: "haus.xmpp.pre-upgrade-snapshot")
    }

    struct Locations: Sendable {
        let groupRoot: URL
        let messaging: URL
        let appDefaults: DefaultsDomain
        let groupDefaults: DefaultsDomain
        let keychain: KeychainNames
        /// The notification logout tombstone (`NotificationAccessGate`).
        let accessGate: URL
        /// Where the running build is installed. It changes with every install, so a snapshot or restore recorded
        /// by another install tells that some other build may have used the data since.
        let installation: String

        var database: URL { messaging.appending(path: "messages.sqlite") }
        var directory: URL { PreUpgradeHold.directory(groupRoot: groupRoot) }
        var snapshot: URL { directory.appending(path: "snapshot", directoryHint: .isDirectory) }
        var partial: URL { directory.appending(path: "snapshot.partial", directoryHint: .isDirectory) }
        var journal: URL { directory.appending(path: PreUpgradeHold.journalName) }
        var restored: URL { directory.appending(path: PreUpgradeHold.restoredName) }

        /// The app's own: the App Group container, the standard and shared preferences, the real Keychain services.
        static func production(messaging: URL) -> Locations? {
            guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.group),
                  let group = UserDefaults(suiteName: SharedStorage.group), let bundle = Bundle.main.bundleIdentifier else { return nil }
            return Locations(groupRoot: root, messaging: messaging, appDefaults: DefaultsDomain(defaults: .standard, name: bundle),
                             groupDefaults: DefaultsDomain(defaults: group, name: SharedStorage.group), keychain: .production,
                             accessGate: root.appending(path: "notification-access-disabled"),
                             installation: Bundle.main.bundleURL.resolvingSymlinksInPath().path)
        }
    }

    /// What a complete snapshot holds; its file is written last.
    struct Manifest: Codable, Sendable, Equatable {
        let id: String
        let takenAt: Date
        let database: StoreSnapshotSummary
        let installation: String
        /// Of `folders`, the ones that existed.
        let folders: [String]
        /// The notification logout tombstone was present.
        let notificationsDisabled: Bool
        let accountRecord: Bool
        let pushRegistrations: [String]
        var expiresAt: Date { takenAt.addingTimeInterval(PreUpgradeSnapshot.lifetime) }
    }

    struct Restored: Codable, Sendable, Equatable {
        let restoredAt: Date
        let takenAt: Date
        let installation: String
    }

    enum Failure: Error, Equatable {
        case insufficientSpace(needed: Int64, available: Int64)
        case keychain(OSStatus)
        case missing(String)
    }

    enum Opening {
        /// Storage is open at the current schema (migrated after the snapshot where one was due).
        case ready(MessageStore)
        /// The previous version's data is back; nothing may open or change it until the user chooses.
        case restored(Restored)
        /// Another process holds the transport lease: nothing was changed; try again later.
        case busy
        /// An upgrade is due but was not allowed now (a launch into the background).
        case deferred
        /// The snapshot could not be taken; nothing was migrated.
        case snapshotFailed(String)
    }

    let locations: Locations
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "upgrade")

    var manifest: Manifest? { try? Self.decode(Manifest.self, at: locations.snapshot.appending(path: "snapshot.json")) }
    var restoredState: Restored? { try? Self.decode(Restored.self, at: locations.restored) }

    // MARK: Opening storage

    /// Opens the store for this launch, finishing an interrupted restore first and taking the snapshot before any
    /// migration. `upgradeAllowed` false (a background launch) leaves an older store untouched. `withoutSnapshot` is
    /// the user's confirmed choice to migrate after the snapshot failed.
    func open(upgradeAllowed: Bool, withoutSnapshot: Bool = false, now: Date) async throws -> Opening {
        let files = FileManager.default
        if files.fileExists(atPath: locations.journal.path) { return try await finishRestore(now: now) }
        if let restored = restoredState {
            if restored.installation == locations.installation { return .restored(restored) }
            Self.log.notice("restored data was left by another install; the next upgrade takes a fresh snapshot")
            // Another build was installed since the restore and may have used the data: the snapshot is stale, and
            // the next upgrade takes a fresh one.
            try? files.removeItem(at: locations.restored)
            try delete()
        }
        discardIncomplete()
        expireIfDue(now: now)
        guard files.fileExists(atPath: locations.database.path) else {
            // A fresh install: there is nothing to go back to.
            return .ready(try MessageStore(url: locations.database))
        }
        let store = try MessageStore(url: locations.database, schema: .asIs)
        let version = store.openedSchemaVersion
        guard version < MessageStore.currentSchemaVersion else { return .ready(store) }
        guard upgradeAllowed else { try await store.close(); return .deferred }
        Self.log.notice("store at schema \(version, privacy: .public) needs upgrading to \(MessageStore.currentSchemaVersion, privacy: .public)")
        do { try await store.acquireTransportOwnership() }
        catch MessageStoreError.transportOwnedElsewhere { try await store.close(); return .busy }
        if version <= Self.previousReleaseSchema, !withoutSnapshot {
            do {
                if let existing = manifest, existing.database.schemaVersion == version, existing.installation != locations.installation {
                    // Taken by another install: the previous build may have written since. Same format, newer data.
                    try delete()
                }
                if manifest == nil { _ = try await take(from: store, now: now) }
            } catch {
                Self.log.error("pre-upgrade snapshot failed; not migrating: \(String(describing: error), privacy: .public)")
                discardIncomplete()
                try? await store.close()
                return .snapshotFailed(Self.describe(error))
            }
        }
        do {
            try await store.upgradeSchema()
            try await store.releaseTransportOwnership()
        } catch { try? await store.close(); throw error }
        return .ready(store)
    }

    // MARK: Taking

    /// Copies everything in the inventory. The caller holds the store's transport lease, and nothing has migrated or
    /// rewritten any of it yet. Throws, leaving no complete snapshot, when any part cannot be copied and verified.
    func take(from store: MessageStore, now: Date) async throws -> Manifest {
        let files = FileManager.default
        try delete()
        let needed = try Self.databaseBytes(locations.database) * 2 + Self.spaceMargin
        let available = (try? locations.groupRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard available >= needed else { throw Failure.insufficientSpace(needed: needed, available: available) }

        let partial = locations.partial
        try Self.createProtectedDirectory(locations.directory)
        try Self.createProtectedDirectory(partial)
        let id = UUID().uuidString
        let summary = try await store.writeSnapshot(to: partial.appending(path: "messages.sqlite"))
        try Self.protect(partial.appending(path: "messages.sqlite"))

        var folders: [String] = []
        for name in Self.folders where files.fileExists(atPath: locations.messaging.appending(path: name).path) {
            // A clone on APFS: no space until either copy changes.
            try files.copyItem(at: locations.messaging.appending(path: name), to: partial.appending(path: name))
            try Self.protectTree(partial.appending(path: name))
            folders.append(name)
        }

        for (domain, file) in [(locations.appDefaults, "app-defaults.plist"), (locations.groupDefaults, "group-defaults.plist")] {
            let contents = domain.contents
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
            try data.write(to: partial.appending(path: file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            guard let back = try PropertyListSerialization.propertyList(from: Data(contentsOf: partial.appending(path: file)), format: nil)
                    as? NSDictionary, back.isEqual(to: contents) else { throw Failure.missing(file) }
        }

        let keychain = locations.keychain
        let account = try Self.keychainData(service: keychain.accountService, account: keychain.accountKey)
        if let account { try saveCopy(account, key: "\(id)|account") }
        var pushed: [String] = []
        for owner in try Self.keychainAccounts(service: keychain.pushService).sorted() {
            guard let data = try Self.keychainData(service: keychain.pushService, account: owner) else { continue }
            try saveCopy(data, key: "\(id)|push|\(owner)")
            pushed.append(owner)
        }

        let manifest = Manifest(id: id, takenAt: now, database: summary, installation: locations.installation, folders: folders,
                                notificationsDisabled: files.fileExists(atPath: locations.accessGate.path),
                                accountRecord: account != nil, pushRegistrations: pushed)
        try JSONEncoder().encode(manifest).write(to: partial.appending(path: "snapshot.json"),
                                                  options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try files.moveItem(at: partial, to: locations.snapshot)
        Self.log.notice("pre-upgrade snapshot taken before migrating: schema \(summary.schemaVersion, privacy: .public), \(summary.rowCounts["messages"] ?? 0, privacy: .public) messages, \(folders.count, privacy: .public) folders, account record \(account != nil, privacy: .public), \(pushed.count, privacy: .public) push registrations")
        return manifest
    }

    /// A snapshot item holds exactly the original bytes, with the original's accessibility, read back to confirm.
    private func saveCopy(_ data: Data, key: String) throws {
        try Self.keychainAdd(service: locations.keychain.snapshotService, account: key, data: data)
        guard try Self.keychainData(service: locations.keychain.snapshotService, account: key) == data else { throw Failure.missing(key) }
    }

    // MARK: Restoring

    /// Puts the snapshot back for every item in the inventory. The caller has stopped and joined all transport,
    /// sender and crypto work and holds the store's transport lease; the store is closed here, under that lease,
    /// before any file changes. A journal written first makes an interrupted restore finish on the next launch.
    func restore(store: MessageStore, now: Date) async throws -> Restored {
        let (manifest, captured) = try prepareRestore()
        try Self.createProtectedDirectory(locations.directory)
        try JSONEncoder().encode(["startedAt": now]).write(to: locations.journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let restored = Restored(restoredAt: now, takenAt: manifest.takenAt, installation: locations.installation)
        try await store.closeForMigration { try self.swap(manifest, captured, restored) }
        Self.log.notice("restored the snapshot taken \(manifest.takenAt, privacy: .public)")
        return restored
    }

    /// A journal without its marker: the last restore stopped part way. Every step is idempotent and the snapshot is
    /// the source of truth, so it is simply done again, under the lease.
    private func finishRestore(now: Date) async throws -> Opening {
        let (manifest, captured) = try prepareRestore()
        let store = try MessageStore(url: locations.database, schema: .asIs)
        do { try await store.acquireTransportOwnership() }
        catch MessageStoreError.transportOwnedElsewhere { try await store.close(); return .busy }
        let restored = Restored(restoredAt: now, takenAt: manifest.takenAt, installation: locations.installation)
        try await store.closeForMigration { try self.swap(manifest, captured, restored) }
        Self.log.notice("finished an interrupted restore from its journal")
        return .restored(restored)
    }

    /// Everything the swap needs, checked before anything changes: the database copy verifies against its manifest
    /// and every Keychain copy is readable.
    private func prepareRestore() throws -> (Manifest, Captured) {
        guard let manifest else { throw Failure.missing("snapshot") }
        try MessageStore.verifySnapshot(at: locations.snapshot.appending(path: "messages.sqlite"), matches: manifest.database)
        let service = locations.keychain.snapshotService
        var account: Data?
        if manifest.accountRecord {
            guard let data = try Self.keychainData(service: service, account: "\(manifest.id)|account") else { throw Failure.missing("account record") }
            account = data
        }
        var push: [String: Data] = [:]
        for owner in manifest.pushRegistrations {
            guard let data = try Self.keychainData(service: service, account: "\(manifest.id)|push|\(owner)") else { throw Failure.missing("push registration") }
            push[owner] = data
        }
        var defaults: [String: Data] = [:]
        for file in ["app-defaults.plist", "group-defaults.plist"] {
            defaults[file] = try Data(contentsOf: locations.snapshot.appending(path: file))
        }
        return (manifest, Captured(account: account, push: push, defaults: defaults))
    }

    struct Captured: Sendable {
        let account: Data?
        let push: [String: Data]
        let defaults: [String: Data]
    }

    /// Runs with SQLite closed and the lease held. The database is replaced by one rename, after the sidecars of the
    /// file it replaces are gone; the folders, the tombstone, the Keychain records and the preferences follow; the
    /// marker is written last and the journal removed.
    private func swap(_ manifest: Manifest, _ captured: Captured, _ restored: Restored) throws {
        let files = FileManager.default
        let database = locations.database
        let staged = URL(filePath: database.path + ".restoring")
        try? files.removeItem(at: staged)
        try files.copyItem(at: locations.snapshot.appending(path: "messages.sqlite"), to: staged)
        try Self.protect(staged)
        for suffix in ["-wal", "-shm", "-journal"] { try Self.removeIfPresent(URL(filePath: database.path + suffix)) }
        guard Darwin.rename(staged.path, database.path) == 0 else { throw CocoaError(.fileWriteUnknown) }

        for name in (try? files.contentsOfDirectory(atPath: locations.messaging.path)) ?? [] where name.hasPrefix(".restore-discard-") {
            try files.removeItem(at: locations.messaging.appending(path: name))
        }
        for name in Self.folders {
            let current = locations.messaging.appending(path: name)
            if files.fileExists(atPath: current.path) {
                let discard = locations.messaging.appending(path: ".restore-discard-" + UUID().uuidString)
                try files.moveItem(at: current, to: discard)
                try files.removeItem(at: discard)
            }
            if manifest.folders.contains(name) {
                try files.copyItem(at: locations.snapshot.appending(path: name), to: current)
                try Self.protectTree(current)
            }
        }

        if manifest.notificationsDisabled {
            try Data("disabled\n".utf8).write(to: locations.accessGate, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else { try Self.removeIfPresent(locations.accessGate) }

        let keychain = locations.keychain
        if let account = captured.account {
            try Self.keychainSet(service: keychain.accountService, account: keychain.accountKey, data: account)
        } else { try Self.keychainDelete(service: keychain.accountService, account: keychain.accountKey) }
        for owner in try Self.keychainAccounts(service: keychain.pushService) {
            try Self.keychainDelete(service: keychain.pushService, account: owner)
        }
        for (owner, data) in captured.push { try Self.keychainAdd(service: keychain.pushService, account: owner, data: data) }

        for (domain, file) in [(locations.appDefaults, "app-defaults.plist"), (locations.groupDefaults, "group-defaults.plist")] {
            guard let data = captured.defaults[file],
                  let contents = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw Failure.missing(file)
            }
            domain.replace(with: contents)
            domain.defaults.synchronize()
        }

        try JSONEncoder().encode(restored).write(to: locations.restored, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Self.removeIfPresent(locations.journal)
    }

    // MARK: Deleting

    /// Removes the snapshot and its Keychain copies. Called only when the user deletes it, when it expires, or when a
    /// fresh snapshot replaces it.
    func delete() throws {
        try Self.removeIfPresent(locations.snapshot)
        try Self.removeIfPresent(locations.partial)
        for key in try Self.keychainAccounts(service: locations.keychain.snapshotService) {
            try Self.keychainDelete(service: locations.keychain.snapshotService, account: key)
        }
    }

    /// Leaves the restored state for "Upgrade again": the snapshot is replaced by a fresh one on the way.
    func leaveRestoredState() throws {
        try delete()
        try Self.removeIfPresent(locations.restored)
    }

    /// Deletes a snapshot taken `lifetime` or longer ago; true when it did.
    @discardableResult
    func expireIfDue(now: Date) -> Bool {
        guard let manifest, now >= manifest.expiresAt else { return false }
        return (try? delete()) != nil
    }

    /// A snapshot interrupted before its manifest: its folder and any Keychain copies not belonging to the complete
    /// snapshot are removed, so it is taken again from the start.
    private func discardIncomplete() {
        try? Self.removeIfPresent(locations.partial)
        let keep = manifest?.id
        for key in (try? Self.keychainAccounts(service: locations.keychain.snapshotService)) ?? [] where !key.hasPrefix((keep ?? "-") + "|") {
            try? Self.keychainDelete(service: locations.keychain.snapshotService, account: key)
        }
    }

    // MARK: Helpers

    static func describe(_ error: any Error) -> String {
        switch error {
        case Failure.insufficientSpace(let needed, let available):
            let format = ByteCountFormatter()
            return "There is not enough free space on this iPhone. The backup needs \(format.string(fromByteCount: needed)); \(format.string(fromByteCount: max(available, 0))) is free."
        case Failure.keychain: return "The saved account could not be read. Unlock your iPhone and try again."
        default: return "The backup could not be written and checked."
        }
    }

    private static func databaseBytes(_ database: URL) throws -> Int64 {
        ["", "-wal"].reduce(Int64(0)) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: database.path + suffix))?[.size] as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
    }

    /// The same class and backup exclusion as `Messaging/`.
    private static func createProtectedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var location = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    private static func protectTree(_ url: URL) throws {
        try protect(url)
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items { try protect(item) }
    }

    // Keychain records as raw bytes: the snapshot never decodes, and so never rewrites, what it copies.

    private static func query(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: false]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func keychainData(service: String, account: String) throws -> Data? {
        var lookup = query(service: service, account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return data
    }

    static func keychainAccounts(service: String) throws -> [String] {
        var lookup = query(service: service, account: nil)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw Failure.keychain(status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func keychainAdd(service: String, account: String, data: Data) throws {
        var item = query(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private static func keychainSet(service: String, account: String, data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(service: service, account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { return try keychainAdd(service: service, account: account, data: data) }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private static func keychainDelete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
