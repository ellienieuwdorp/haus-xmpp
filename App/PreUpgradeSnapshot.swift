import Foundation
import Security
import CryptoKit
import MessageStore
import MessagingCore
import os

/// A copy of everything the previous build reads, taken by the app before a new build changes any of it, and the way
/// back: restoring it puts that build's data, preferences and Keychain records back exactly as they were, so the
/// previous build can be installed again. Restoring first keeps this build's own data as a second copy, because only
/// that copy holds the encryption sessions contacts used since; coming back offers to return to it.
/// docs/development/pre-upgrade-snapshot.md has the inventory, the choices and the reasons.
///
/// Layout, in the App Group container beside `Messaging/`, in this build's generation folder `PreUpgrade-<schema>/`
/// (`PreUpgradeHold`): `snapshot/` (the previous version's data) and `post-upgrade/` (this version's data as it was at
/// a restore), each complete once its `snapshot.json` is written and the folder renamed from `<name>.partial/`;
/// `restore-journal.json` and `return-journal.json` while a restore or a return runs; `restored.json` while the
/// previous version's data is in place; `saved-replies.json` for notification replies typed before the upgrade.
/// Secrets stay in the Keychain as separate copy items, under a service named for the same generation. Builds up to
/// f563365 have this code too, under the unnumbered names, and main at 4df394a under generation 24: neither sees a
/// newer generation's backups, and this build takes theirs over when it opens (`adoptOlderGeneration`).
struct PreUpgradeSnapshot: Sendable {
    /// The newest schema the build this one replaces can open: main since 4df394a refuses anything above 24, f563365
    /// (the owner's build) anything above 23, and 045ca73 stops at 21. A store at or below it is copied before
    /// migrating, whichever of them left it; one above it (a migration that stopped part way) holds nothing a previous
    /// build could read back.
    static let previousReleaseSchema = 24
    /// After this long Settings suggests deleting the backup. Nothing is ever deleted on a clock reading: the wall
    /// clock can jump, and no monotonic clock survives a restart.
    static let suggestedLifetime: TimeInterval = 14 * 24 * 60 * 60
    /// Free space required beyond the copies themselves.
    static let spaceMargin: Int64 = 32 << 20
    static let folders = ["attachments", "avatars"]

    /// The two copies. Each holds a database, the cloned folders, both preference domains and Keychain copies.
    enum Copy: String, CaseIterable, Sendable {
        /// The previous version's data, taken before this version changes it.
        case previousVersion = "snapshot"
        /// This version's data as it was when the previous version's was restored: the only copy whose encryption
        /// sessions match what contacts sent since. Exists only while the restored data is in place.
        case thisVersion = "post-upgrade"
    }

    /// A preferences domain, read and replaced whole.
    struct DefaultsDomain: @unchecked Sendable {
        let defaults: UserDefaults
        let name: String
        var contents: [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }
        func replace(with contents: [String: Any]) { defaults.setPersistentDomain(contents, forName: name) }
    }

    /// The Keychain services this build and the previous one keep per-installation records in, and the service that
    /// holds their copies.
    struct KeychainNames: Sendable {
        let accountService: String
        let accountKey: String
        let pushService: String
        /// The snapshot service's name without a generation, where builds up to f563365 keep their copies.
        let unnumberedSnapshotService: String

        init(accountService: String, accountKey: String, pushService: String, snapshotService: String) {
            self.accountService = accountService; self.accountKey = accountKey; self.pushService = pushService
            unnumberedSnapshotService = snapshotService
        }

        /// The service holding one generation's copies; nil is the unnumbered one.
        func snapshotService(generation: Int?) -> String { generation.map { "\(unnumberedSnapshotService).\($0)" } ?? unnumberedSnapshotService }
        /// This build's.
        var snapshotService: String { snapshotService(generation: PreUpgradeHold.generation) }

        static let production = KeychainNames(accountService: "haus.xmpp.notification-account", accountKey: "primary",
                                              pushService: PushRegistrationState.service, snapshotService: "haus.xmpp.pre-upgrade-snapshot")
    }

    struct Locations: Sendable {
        let groupRoot: URL
        let messaging: URL
        let appDefaults: DefaultsDomain
        let groupDefaults: DefaultsDomain
        let keychain: KeychainNames
        /// The notification logout tombstone (`NotificationAccessGate`).
        let accessGate: URL
        /// Where the running build is installed. It changes with every install, so a snapshot taken by another
        /// install tells that some other build may have used the data since.
        let installation: String

        var database: URL { messaging.appending(path: "messages.sqlite") }
        var directory: URL { PreUpgradeHold.directory(groupRoot: groupRoot) }
        func directory(generation: Int?) -> URL { PreUpgradeHold.directory(groupRoot: groupRoot, generation: generation) }
        func folder(_ copy: Copy) -> URL { directory.appending(path: copy.rawValue, directoryHint: .isDirectory) }
        func partial(_ copy: Copy) -> URL { directory.appending(path: copy.rawValue + ".partial", directoryHint: .isDirectory) }
        /// A complete copy moved aside while its replacement is renamed into place.
        func replaced(_ copy: Copy) -> URL { directory.appending(path: copy.rawValue + ".replaced", directoryHint: .isDirectory) }
        var snapshot: URL { folder(.previousVersion) }
        var journal: URL { directory.appending(path: PreUpgradeHold.journalName) }
        var returnJournal: URL { directory.appending(path: PreUpgradeHold.returnJournalName) }
        var restored: URL { directory.appending(path: PreUpgradeHold.restoredName) }
        var savedReplies: URL { directory.appending(path: "saved-replies.json") }

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

    /// What a complete copy holds; its file is written last.
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
        /// From then on Settings suggests deleting it (never deleted automatically).
        var suggestDeletionAfter: Date { takenAt.addingTimeInterval(PreUpgradeSnapshot.suggestedLifetime) }
    }

    /// Whether a copy is there. `unreadable` (a folder whose manifest cannot be read or decoded) is never treated as
    /// absent: nothing of it, including its Keychain copies, is deleted except by the user.
    enum Status: Sendable, Equatable {
        case absent
        case complete(Manifest)
        case unreadable
    }

    /// Written once the previous version's data is back.
    struct Restored: Codable, Sendable, Equatable {
        let restoredAt: Date
        let takenAt: Date
        let installation: String
        /// SHA-256 of the database file as restored: a different digest (or a sidecar) means an older build used it
        /// since.
        var database: String?
        /// Put back in write-ahead-log mode, as every build keeps its live store (every restore by this build). Nil:
        /// restored by an older build, in rollback-journal mode, which 045ca73 switched to write-ahead logging on open.
        var writeAheadLog: Bool?
    }

    /// Where a launch finds the restored data.
    struct RestoredState: Sendable, Equatable {
        let restored: Restored
        /// An older build opened the restored data since the restore.
        let previousVersionRan: Bool
        /// This version's data kept at the restore; nil when it is gone or cannot be read.
        let thisVersion: Manifest?
        /// The kept copy is there but its manifest cannot be read: it cannot be put back, and only Delete backup
        /// removes it.
        let thisVersionUnreadable: Bool
        /// Chats where this version had sent encrypted messages after the backup: the previous version cannot read
        /// what arrived in them after the first of those.
        let rolledBack: [String]
        /// Chats where the previous version sent encrypted messages after the restore.
        let sentOnPreviousVersion: [String]
    }

    enum Failure: Error, Equatable {
        case insufficientSpace(needed: Int64, available: Int64)
        case keychain(OSStatus)
        case missing(String)
        /// A copy exists but cannot be read; nothing replaces it without the user.
        case unreadableBackup
    }

    enum Opening {
        /// Storage is open at the current schema (migrated after the snapshot where one was due).
        case ready(MessageStore)
        /// The previous version's data is back; nothing may open or change it until the user chooses.
        case restored(RestoredState)
        /// Another process holds the transport lease: nothing was changed; try again later.
        case busy
        /// An upgrade is due but was not allowed now (a launch into the background).
        case deferred
        /// The snapshot could not be taken; nothing was migrated.
        case snapshotFailed(String)
    }

    let locations: Locations
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "upgrade")

    /// The previous version's data, when complete.
    var manifest: Manifest? { if case let .complete(manifest) = status(.previousVersion) { manifest } else { nil } }

    func status(_ copy: Copy) -> Status {
        let folder = locations.folder(copy)
        guard FileManager.default.fileExists(atPath: folder.path) else { return .absent }
        guard let manifest = try? Self.decode(Manifest.self, at: folder.appending(path: "snapshot.json")) else { return .unreadable }
        return .complete(manifest)
    }

    // MARK: Opening storage

    /// Opens the store for this launch, finishing an interrupted restore or return first and taking the snapshot
    /// before any migration. `upgradeAllowed` false (a background launch) leaves an older store untouched.
    /// `withoutSnapshot` is the user's confirmed choice to migrate after the snapshot failed. Only a `ready` store has
    /// had the previous build's preference, folder and push spellings rewritten (`adopt`).
    func open(upgradeAllowed: Bool, withoutSnapshot: Bool = false, now: Date) async throws -> Opening {
        let files = FileManager.default
        adoptOlderGeneration()
        tidy()
        if files.fileExists(atPath: locations.journal.path) { return try await finishRestore(now: now) }
        if files.fileExists(atPath: locations.returnJournal.path) {
            guard try await finishReturn() else { return .busy }
        }
        if files.fileExists(atPath: locations.restored.path) { return .restored(restoredState()) }
        guard files.fileExists(atPath: locations.database.path) else {
            // A fresh install: there is nothing to go back to.
            let store = try MessageStore(url: locations.database)
            adopt()
            return .ready(store)
        }
        let store = try MessageStore(url: locations.database, schema: .asIs)
        let version = store.openedSchemaVersion
        guard version < MessageStore.currentSchemaVersion else { adopt(); return .ready(store) }
        guard upgradeAllowed else { try await store.close(); return .deferred }
        Self.log.notice("store at schema \(version, privacy: .public) needs upgrading to \(MessageStore.currentSchemaVersion, privacy: .public)")
        do { try await store.acquireTransportOwnership() }
        catch MessageStoreError.transportOwnedElsewhere { try await store.close(); return .busy }
        if version <= Self.previousReleaseSchema, !withoutSnapshot {
            do {
                switch status(.previousVersion) {
                case .unreadable: throw Failure.unreadableBackup
                case .complete(let existing) where existing.database.schemaVersion == version && existing.installation == locations.installation:
                    break // Taken by this install before a migration that did not finish: the same data.
                default:
                    // None yet, or taken by another install: a previous build may have written since.
                    _ = try await take(from: store, into: .previousVersion, now: now)
                }
            } catch {
                Self.log.error("pre-upgrade snapshot failed; not migrating: \(String(describing: error), privacy: .public)")
                tidy()
                try? await store.close()
                return .snapshotFailed(Self.describe(error))
            }
        }
        do {
            try await store.upgradeSchema()
            try await store.releaseTransportOwnership()
        } catch { try? await store.close(); throw error }
        adopt()
        return .ready(store)
    }

    /// Moves an older build's backups (its generation folder and Keychain copies) to this build's names, so that an
    /// older build installed after a restore finds nothing of this build's, and drops the Keychain copies of any older
    /// generation whose folder is gone. Only when this build has no folder of its own yet: one that has (an older build
    /// ran after this one and made its own backup) is left to Delete backup. Every step can run again after a crash:
    /// the copies are written before the folder moves, and the old ones are deleted only once it has. A Keychain that
    /// cannot be read leaves everything in place for the next launch.
    private func adoptOlderGeneration() {
        let files = FileManager.default, keychain = locations.keychain
        if !files.fileExists(atPath: locations.directory.path),
           let older = PreUpgradeHold.olderGenerations.first(where: { files.fileExists(atPath: locations.directory(generation: $0).path) }) {
            let service = keychain.snapshotService(generation: older)
            do {
                for key in try Self.keychainAccounts(service: service) {
                    guard let data = try Self.keychainData(service: service, account: key) else { continue }
                    try Self.keychainSet(service: keychain.snapshotService, account: key, data: data)
                }
                try files.moveItem(at: locations.directory(generation: older), to: locations.directory)
                Self.log.notice("moved the backups of generation \(older.map(String.init) ?? "unnumbered", privacy: .public) to \(PreUpgradeHold.generation, privacy: .public)")
            } catch {
                Self.log.error("could not move older backups: \(String(describing: error), privacy: .public)")
                return
            }
        }
        for older in PreUpgradeHold.olderGenerations where !files.fileExists(atPath: locations.directory(generation: older).path) {
            let service = keychain.snapshotService(generation: older)
            for key in (try? Self.keychainAccounts(service: service)) ?? [] { try? Self.keychainDelete(service: service, account: key) }
        }
    }

    /// Rewrites the previous build's account spellings outside the store (preference keys, the attachment and avatar
    /// folders, push registrations). Runs only once the store is at the current schema, so always after the snapshot.
    private func adopt() {
        let defaults = locations.appDefaults.defaults
        AccountIdentityMigration.migratePreferences(defaults)
        AccountIdentityMigration.moveFiles(directory: locations.messaging, defaults: defaults)
        PushRegistrationState.normalizeSavedAccounts(service: locations.keychain.pushService)
    }

    // MARK: Taking

    /// Copies everything in the inventory into `copy`, replacing a complete copy there only once the new one is
    /// complete. The caller holds the store's transport lease. Throws, leaving the previous copy (if any) in place,
    /// when any part cannot be copied and verified.
    func take(from store: MessageStore, into copy: Copy, now: Date) async throws -> Manifest {
        let files = FileManager.default
        // The previous version's copy must leave room for the migration's rewrite after it.
        let needed = try Self.databaseBytes(locations.database) * (copy == .previousVersion ? 2 : 1) + Self.spaceMargin
        let available = (try? locations.groupRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard available >= needed else { throw Failure.insufficientSpace(needed: needed, available: available) }

        let partial = locations.partial(copy)
        try Self.removeIfPresent(partial)
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
        try commit(partial, as: copy)
        Self.log.notice("\(copy.rawValue, privacy: .public) copy taken: schema \(summary.schemaVersion, privacy: .public), \(summary.rowCounts["messages"] ?? 0, privacy: .public) messages, \(folders.count, privacy: .public) folders, account record \(account != nil, privacy: .public), \(pushed.count, privacy: .public) push registrations")
        return manifest
    }

    /// Renames a finished copy into place. A complete copy already there is moved aside first and deleted after, so
    /// a crash in between leaves one of them complete (`tidy` puts the old one back if the new one is not in place).
    private func commit(_ partial: URL, as copy: Copy) throws {
        let files = FileManager.default, target = locations.folder(copy), replaced = locations.replaced(copy)
        let previous = status(copy)
        if files.fileExists(atPath: target.path) {
            try Self.removeIfPresent(replaced)
            try files.moveItem(at: target, to: replaced)
        }
        try files.moveItem(at: partial, to: target)
        try Self.removeIfPresent(replaced)
        if case let .complete(old) = previous { deleteKeychainCopies(of: old.id) }
    }

    /// A Keychain copy holds exactly the original bytes, with the original's accessibility, read back to confirm.
    private func saveCopy(_ data: Data, key: String) throws {
        try Self.keychainAdd(service: locations.keychain.snapshotService, account: key, data: data)
        guard try Self.keychainData(service: locations.keychain.snapshotService, account: key) == data else { throw Failure.missing(key) }
    }

    // MARK: Restoring

    /// Puts the previous version's data back for every item in the inventory, after keeping this version's own as the
    /// `thisVersion` copy. The caller has stopped and joined all transport, sender and crypto work and holds the
    /// store's transport lease; the store is closed here, under that lease, before any file changes. Throws with
    /// nothing changed until the journal is written; after that an interrupted restore finishes on the next launch.
    func restore(store: MessageStore, now: Date) async throws -> Restored {
        let (manifest, captured) = try prepare(.previousVersion)
        do { _ = try await take(from: store, into: .thisVersion, now: now) }
        catch { try? Self.removeIfPresent(locations.partial(.thisVersion)); throw error }
        try Self.createProtectedDirectory(locations.directory)
        try JSONEncoder().encode(["startedAt": now]).write(to: locations.journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let restored = Restored(restoredAt: now, takenAt: manifest.takenAt, installation: locations.installation)
        try await store.closeForMigration { _ = try self.finishRestoreLocked(manifest, captured, restored) }
        Self.log.notice("restored the snapshot taken \(manifest.takenAt, privacy: .public)")
        return try Self.decode(Restored.self, at: locations.restored)
    }

    /// A journal without its marker: the last restore stopped part way. Every step is idempotent and the snapshot is
    /// the source of truth, so it is simply done again, under the lease. This version's copy was complete before the
    /// journal was written.
    private func finishRestore(now: Date) async throws -> Opening {
        let (manifest, captured) = try prepare(.previousVersion)
        let store = try MessageStore(url: locations.database, schema: .asIs)
        do { try await store.acquireTransportOwnership() }
        catch MessageStoreError.transportOwnedElsewhere { try await store.close(); return .busy }
        let restored = Restored(restoredAt: now, takenAt: manifest.takenAt, installation: locations.installation)
        try await store.closeForMigration { _ = try self.finishRestoreLocked(manifest, captured, restored) }
        Self.log.notice("finished an interrupted restore from its journal")
        return .restored(restoredState())
    }

    private func finishRestoreLocked(_ manifest: Manifest, _ captured: Captured, _ restored: Restored) throws -> Restored {
        try putBack(manifest, captured, from: .previousVersion)
        var marked = restored
        marked.database = try Self.digest(locations.database)
        marked.writeAheadLog = true
        try JSONEncoder().encode(marked).write(to: locations.restored, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Self.removeIfPresent(locations.journal)
        return marked
    }

    /// The restored data as a launch finds it: whether an older build ran on it, and what each choice would keep.
    func restoredState() -> RestoredState {
        let restored = (try? Self.decode(Restored.self, at: locations.restored))
            ?? Restored(restoredAt: .distantPast, takenAt: .distantPast, installation: "", database: nil)
        let ran = previousVersionRan(restored)
        var kept: Manifest?
        let keptStatus = status(.thisVersion)
        if case let .complete(manifest) = keptStatus { kept = manifest }
        let rolledBack = kept.flatMap { _ in
            try? MessageStore.chatsWithEncryptedSends(inFileAt: locations.folder(.thisVersion).appending(path: "messages.sqlite"), since: restored.takenAt)
        } ?? []
        let sent = ran ? (try? MessageStore.chatsWithEncryptedSends(inFileAt: locations.database, since: restored.restoredAt)) ?? [] : []
        return RestoredState(restored: restored, previousVersionRan: ran, thisVersion: kept, thisVersionUnreadable: keptStatus == .unreadable,
                             rolledBack: rolledBack, sentOnPreviousVersion: sent)
    }

    /// True once an older build opened the restored database. The restored file is put back in write-ahead-log mode
    /// with no sidecars and its digest recorded. An older build (app or extension) that opens it leaves `-wal`/`-shm`
    /// beside it (the system SQLite keeps them after closing), and anything it writes changes the file or the WAL.
    /// f563365 and main at 4df394a open a store at their own schema as it is, so the journal mode alone cannot tell.
    /// Reinstalling this build changes none of that, so a reinstall still finds the data untouched. A restore an older
    /// build made was in rollback-journal mode, which 045ca73 switched on open; its header is checked too. When it
    /// cannot tell, it answers true: the choices then keep the data the previous build may have written as the new
    /// backup.
    func previousVersionRan(_ restored: Restored) -> Bool {
        let files = FileManager.default, path = locations.database.path
        if ["-wal", "-shm", "-journal"].contains(where: { files.fileExists(atPath: path + $0) }) { return true }
        guard let handle = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? handle.close() }
        let mode: UInt8 = restored.writeAheadLog == true ? 2 : 1
        guard let header = try? handle.read(upToCount: 20), header.count == 20, header[18] == mode, header[19] == mode else { return true }
        guard let expected = restored.database else { return false }
        guard let digest = try? Self.digest(locations.database) else { return true }
        return digest != expected
    }

    // MARK: After a restore

    enum ChoiceResult: Sendable, Equatable {
        case done
        /// Another process holds the lease: nothing changed.
        case busy
    }

    /// The restored screen's first choice: puts this version's kept copy back, so its messages and encryption sessions
    /// are in place again. When the previous build ran on the restored data, that data first becomes the new
    /// `previousVersion` copy (it holds what that build received and sent), so nothing on this iPhone is dropped and
    /// Settings can still go back to it. The store is then at the current schema; `open` finishes the launch.
    func returnToThisVersion(now: Date) async throws -> ChoiceResult {
        guard FileManager.default.fileExists(atPath: locations.restored.path) else { throw Failure.missing("restored data") }
        let (kept, captured) = try prepare(.thisVersion)
        let ran = previousVersionRan((try? Self.decode(Restored.self, at: locations.restored))
                                     ?? Restored(restoredAt: .distantPast, takenAt: .distantPast, installation: "", database: nil))
        let store = try MessageStore(url: locations.database, schema: .asIs)
        do { try await store.acquireTransportOwnership() }
        catch MessageStoreError.transportOwnedElsewhere { try await store.close(); return .busy }
        do {
            if ran || manifest == nil {
                if case .unreadable = status(.previousVersion) { throw Failure.unreadableBackup }
                _ = try await take(from: store, into: .previousVersion, now: now)
            }
            try JSONEncoder().encode(["startedAt": now]).write(to: locations.returnJournal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { tidy(); try? await store.close(); throw error }
        try await store.closeForMigration { try self.finishReturnLocked(kept, captured) }
        Self.log.notice("returned to this version's data kept \(kept.takenAt, privacy: .public)")
        return .done
    }

    /// A return journal: the last return stopped part way. While the kept copy exists it is put back again (every step
    /// is idempotent); once it is gone the return had finished but for the marker and the journal. False when the
    /// lease is busy.
    private func finishReturn() async throws -> Bool {
        guard case .complete = status(.thisVersion) else {
            try Self.removeIfPresent(locations.restored)
            try Self.removeIfPresent(locations.returnJournal)
            return true
        }
        let (kept, captured) = try prepare(.thisVersion)
        let store = try MessageStore(url: locations.database, schema: .asIs)
        do { try await store.acquireTransportOwnership() }
        catch MessageStoreError.transportOwnedElsewhere { try await store.close(); return false }
        try await store.closeForMigration { try self.finishReturnLocked(kept, captured) }
        Self.log.notice("finished an interrupted return from its journal")
        return true
    }

    private func finishReturnLocked(_ kept: Manifest, _ captured: Captured) throws {
        try putBack(kept, captured, from: .thisVersion)
        try Self.removeIfPresent(locations.restored)
        try deleteCopy(.thisVersion)
        try Self.removeIfPresent(locations.returnJournal)
    }

    /// The restored screen's second choice: this version's kept copy is deleted and the restored data (as the
    /// previous build may have left it) is upgraded by the next `open`. When the previous build ran on it, its data
    /// first becomes the new `previousVersion` copy here, whatever the install path says (`open` reuses a copy taken
    /// by the same install at the same schema), so what that build wrote is in the backup before anything migrates.
    /// A kept copy that cannot be read stays: only Delete backup removes it.
    func upgradeRestoredData(now: Date) async throws -> ChoiceResult {
        guard FileManager.default.fileExists(atPath: locations.restored.path) else { throw Failure.missing("restored data") }
        let ran = previousVersionRan((try? Self.decode(Restored.self, at: locations.restored))
                                     ?? Restored(restoredAt: .distantPast, takenAt: .distantPast, installation: "", database: nil))
        // An unreadable backup is never replaced here; `open` then stops with "Backup before update failed".
        if ran, status(.previousVersion) != .unreadable {
            let store = try MessageStore(url: locations.database, schema: .asIs)
            do { try await store.acquireTransportOwnership() }
            catch MessageStoreError.transportOwnedElsewhere { try await store.close(); return .busy }
            do { _ = try await take(from: store, into: .previousVersion, now: now) }
            catch { tidy(); try? await store.close(); throw error }
            try await store.close()
        }
        if case .complete = status(.thisVersion) { try deleteCopy(.thisVersion) }
        try Self.removeIfPresent(locations.restored)
        return .done
    }

    // MARK: Putting a copy back

    /// Everything a put-back needs, checked before anything changes: the database copy verifies against its manifest
    /// and every Keychain copy and preference file is readable.
    private func prepare(_ copy: Copy) throws -> (Manifest, Captured) {
        let manifest: Manifest
        switch status(copy) {
        case .complete(let found): manifest = found
        case .unreadable: throw Failure.unreadableBackup
        case .absent: throw Failure.missing(copy.rawValue)
        }
        let folder = locations.folder(copy)
        try MessageStore.verifySnapshot(at: folder.appending(path: "messages.sqlite"), matches: manifest.database)
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
            defaults[file] = try Data(contentsOf: folder.appending(path: file))
        }
        return (manifest, Captured(account: account, push: push, defaults: defaults))
    }

    struct Captured: Sendable {
        let account: Data?
        let push: [String: Data]
        let defaults: [String: Data]
    }

    /// Runs with SQLite closed and the lease held. The database is replaced by one rename, after the sidecars of the
    /// file it replaces are gone; the folders, the tombstone, the Keychain records and the preferences follow. Every
    /// copy goes back in write-ahead-log mode, as each build keeps its live store: f563365, main at 4df394a and this
    /// build open a store at their own schema as it is, so a copy left in the snapshot's rollback-journal mode would
    /// stay in it.
    private func putBack(_ manifest: Manifest, _ captured: Captured, from copy: Copy) throws {
        let files = FileManager.default
        let source = locations.folder(copy)
        let database = locations.database
        let staged = URL(filePath: database.path + ".restoring")
        for suffix in ["", "-wal", "-shm"] { try Self.removeIfPresent(URL(filePath: staged.path + suffix)) }
        try files.copyItem(at: source.appending(path: "messages.sqlite"), to: staged)
        try Self.protect(staged)
        try MessageStore.useWriteAheadLog(at: staged)
        for suffix in ["-wal", "-shm", "-journal"] { try Self.removeIfPresent(URL(filePath: database.path + suffix)) }
        guard Darwin.rename(staged.path, database.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        for suffix in ["-wal", "-shm"] { try Self.removeIfPresent(URL(filePath: staged.path + suffix)) }

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
                try files.copyItem(at: source.appending(path: name), to: current)
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
    }

    // MARK: Deleting

    /// Settings' "Delete backup": both copies, whatever state they are in, every Keychain copy, and replies saved
    /// before the upgrade that were never queued; also any older build's backup folder and Keychain copies left beside
    /// this build's (`adoptOlderGeneration`).
    func delete() throws {
        for copy in Copy.allCases {
            for folder in [locations.folder(copy), locations.partial(copy), locations.replaced(copy)] { try Self.removeIfPresent(folder) }
        }
        try Self.removeIfPresent(locations.savedReplies)
        for older in PreUpgradeHold.olderGenerations { try Self.removeIfPresent(locations.directory(generation: older)) }
        for generation in ([PreUpgradeHold.generation] as [Int?]) + PreUpgradeHold.olderGenerations {
            let service = locations.keychain.snapshotService(generation: generation)
            for key in try Self.keychainAccounts(service: service) { try Self.keychainDelete(service: service, account: key) }
        }
    }

    /// Deletes one copy and, when its manifest can be read, its Keychain copies (otherwise `tidy` removes them once no
    /// unreadable copy remains).
    private func deleteCopy(_ copy: Copy) throws {
        let found = status(copy)
        try Self.removeIfPresent(locations.folder(copy))
        try Self.removeIfPresent(locations.partial(copy))
        if case let .complete(manifest) = found { deleteKeychainCopies(of: manifest.id) }
    }

    private func deleteKeychainCopies(of id: String) {
        for key in (try? Self.keychainAccounts(service: locations.keychain.snapshotService)) ?? [] where key.hasPrefix(id + "|") {
            try? Self.keychainDelete(service: locations.keychain.snapshotService, account: key)
        }
    }

    /// Finishes or discards what a crash left: a copy moved aside whose replacement never arrived is put back, a
    /// partial copy is removed, and this version's complete copy is removed when no restore or return is under way
    /// or in place (a restore that stopped before its journal: the live data is that copy's successor). An
    /// unreadable one stays for Delete backup. Keychain copies are removed only when they belong to no complete copy
    /// and no copy is unreadable.
    func tidy() {
        let files = FileManager.default
        for copy in Copy.allCases {
            let target = locations.folder(copy), replaced = locations.replaced(copy)
            if files.fileExists(atPath: replaced.path) {
                if files.fileExists(atPath: target.path) { try? Self.removeIfPresent(replaced) }
                else { try? files.moveItem(at: replaced, to: target) }
            }
            try? Self.removeIfPresent(locations.partial(copy))
        }
        if case .complete = status(.thisVersion),
           ![locations.restored, locations.journal, locations.returnJournal].contains(where: { files.fileExists(atPath: $0.path) }) {
            Self.log.notice("discarding this version's copy left by a restore that did not start")
            try? Self.removeIfPresent(locations.folder(.thisVersion))
        }
        let statuses = Copy.allCases.map(status)
        guard !statuses.contains(.unreadable) else { return }
        let keep = statuses.compactMap { if case let .complete(manifest) = $0 { manifest.id } else { nil } }
        for key in (try? Self.keychainAccounts(service: locations.keychain.snapshotService)) ?? []
        where !keep.contains(where: { key.hasPrefix($0 + "|") }) {
            try? Self.keychainDelete(service: locations.keychain.snapshotService, account: key)
        }
    }

    // MARK: Replies saved before the upgrade

    /// How long a saved reply may wait for the upgrade. One found later is not sent: a message going out a day or
    /// more after it was typed, into a conversation that has moved on, would surprise both sides, and the person can
    /// no longer take it back. It is dropped and a notice says so. A clock that jumped makes this err towards
    /// dropping, which the notice reports; it never sends something the user did not expect to go.
    static let savedReplyLifetime: TimeInterval = 24 * 60 * 60

    /// A notification reply typed while the upgrade waited for the app to come to the front. Only the notification's
    /// opaque destination and the text; queued in the outbox once the upgrade finished, never sent before.
    struct SavedReply: Codable, Sendable, Equatable {
        /// The outbox message ID it is queued under, fixed when it is saved: queueing it again (the app was killed
        /// before the file was removed) finds it already queued and never sends it twice.
        let id: String
        let destination: [String: String]
        let text: String
        let savedAt: Date

        init(id: String = UUID().uuidString, destination: [String: String], text: String, savedAt: Date) {
            self.id = id; self.destination = destination; self.text = text; self.savedAt = savedAt
        }

        /// A reply saved before replies carried an ID gets one derived from its contents, the same on every launch.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            destination = try container.decode([String: String].self, forKey: .destination)
            text = try container.decode(String.self, forKey: .text)
            savedAt = try container.decode(Date.self, forKey: .savedAt)
            if let id = try container.decodeIfPresent(String.self, forKey: .id) { self.id = id; return }
            var hash = SHA256()
            for (key, value) in destination.sorted(by: { $0.key < $1.key }) { hash.update(data: Data("\(key)\u{0}\(value)\u{0}".utf8)) }
            hash.update(data: Data("\(savedAt.timeIntervalSinceReferenceDate)\u{0}\(text)".utf8))
            var b = Array(hash.finalize().prefix(16))
            b[6] = (b[6] & 0x0F) | 0x50 // a name-based UUID's version and variant bits
            b[8] = (b[8] & 0x3F) | 0x80
            id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
        }
    }

    /// What `queueSavedReplies` did with the replies of one account.
    struct SavedReplyResult: Sendable, Equatable {
        /// Queued now, or found already queued by an earlier launch.
        var queued = 0
        /// Another account's, or no longer resolving to one of this account's messages, or refused by the outbox.
        var rejected = 0
        /// Older than `savedReplyLifetime`: dropped, not sent.
        var expired = 0
    }

    func saveReply(_ reply: SavedReply) throws {
        try Self.createProtectedDirectory(locations.directory)
        var saved = (try? Self.decode([SavedReply].self, at: locations.savedReplies)) ?? []
        saved.append(reply)
        try writeSavedReplies(saved)
    }

    var savedReplies: [SavedReply] { (try? Self.decode([SavedReply].self, at: locations.savedReplies)) ?? [] }

    /// Queues every saved reply through `enqueue` (the outbox, trust and encryption rules unchanged) as a reply to
    /// the message its notification named, under the reply's own ID, then removes the file. A reply whose ID the
    /// store already holds was queued by a launch killed before the removal and is not queued again. `account` is
    /// the signed-in account; every other account's reply is rejected.
    func queueSavedReplies(account: String, store: MessageStore, now: Date,
                           enqueue: @Sendable (StoredMessage) async throws -> Void) async -> SavedReplyResult {
        var result = SavedReplyResult()
        for reply in savedReplies {
            guard let destination = NotificationDestination(payload: reply.destination), destination.belongs(to: account) else {
                result.rejected += 1; continue
            }
            if (try? await store.message(accountID: account, messageID: reply.id)) != nil { result.queued += 1; continue }
            guard now.timeIntervalSince(reply.savedAt) <= Self.savedReplyLifetime else { result.expired += 1; continue }
            guard let message = try? await destination.resolve(accountID: account, store: store),
                  (try? await enqueue(NotificationActionHandler.replyMessage(reply.text, id: reply.id, to: message))) != nil else {
                result.rejected += 1; continue
            }
            result.queued += 1
        }
        try? Self.removeIfPresent(locations.savedReplies)
        return result
    }

    /// Sign-out: the replies saved for `account` go with it; any other account's stay.
    func removeSavedReplies(of account: String) throws {
        let saved = savedReplies
        let kept = saved.filter { !(NotificationDestination(payload: $0.destination)?.belongs(to: account) ?? false) }
        guard kept.count != saved.count else { return }
        if kept.isEmpty { try Self.removeIfPresent(locations.savedReplies) } else { try writeSavedReplies(kept) }
    }

    private func writeSavedReplies(_ replies: [SavedReply]) throws {
        try JSONEncoder().encode(replies).write(to: locations.savedReplies, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Helpers

    static func describe(_ error: any Error) -> String {
        switch error {
        case Failure.insufficientSpace(let needed, let available):
            let format = ByteCountFormatter()
            return "There is not enough free space on this iPhone. The backup needs \(format.string(fromByteCount: needed)); \(format.string(fromByteCount: max(available, 0))) is free."
        case Failure.keychain: return "The saved account could not be read. Unlock your iPhone and try again."
        case Failure.unreadableBackup: return "A backup made earlier is on this iPhone but could not be read."
        default: return "The backup could not be written and checked."
        }
    }

    private static func databaseBytes(_ database: URL) throws -> Int64 {
        ["", "-wal"].reduce(Int64(0)) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: database.path + suffix))?[.size] as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
    }

    /// SHA-256 of a file, read in pieces.
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
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

    // Keychain records as raw bytes: a copy never decodes, and so never rewrites, what it copies.

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
