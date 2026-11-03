import Foundation
import Security
import CryptoKit
import MessageStore
import MessagingCore
import os

// Copy of everything the previous build reads, taken before this build changes any of it. Restoring puts data,
// preferences and Keychain records back so that build can be reinstalled; it first keeps this build's data as a second
// copy, because only that copy holds the encryption sessions contacts used since.
struct PreUpgradeSnapshot: Sendable {
    // The schema the last release writes, the newest a replaced build can open. A store at or below it is copied before
    // migrating. Each migration commits with its user_version, so a store above it was left by an unreleased build,
    // which no release could open again.
    static let previousReleaseSchema = 27
    // Only suggested: the wall clock can jump and no monotonic clock survives a restart.
    static let suggestedLifetime: TimeInterval = 14 * 24 * 60 * 60
    static let spaceMargin: Int64 = 32 << 20
    static let folders = ["attachments", "avatars"]

    enum Copy: String, CaseIterable, Sendable {
        case previousVersion = "snapshot"
        // Only this copy's encryption sessions match what contacts sent since the restore.
        case thisVersion = "post-upgrade"
    }

    // UserDefaults is thread-safe, and `name` is an immutable String.
    struct DefaultsDomain: @unchecked Sendable {
        let defaults: UserDefaults
        let name: String
        var contents: [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }
        func replace(with contents: [String: Any]) { defaults.setPersistentDomain(contents, forName: name) }
    }

    struct KeychainNames: Sendable {
        let accountService: String
        let accountKey: String
        let pushService: String
        let unnumberedSnapshotService: String

        init(accountService: String, accountKey: String, pushService: String, snapshotService: String) {
            self.accountService = accountService; self.accountKey = accountKey; self.pushService = pushService
            unnumberedSnapshotService = snapshotService
        }

        func snapshotService(generation: Int?) -> String { generation.map { "\(unnumberedSnapshotService).\($0)" } ?? unnumberedSnapshotService }
        var snapshotService: String { snapshotService(generation: PreUpgradeHold.generation) }

        static let production = KeychainNames(accountService: NotificationAccount.service, accountKey: NotificationAccount.key,
                                              pushService: PushRegistrationState.service, snapshotService: "haus.xmpp.pre-upgrade-snapshot")
    }

    struct Locations: Sendable {
        let groupRoot: URL
        let messaging: URL
        let appDefaults: DefaultsDomain
        let groupDefaults: DefaultsDomain
        let keychain: KeychainNames
        let accessGate: URL
        // Changes with every install: a snapshot from another install means another build may have used the data.
        let installation: String

        var database: URL { messaging.appending(path: "messages.sqlite") }
        var directory: URL { PreUpgradeHold.directory(groupRoot: groupRoot) }
        func directory(generation: Int?) -> URL { PreUpgradeHold.directory(groupRoot: groupRoot, generation: generation) }
        func folder(_ copy: Copy) -> URL { directory.appending(path: copy.rawValue, directoryHint: .isDirectory) }
        func partial(_ copy: Copy) -> URL { directory.appending(path: copy.rawValue + ".partial", directoryHint: .isDirectory) }
        func replaced(_ copy: Copy) -> URL { directory.appending(path: copy.rawValue + ".replaced", directoryHint: .isDirectory) }
        var snapshot: URL { folder(.previousVersion) }
        var journal: URL { directory.appending(path: PreUpgradeHold.journalName) }
        var returnJournal: URL { directory.appending(path: PreUpgradeHold.returnJournalName) }
        var restored: URL { directory.appending(path: PreUpgradeHold.restoredName) }
        var savedReplies: URL { directory.appending(path: "saved-replies.json") }

        static func production(messaging: URL) -> Locations? {
            guard let root = try? SharedStorage.groupContainer(),
                  let group = UserDefaults(suiteName: SharedStorage.group), let bundle = Bundle.main.bundleIdentifier else { return nil }
            return Locations(groupRoot: root, messaging: messaging, appDefaults: DefaultsDomain(defaults: .standard, name: bundle),
                             groupDefaults: DefaultsDomain(defaults: group, name: SharedStorage.group), keychain: .production,
                             accessGate: root.appending(path: "notification-access-disabled"),
                             installation: Bundle.main.bundleURL.resolvingSymlinksInPath().path)
        }
    }

    struct Manifest: Codable, Sendable, Equatable {
        let id: String
        let takenAt: Date
        let database: StoreSnapshotSummary
        let installation: String
        let folders: [String]
        let notificationsDisabled: Bool
        let accountRecord: Bool
        let pushRegistrations: [String]
        var suggestDeletionAfter: Date { takenAt.addingTimeInterval(PreUpgradeSnapshot.suggestedLifetime) }
    }

    // `unreadable` is never absent: nothing of it, Keychain copies included, is deleted except by the user.
    enum Status: Sendable, Equatable {
        case absent
        case complete(Manifest)
        case unreadable
    }

    struct Restored: Codable, Sendable, Equatable {
        let restoredAt: Date
        let takenAt: Date
        let installation: String
        // A different digest (or a sidecar) means an older build used the restored database since.
        var database: String?
        // Nil: restored by an older build, in rollback-journal mode.
        var writeAheadLog: Bool?
    }

    struct RestoredState: Sendable, Equatable {
        let restored: Restored
        let previousVersionRan: Bool
        let thisVersion: Manifest?
        let thisVersionUnreadable: Bool
        // Chats where this version sent encrypted messages after the backup: the previous version cannot read what
        // arrived after.
        let rolledBack: [String]
        let sentOnPreviousVersion: [String]
    }

    enum Failure: Error, Equatable {
        case insufficientSpace(needed: Int64, available: Int64)
        case keychain(OSStatus)
        case missing(String)
        case unreadableBackup
    }

    enum Opening {
        case ready(MessageStore)
        // Nothing may open or change the restored data until the user chooses.
        case restored(RestoredState)
        // Another process holds the transport lease; nothing was changed.
        case busy
        // An upgrade is due but the launch is into the background.
        case deferred
        case snapshotFailed(String)
    }

    let locations: Locations
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "upgrade")

    var manifest: Manifest? { if case let .complete(manifest) = status(.previousVersion) { manifest } else { nil } }

    func status(_ copy: Copy) -> Status {
        let folder = locations.folder(copy)
        guard FileManager.default.fileExists(atPath: folder.path) else { return .absent }
        guard let manifest = try? Self.decode(Manifest.self, at: folder.appending(path: "snapshot.json")) else { return .unreadable }
        return .complete(manifest)
    }

    // Finishes an interrupted restore or return, then snapshots before any migration. A background launch leaves an
    // older store untouched. Only a `ready` store has had the previous build's spellings rewritten (`adopt`).
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

    // Moves an older build's backups to this build's names so an older build installed after a restore finds none of
    // ours; skipped once this build has its own folder. Crash-safe: copies are written before the folder moves and old
    // ones deleted after; an unreadable Keychain leaves everything for the next launch.
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

    // Runs only once the store is at the current schema, so always after the snapshot.
    private func adopt() {
        let defaults = locations.appDefaults.defaults
        AccountIdentityMigration.migratePreferences(defaults)
        AccountIdentityMigration.moveFiles(directory: locations.messaging, defaults: defaults)
        PushRegistrationState.normalizeSavedAccounts(service: locations.keychain.pushService)
    }

    // Replaces a complete copy only once the new one is complete and verified. The caller holds the store's transport
    // lease.
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

    // A complete copy already there is moved aside first and deleted after, so a crash leaves one complete (`tidy`
    // restores it).
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

    // Original bytes and accessibility, read back to confirm.
    private func saveCopy(_ data: Data, key: String) throws {
        try Self.keychainAdd(service: locations.keychain.snapshotService, account: key, data: data)
        guard try Self.keychainData(service: locations.keychain.snapshotService, account: key) == data else { throw Failure.missing(key) }
    }

    // The caller has stopped and joined all transport, sender and crypto work and holds the transport lease; the store
    // closes here under that lease before any file changes. Nothing changes until the journal is written; after that an
    // interrupted restore finishes on the next launch.
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

    // A journal without its marker: every step is idempotent and the snapshot is the source of truth, so it runs again
    // under the lease. This version's copy was complete before the journal was written.
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

    // A restore leaves the file in WAL mode without sidecars and records its digest, so an older build that opens it
    // leaves -wal/-shm (the system SQLite keeps them after closing) or changes the file; older builds restored in
    // rollback-journal mode, so the header is checked too. When unsure it answers true, keeping what they wrote.
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

    enum ChoiceResult: Sendable, Equatable {
        case done
        case busy
    }

    // When the previous build ran on the restored data, that data first becomes the new `previousVersion` copy, so
    // nothing on the device is dropped. The store is then at the current schema; `open` finishes the launch.
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

    // While the kept copy exists it is put back again (every step is idempotent); once gone, only the marker and
    // journal remain. False when the lease is busy.
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

    // If the previous build ran on the restored data, it first becomes the new `previousVersion` copy whatever the
    // install path says, so what that build wrote is backed up before anything migrates. An unreadable kept copy stays
    // for Delete backup.
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

    // Verifies everything before anything changes: the database against its manifest, every Keychain copy and
    // preference file.
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

    // Runs with SQLite closed and the lease held; the database is replaced by one rename after the old file's sidecars
    // are gone. Every copy goes back in WAL mode: builds open a store at their own schema as it is, so a
    // rollback-journal copy would stay so.
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

    // Also removes unqueued saved replies and any older build's backup folder and Keychain copies.
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

    // Keychain copies of an unreadable manifest are left for `tidy`, which removes them once no unreadable copy
    // remains.
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

    // Finishes or discards what a crash left: a moved-aside copy without replacement is put back, partial copies are
    // removed, and this version's copy goes when no restore or return is under way or in place. Unreadable copies stay
    // for Delete backup; Keychain copies go only when they belong to no complete copy and no copy is unreadable.
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

    // A reply found later is dropped with a notice, not sent into a conversation that moved on. A jumped clock errs
    // towards dropping; it never sends something the user did not expect to go.
    static let savedReplyLifetime: TimeInterval = 24 * 60 * 60

    // Queued in the outbox only once the upgrade finished, never before.
    struct SavedReply: Codable, Sendable, Equatable {
        // Fixed when saved: queueing again after a kill before the file was removed finds it queued and never sends it
        // twice.
        let id: String
        let destination: [String: String]
        let text: String
        let savedAt: Date

        init(id: String = UUID().uuidString, destination: [String: String], text: String, savedAt: Date) {
            self.id = id; self.destination = destination; self.text = text; self.savedAt = savedAt
        }

        // Replies saved without an ID get one derived from their contents, stable across launches.
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

    struct SavedReplyResult: Sendable, Equatable {
        var queued = 0
        // Another account's, no longer resolving to one of this account's messages, or refused by the outbox.
        var rejected = 0
        var expired = 0
    }

    func saveReply(_ reply: SavedReply) throws {
        try Self.createProtectedDirectory(locations.directory)
        var saved = (try? Self.decode([SavedReply].self, at: locations.savedReplies)) ?? []
        saved.append(reply)
        try writeSavedReplies(saved)
    }

    var savedReplies: [SavedReply] { (try? Self.decode([SavedReply].self, at: locations.savedReplies)) ?? [] }

    // A reply whose ID the store already holds was queued by a launch killed before the removal and is not queued
    // again. Every account's reply but `account`'s is rejected. Each reply goes through `enqueue`, so the outbox's trust
    // and encryption rules apply unchanged.
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

    func removeSavedReplies(of account: String) throws {
        let saved = savedReplies
        let kept = saved.filter { !(NotificationDestination(payload: $0.destination)?.belongs(to: account) ?? false) }
        guard kept.count != saved.count else { return }
        if kept.isEmpty { try Self.removeIfPresent(locations.savedReplies) } else { try writeSavedReplies(kept) }
    }

    private func writeSavedReplies(_ replies: [SavedReply]) throws {
        try JSONEncoder().encode(replies).write(to: locations.savedReplies, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case Failure.insufficientSpace(let needed, let available):
            let format = ByteCountFormatter()
            return "There is not enough free space on this \(ThisDevice.noun). The backup needs \(format.string(fromByteCount: needed)); \(format.string(fromByteCount: max(available, 0))) is free."
        case Failure.keychain: return "The saved account could not be read. Unlock your \(ThisDevice.noun) and try again."
        case Failure.unreadableBackup: return "A backup made earlier is on this \(ThisDevice.noun) but could not be read."
        default: return "The backup could not be written and checked."
        }
    }

    private static func databaseBytes(_ database: URL) throws -> Int64 {
        ["", "-wal"].reduce(Int64(0)) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: database.path + suffix))?[.size] as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
    }

    static func createProtectedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var location = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }

    static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    static func protectTree(_ url: URL) throws {
        try protect(url)
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items { try protect(item) }
    }

    // Keychain records as raw bytes: a copy never decodes, and so never rewrites, what it copies.

    private static func query(service: String, account: String?) -> [String: Any] {
        KeychainQuery.genericPassword(service: service, account: account)
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

    static func keychainAdd(service: String, account: String, data: Data) throws {
        var item = query(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func keychainSet(service: String, account: String, data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(service: service, account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { return try keychainAdd(service: service, account: account, data: data) }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func keychainDelete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
