import Foundation
import MessageStore
import MessagingCore
import os

/// Moves everything this install keeps for its accounts to another install of the app (another build, another
/// iPhone, the Mac) as one encrypted file, and restores such a file into an install that has none of its own.
///
/// It is a move, never a copy: two installs must not both use one OMEMO device identity, or contacts' sessions break.
/// So an export ends in the "moved" state. The store goes out of reach (`held/`), the marker holds this app and its
/// extension off it, and only the user ends that state: by deleting this install's copy once the other install shows
/// the chats, or by taking it back here, which is safe only if the file was never restored anywhere.
///
/// What an install's data is, as the previous-version backup knows it (`PreUpgradeSnapshot`): the store (one
/// consistent copy, WAL included), its attachment and avatar folders, the preferences of both domains, and the
/// Keychain items (the account record, the encryption state's wrapping key, push registrations). Everything goes into
/// the archive under logical names; the target writes each into its own App Group, preference domains and Keychain
/// group, so nothing install-specific travels. What belongs to the install rather than the account stays behind: the
/// XMPP resource, keyboard measurements, the stream that last enabled carbons. Push is set up again for the target:
/// the account record arrives without its subscription, and each registration arrives turned off, so the first
/// connection retires the old device's registration before registering the new one.
///
/// Layout, in the App Group container beside `Messaging/`, in `Transfer/` (`TransferHold`): `moved.json` (the marker,
/// from just before the store moves until the user settles it), `held/` (the store while moved), `outgoing/` (the
/// archive), `export.partial/`; `incoming.partial/` while a restore is read, `import-journal.json` and
/// `import-previous/` while it is put in place, and `imported.json`, the transfers restored here.
struct AccountTransfer: Sendable {
    struct Locations: Sendable {
        let install: PreUpgradeSnapshot.Locations
        /// The wrapping key's Keychain item (`EncryptionKeychain`).
        let encryptionService: String
        let storageID: String
        /// The Keychain service that keeps a moved install's code, one item per transfer ID.
        let codeService: String

        var directory: URL { TransferHold.directory(groupRoot: install.groupRoot) }
        var marker: URL { directory.appending(path: TransferHold.markerName) }
        var held: URL { directory.appending(path: "held", directoryHint: .isDirectory) }
        var outgoing: URL { directory.appending(path: "outgoing", directoryHint: .isDirectory) }
        var exportStaging: URL { directory.appending(path: "export.partial", directoryHint: .isDirectory) }
        var incoming: URL { directory.appending(path: "incoming.partial", directoryHint: .isDirectory) }
        var importJournal: URL { directory.appending(path: "import-journal.json") }
        var importPrevious: URL { directory.appending(path: "import-previous", directoryHint: .isDirectory) }
        var imported: URL { directory.appending(path: "imported.json") }

        static func production(messaging: URL) -> Locations? {
            PreUpgradeSnapshot.Locations.production(messaging: messaging)
                .map { Locations(install: $0, encryptionService: EncryptionKeychain.service, storageID: "primary", codeService: "haus.xmpp.transfer-code") }
        }

        /// A UI test session's own store, preferences and Keychain items (DEBUG builds only set one), beside the
        /// session's store folder: a transfer there never reaches the app's real data.
        static func testSession(_ id: String, preferences: UserDefaults) -> Locations? {
            guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
                  let group = UserDefaults(suiteName: "haus.xmpp.uitest.\(id).group") else { return nil }
            let sessions = support.appending(path: "Messaging/UITests", directoryHint: .isDirectory)
            let root = sessions.appending(path: id + "-group", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let install = PreUpgradeSnapshot.Locations(
                groupRoot: root, messaging: sessions.appending(path: id, directoryHint: .isDirectory),
                appDefaults: .init(defaults: preferences, name: "haus.xmpp.uitest." + id),
                groupDefaults: .init(defaults: group, name: "haus.xmpp.uitest.\(id).group"),
                keychain: .init(accountService: "haus.xmpp.uitest.\(id).account", accountKey: NotificationAccount.key,
                                pushService: "haus.xmpp.uitest.\(id).push", snapshotService: "haus.xmpp.uitest.\(id).snapshot"),
                accessGate: root.appending(path: "notification-access-disabled"), installation: "uitest")
            return Locations(install: install, encryptionService: EncryptionKeychain.service, storageID: id,
                             codeService: "haus.xmpp.uitest.\(id).transfer-code")
        }
    }

    /// The Keychain as this type uses it: raw bytes, never decoded on the way through.
    struct Secrets: Sendable {
        var read: @Sendable (_ service: String, _ account: String) throws -> Data?
        var accounts: @Sendable (_ service: String) throws -> [String]
        var set: @Sendable (_ service: String, _ account: String, _ data: Data) throws -> Void
        var delete: @Sendable (_ service: String, _ account: String) throws -> Void

        static let keychain = Secrets(read: PreUpgradeSnapshot.keychainData, accounts: PreUpgradeSnapshot.keychainAccounts,
                                      set: PreUpgradeSnapshot.keychainSet, delete: PreUpgradeSnapshot.keychainDelete)
    }

    /// The marker: the transfer this install's data went into.
    struct Moved: Codable, Sendable, Equatable {
        enum Stage: String, Codable, Sendable {
            /// The store has moved out of reach and the archive is being written. A launch that finds this undoes it:
            /// no archive was ever offered.
            case exporting
            /// The archive is complete and checked. Only the user ends this.
            case moved
        }

        var stage: Stage
        let transferID: String
        let createdAt: Date
        let accountID: String
        let fileName: String
        var fileSize: Int64 = 0
    }

    struct Progress: Sendable, Equatable {
        enum Step: Int, Sendable { case copying, encrypting, checking, restoring }
        let step: Step
        /// Of this step, 0 to 1.
        let fraction: Double
    }

    enum Failure: Error, Equatable {
        case insufficientSpace(needed: Int64, available: Int64)
        /// This install's data went into a transfer; it cannot be packed again or receive another.
        case alreadyMoved
        /// The store holds an encryption identity: a restore would replace it.
        case identityExists
        /// The store holds another account's chats.
        case accountExists
        /// A previous-version backup is here; its copy is sealed with this install's wrapping key.
        case backupExists
        /// This transfer was restored into this install before.
        case alreadyRestored
        /// The archive holds something this build does not know where to put.
        case unrecognised(String)
        /// The moved data is not where the marker says, or a store appeared where it would go back.
        case heldDataMissing
        /// The marker is there but cannot be read (before the first unlock, or damaged): the data may be moved, so
        /// nothing may open or create a store until it can be.
        case markerUnreadable
        case keychain
    }

    let locations: Locations
    var secrets = Secrets.keychain
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "transfer")
    /// Free space required beyond the copies themselves.
    static let spaceMargin: Int64 = 32 << 20

    private enum Name {
        static let database = "messaging/messages.sqlite"
        static let summary = "meta/database.json"
        static let account = "keychain/account"
        static let wrappingKey = "keychain/encryption-state"
        static let pushPrefix = "keychain/push/"
        static let appPreferences = "preferences/app.plist"
        static let groupPreferences = "preferences/group.plist"
        static let messagingPrefix = "messaging/"
    }

    /// Preference keys that describe this install or this device rather than the account: the XMPP resource (a new
    /// install binds its own), the last time the app left the foreground, keyboard measurements and whether the photo
    /// prompt was shown, and which stream last enabled carbons. Keys the system writes (they start with a capital, as
    /// `AppleLanguages`) stay behind too.
    static let installOnlyPrefixes = ["xmppResource.", "leftForeground", "attachmentKeyboard.", "carbonsStream."]

    static func isTransferable(preference key: String) -> Bool {
        guard let first = key.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else { return false }
        return !installOnlyPrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: State at launch

    /// What a launch finds, after finishing what a crash interrupted: an export that never completed is undone (the
    /// store goes back, nothing was offered), a restore that never reached its commit point is rolled back. Returns
    /// the marker while the data is moved.
    func recover() throws -> Moved? {
        let files = FileManager.default
        if files.fileExists(atPath: locations.importJournal.path) {
            Self.log.error("a restore stopped part way; rolling it back")
            try rollBackInterruptedImport()
        } else if files.fileExists(atPath: locations.importPrevious.path) {
            // The restore committed; only its leftovers were not removed.
            try PreUpgradeSnapshot.removeIfPresent(locations.importPrevious)
        }
        try PreUpgradeSnapshot.removeIfPresent(locations.incoming)
        guard let moved = try readMarker() else {
            // An export that failed before its marker leaves only its staging copy.
            try PreUpgradeSnapshot.removeIfPresent(locations.exportStaging)
            return nil
        }
        guard moved.stage == .moved else {
            Self.log.error("an export stopped part way; putting the data back")
            try rollBackExport()
            return nil
        }
        return moved
    }

    func marker() -> Moved? { try? readMarker() }

    /// Nil only when there is no marker; one that is there but does not read throws instead of counting as absent.
    private func readMarker() throws -> Moved? {
        guard FileManager.default.fileExists(atPath: locations.marker.path) else { return nil }
        do { return try JSONDecoder().decode(Moved.self, from: Data(contentsOf: locations.marker)) }
        catch {
            Self.log.error("the transfer marker is there but cannot be read; storage stays closed")
            throw Failure.markerUnreadable
        }
    }

    /// The code that opens the archive, while moved, so the moved screen can show it again after a relaunch. It lives
    /// in the Keychain, never beside the archive: the archive carries the Keychain's own secrets (the account's
    /// password, the encryption state's wrapping key), so a code kept in a file would let anyone who can read this
    /// install's files read those too.
    func code(of moved: Moved) -> TransferCode? {
        (try? secrets.read(locations.codeService, moved.transferID)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }.flatMap(TransferCode.init)
    }

    /// Every stored code goes: only the transfer in progress or moved ever has one.
    private func deleteCodes() throws {
        for transfer in try secrets.accounts(locations.codeService) { try secrets.delete(locations.codeService, transfer) }
    }

    /// The archive, while moved.
    func archive(of moved: Moved) -> URL { locations.outgoing.appending(path: moved.fileName) }

    // MARK: Export

    /// Packs this install's data into a new archive under `code` and leaves the install moved. The caller has stopped
    /// and joined all transport, sender and crypto work and holds `store`'s lease. Before the marker is written a
    /// failure leaves the store open and untouched; after it, the store is closed (under the lease) and moved out of
    /// reach, and a failure puts it back. Either way a caller whose call threw opens storage again.
    func export(store: MessageStore, accountID: String, code: TransferCode, now: Date,
                progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Moved {
        let files = FileManager.default
        guard marker() == nil else { throw Failure.alreadyMoved }
        guard await store.holdsTransportOwnership else { throw MessageStoreError.transportOwnershipRequired }
        for folder in [locations.exportStaging, locations.outgoing] { try PreUpgradeSnapshot.removeIfPresent(folder) }
        try PreUpgradeSnapshot.createProtectedDirectory(locations.directory)
        try PreUpgradeSnapshot.createProtectedDirectory(locations.exportStaging)

        // The archive, and the store's copy it is made from, beside the data itself.
        let folders = PreUpgradeSnapshot.folders.map { locations.install.messaging.appending(path: $0) }
        let database = Self.bytes(at: locations.install.database) + Self.bytes(at: URL(filePath: locations.install.database.path + "-wal"))
        let needed = database * 2 + folders.reduce(0) { $0 + Self.bytes(at: $1) } + Self.spaceMargin
        let available = Self.availableSpace(at: locations.install.groupRoot)
        guard available >= needed else {
            try? PreUpgradeSnapshot.removeIfPresent(locations.exportStaging)
            throw Failure.insufficientSpace(needed: needed, available: available)
        }

        let copy = locations.exportStaging.appending(path: "messages.sqlite")
        let summary: StoreSnapshotSummary
        let deviceLocalPhotos: [ContactLinkPhoto]
        do {
            _ = try await store.writeSnapshot(to: copy)
            // Contact links name this device's contacts, and nothing from Contacts is transferred: the copy leaves
            // without them, and without the photos only they named.
            deviceLocalPhotos = try MessageStore.removeContactLinks(fromSnapshotAt: copy)
            summary = try StoreSnapshotSummary(snapshotAt: copy)
            try PreUpgradeSnapshot.protect(copy)
        } catch { try? PreUpgradeSnapshot.removeIfPresent(locations.exportStaging); throw error }

        let id = UUID().uuidString
        var moved = Moved(stage: .exporting, transferID: id, createdAt: now, accountID: accountID,
                          fileName: "Haus XMPP Transfer \(now.formatted(.iso8601.year().month().day())).\(TransferArchive.fileExtension)")
        do {
            try deleteCodes()
            try secrets.set(locations.codeService, id, Data(code.grouped.utf8))
        } catch {
            try? PreUpgradeSnapshot.removeIfPresent(locations.exportStaging)
            throw Failure.keychain
        }
        // Written before the store moves: from here on the extension stays off, and a crash undoes the export.
        do { try write(moved) } catch {
            try? secrets.delete(locations.codeService, id)
            try? PreUpgradeSnapshot.removeIfPresent(locations.exportStaging)
            throw error
        }
        let messaging = locations.install.messaging, held = locations.held
        do {
            try await store.closeForMigration { try FileManager.default.moveItem(at: messaging, to: held) }
        } catch {
            try? rollBackExport()
            throw error
        }
        do {
            let (manifest, sources) = try contents(snapshot: copy, summary: summary, omitting: deviceLocalPhotos, id: id, accountID: accountID,
                                                   now: now, progress: progress)
            let partial = locations.outgoing.appending(path: moved.fileName + ".partial")
            try PreUpgradeSnapshot.createProtectedDirectory(locations.outgoing)
            let total = max(manifest.totalBytes, 1)
            let encrypting = Throttle { progress(Progress(step: .encrypting, fraction: Double($0) / Double(total))) }
            try TransferArchive.write(manifest, sources: sources, to: partial, code: code, progress: encrypting.report)
            // Read back in full before it is offered: the file that leaves this install must open.
            let checking = Throttle { progress(Progress(step: .checking, fraction: Double($0) / Double(total))) }
            try TransferArchive.open(partial, code: code, supportedSchema: MessageStore.currentSchemaVersion).verify(progress: checking.report)
            let final = archive(of: moved)
            try PreUpgradeSnapshot.removeIfPresent(final)
            try files.moveItem(at: partial, to: final)
            moved.fileSize = Self.bytes(at: final)
            moved.stage = .moved
            try write(moved)
            try? PreUpgradeSnapshot.removeIfPresent(locations.exportStaging)
            Self.log.notice("transfer \(id, privacy: .public) packed: \(manifest.entries.count, privacy: .public) entries, \(manifest.totalBytes, privacy: .public) bytes")
            return moved
        } catch {
            Self.log.error("transfer failed; putting the data back: \(String(describing: error), privacy: .public)")
            try? rollBackExport()
            throw error
        }
    }

    /// Every entry of the archive, described (size and SHA-256), from the store's copy, the held folders (less the
    /// `omitting` photos), the Keychain and the preference domains.
    private func contents(snapshot: URL, summary: StoreSnapshotSummary, omitting photos: [ContactLinkPhoto], id: String, accountID: String, now: Date,
                          progress: @escaping @Sendable (Progress) -> Void) throws -> (TransferManifest, [String: TransferSource]) {
        let files = FileManager.default
        var sources: [String: TransferSource] = [Name.database: .file(snapshot), Name.summary: .data(try JSONEncoder().encode(summary))]
        let omitted = Set(Self.photoFiles(photos, root: locations.held).map(\.standardizedFileURL.path))
        for folder in PreUpgradeSnapshot.folders {
            let root = locations.held.appending(path: folder, directoryHint: .isDirectory)
            guard let items = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            for case let item as URL in items where (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = item.standardizedFileURL.path
                guard path.hasPrefix(prefix), !omitted.contains(path) else { continue }
                sources[Name.messagingPrefix + folder + "/" + path.dropFirst(prefix.count)] = .file(item)
            }
        }
        let keychain = locations.install.keychain
        do {
            if let account = try secrets.read(keychain.accountService, keychain.accountKey) { sources[Name.account] = .data(account) }
            if let key = try secrets.read(locations.encryptionService, locations.storageID) { sources[Name.wrappingKey] = .data(key) }
            for owner in try secrets.accounts(keychain.pushService) {
                guard let data = try secrets.read(keychain.pushService, owner), let encoded = Self.encodedComponent(owner) else { continue }
                sources[Name.pushPrefix + encoded] = .data(data)
            }
        } catch { throw Failure.keychain }
        sources[Name.appPreferences] = .data(try Self.transferablePreferences(locations.install.appDefaults.contents))
        sources[Name.groupPreferences] = .data(try Self.transferablePreferences(locations.install.groupDefaults.contents))

        let total = max(sources.values.reduce(Int64(0)) { total, source in
            if case let .file(url) = source { total + Self.bytes(at: url) } else { total }
        }, 1)
        var described: Int64 = 0
        var entries: [TransferManifest.Entry] = []
        for name in sources.keys.sorted() {
            let entry = try TransferArchive.describe(name: name, source: sources[name]!)
            entries.append(entry)
            if case .file = sources[name]! { described += entry.size }
            progress(Progress(step: .copying, fraction: Double(described) / Double(total)))
        }
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let manifest = TransferManifest(transferID: id, createdAt: now, appVersion: AppInfo.version, appBuild: AppInfo.build, platform: platform,
                                        schemaVersion: summary.schemaVersion, accountID: accountID, entries: entries)
        return (manifest, sources)
    }

    /// The moved state's "Use Here Again", and the undoing of an export that did not finish: the store goes back where
    /// it was, the archive and the marker go. A store found in its place (which nothing should have created) is never
    /// overwritten.
    func rollBackExport() throws {
        let files = FileManager.default, messaging = locations.install.messaging
        if files.fileExists(atPath: locations.held.path) {
            if files.fileExists(atPath: messaging.path) {
                guard !files.fileExists(atPath: locations.install.database.path) else { throw Failure.heldDataMissing }
                // Only folders something recreated after the move (an attachment cache), never a store.
                try PreUpgradeSnapshot.removeIfPresent(messaging)
            }
            try files.moveItem(at: locations.held, to: messaging)
        } else if marker()?.stage == .moved {
            throw Failure.heldDataMissing
        }
        try PreUpgradeSnapshot.removeIfPresent(locations.outgoing)
        try PreUpgradeSnapshot.removeIfPresent(locations.exportStaging)
        do { try deleteCodes() } catch { throw Failure.keychain }
        try PreUpgradeSnapshot.removeIfPresent(locations.marker)
    }

    /// The moved state's "Delete Data": this install's copy of everything the archive carried goes, with the
    /// previous-version backup (it holds an older copy of the same identity) and the archive. The marker goes last, so
    /// an interrupted deletion is still offered on the next launch.
    func deleteMovedData() throws {
        guard marker()?.stage == .moved else { throw Failure.heldDataMissing }
        try PreUpgradeSnapshot.removeIfPresent(locations.held)
        try PreUpgradeSnapshot.removeIfPresent(locations.outgoing)
        try PreUpgradeSnapshot(locations: locations.install).delete()
        let keychain = locations.install.keychain
        do {
            try secrets.delete(keychain.accountService, keychain.accountKey)
            try secrets.delete(locations.encryptionService, locations.storageID)
            for owner in try secrets.accounts(keychain.pushService) { try secrets.delete(keychain.pushService, owner) }
            try deleteCodes()
        } catch { throw Failure.keychain }
        for domain in [locations.install.appDefaults, locations.install.groupDefaults] {
            domain.replace(with: domain.contents.filter { !Self.isTransferable(preference: $0.key) })
            domain.defaults.synchronize()
        }
        try PreUpgradeSnapshot.removeIfPresent(locations.marker)
        Self.log.notice("deleted this install's copy of a transferred account")
    }

    // MARK: Import

    /// A transfer read and checked into `incoming.partial/`, ready to be put in place.
    struct Staged: Sendable {
        let manifest: TransferManifest
        /// The store and its folders, as `Messaging/` will hold them.
        let messaging: URL
        /// The Keychain records and preferences, by entry name.
        let records: [String: Data]
    }

    /// Reads `archive` with `code` and extracts it into the staging folder, checking everything: the code, the
    /// manifest (a newer format or schema is refused), every entry's size and SHA-256, the database against its
    /// summary, and that each record is what its name says. Changes nothing outside the staging folder.
    func stage(archive: URL, code: TransferCode, progress: @escaping @Sendable (Progress) -> Void = { _ in }) throws -> Staged {
        let reader = try TransferArchive.open(archive, code: code, supportedSchema: MessageStore.currentSchemaVersion)
        let manifest = reader.manifest
        guard !restoredTransfers().contains(manifest.transferID) else { throw Failure.alreadyRestored }
        for entry in manifest.entries {
            let known = entry.name == Name.database || entry.name == Name.summary || entry.name == Name.account || entry.name == Name.wrappingKey
                || entry.name == Name.appPreferences || entry.name == Name.groupPreferences
                || (entry.name.hasPrefix(Name.pushPrefix) && !entry.name.dropFirst(Name.pushPrefix.count).contains("/"))
                || PreUpgradeSnapshot.folders.contains { entry.name.hasPrefix(Name.messagingPrefix + $0 + "/") }
            guard known else { throw Failure.unrecognised(entry.name) }
        }
        guard manifest.entry(named: Name.database) != nil, manifest.entry(named: Name.summary) != nil else { throw Failure.unrecognised("no database") }
        let needed = manifest.totalBytes + Self.spaceMargin
        let available = Self.availableSpace(at: locations.install.groupRoot)
        guard available >= needed else { throw Failure.insufficientSpace(needed: needed, available: available) }

        try PreUpgradeSnapshot.removeIfPresent(locations.incoming)
        try PreUpgradeSnapshot.createProtectedDirectory(locations.directory)
        try PreUpgradeSnapshot.createProtectedDirectory(locations.incoming)
        do {
            let total = max(manifest.totalBytes, 1)
            let reading = Throttle { progress(Progress(step: .restoring, fraction: Double($0) / Double(total))) }
            let records = try reader.extract(into: locations.incoming, inMemory: { !$0.name.hasPrefix(Name.messagingPrefix) }, progress: reading.report)
            let messaging = locations.incoming.appending(path: "messaging", directoryHint: .isDirectory)
            let database = messaging.appending(path: "messages.sqlite")
            let summary = try JSONDecoder().decode(StoreSnapshotSummary.self, from: records[Name.summary] ?? Data())
            guard summary.schemaVersion == manifest.schemaVersion else { throw TransferArchiveError.damaged }
            try MessageStore.verifySnapshot(at: database, matches: summary)
            // Contact links from a build that still packed them name another device's contacts: they go before the
            // commit, for every account, with the photos only they named.
            for file in Self.photoFiles(try MessageStore.removeContactLinks(fromSnapshotAt: database), root: messaging) {
                try PreUpgradeSnapshot.removeIfPresent(file)
            }
            // As every build keeps its live store; the copy was made in rollback-journal mode.
            try MessageStore.useWriteAheadLog(at: database)
            for suffix in ["-wal", "-shm"] { try PreUpgradeSnapshot.removeIfPresent(URL(filePath: database.path + suffix)) }
            try PreUpgradeSnapshot.protectTree(messaging)
            if let key = records[Name.wrappingKey], key.count != 32 { throw Failure.unrecognised(Name.wrappingKey) }
            if let account = records[Name.account] { _ = try Self.decodeAccount(account) }
            for (name, data) in records where name.hasPrefix(Name.pushPrefix) {
                let state = try JSONDecoder().decode(PushRegistrationState.self, from: data)
                guard Self.encodedComponent(state.accountID) == String(name.dropFirst(Name.pushPrefix.count)) else { throw Failure.unrecognised(name) }
            }
            for name in [Name.appPreferences, Name.groupPreferences] where records[name] != nil {
                _ = try Self.preferences(records[name]!)
            }
            return Staged(manifest: manifest, messaging: messaging, records: records)
        } catch {
            try? PreUpgradeSnapshot.removeIfPresent(locations.incoming)
            throw error
        }
    }

    /// Why this install cannot take a restore, or nil: it must hold no encryption identity and no account's data but
    /// the sample conversations, no previous-version backup, and must not have moved its own data away.
    func importBlocker(store: MessageStore) async throws -> Failure? {
        if marker() != nil { return .alreadyMoved }
        if try await store.hasAnyEncryptionState() { return .identityExists }
        if !(try await store.storedAccountIDs()).subtracting([DemoSamples.account]).isEmpty { return .accountExists }
        let backups = PreUpgradeSnapshot(locations: locations.install)
        if PreUpgradeHold.isHeld(groupRoot: locations.install.groupRoot) || PreUpgradeSnapshot.Copy.allCases.contains(where: { backups.status($0) != .absent }) {
            return .backupExists
        }
        return nil
    }

    /// What a restore replaces, read before it does: put back exactly if it fails.
    private struct Previous {
        var secrets: [(service: String, account: String, data: Data?)] = []
        var appDefaults: [String: Any] = [:]
        var groupDefaults: [String: Any] = [:]
        var notificationsDisabled = false
    }

    private struct Journal: Codable {
        let transferID: String
        let startedAt: Date
        let pushAccounts: [String]
    }

    /// Puts a staged transfer in place of this install's (empty) data, all or nothing. The caller holds `store`'s
    /// lease with nothing running on it; the store is closed here, under the lease, before any file moves, and the
    /// caller opens storage again afterwards whatever the outcome (an older schema then migrates the usual way,
    /// backup first). Refuses, changing nothing, when `importBlocker` names a reason. Until the journal is removed
    /// every step is undone on failure, here or, after a crash, by `recover`.
    func commit(_ staged: Staged, store: MessageStore, now: Date) async throws {
        let files = FileManager.default
        guard await store.holdsTransportOwnership else { throw MessageStoreError.transportOwnershipRequired }
        if let blocker = try await importBlocker(store: store) { throw blocker }
        let keychain = locations.install.keychain

        // Everything decoded and rewritten for this install before anything changes.
        var writes: [(service: String, account: String, data: Data)] = []
        if let record = staged.records[Name.account] {
            // Without its push subscription: this install registers its own.
            writes.append((keychain.accountService, keychain.accountKey, try JSONEncoder().encode(try Self.decodeAccount(record).replacingPush(nil))))
        }
        if let key = staged.records[Name.wrappingKey] { writes.append((locations.encryptionService, locations.storageID, key)) }
        var pushAccounts: [String] = []
        for (name, data) in staged.records.sorted(by: { $0.key < $1.key }) where name.hasPrefix(Name.pushPrefix) {
            let saved = try JSONDecoder().decode(PushRegistrationState.self, from: data)
            // The registration the other install made: revoked at the gateway and disabled at the account server on
            // this install's first connection, before it registers its own device.
            guard let off = try PushRegistrationState.turningOff(accountID: saved.accountID, saved: saved, enabled: nil) else { continue }
            writes.append((keychain.pushService, saved.accountID, try JSONEncoder().encode(off)))
            pushAccounts.append(saved.accountID)
        }
        let appDefaults = try staged.records[Name.appPreferences].map(Self.preferences) ?? [:]
        let groupDefaults = try staged.records[Name.groupPreferences].map(Self.preferences) ?? [:]

        var previous = Previous(appDefaults: locations.install.appDefaults.contents, groupDefaults: locations.install.groupDefaults.contents,
                                notificationsDisabled: files.fileExists(atPath: locations.install.accessGate.path))
        do {
            for write in writes { previous.secrets.append((write.service, write.account, try secrets.read(write.service, write.account))) }
        } catch { throw Failure.keychain }

        try PreUpgradeSnapshot.removeIfPresent(locations.importPrevious)
        try PreUpgradeSnapshot.createProtectedDirectory(locations.importPrevious)
        for (contents, file) in [(previous.appDefaults, "app.plist"), (previous.groupDefaults, "group.plist")] {
            try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
                .write(to: locations.importPrevious.appending(path: file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try JSONEncoder().encode(Journal(transferID: staged.manifest.transferID, startedAt: now, pushAccounts: pushAccounts))
            .write(to: locations.importJournal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        let messaging = locations.install.messaging, aside = locations.importPrevious.appending(path: "Messaging", directoryHint: .isDirectory)
        let incoming = staged.messaging
        do {
            try await store.closeForMigration {
                let files = FileManager.default
                try files.moveItem(at: messaging, to: aside)
                do { try files.moveItem(at: incoming, to: messaging) }
                catch { try? files.moveItem(at: aside, to: messaging); throw error }
            }
            do { for write in writes { try secrets.set(write.service, write.account, write.data) } }
            catch { throw Failure.keychain }
            locations.install.appDefaults.replace(with: Self.merging(appDefaults, into: previous.appDefaults))
            locations.install.groupDefaults.replace(with: Self.merging(groupDefaults, into: previous.groupDefaults))
            for domain in [locations.install.appDefaults, locations.install.groupDefaults] { domain.defaults.synchronize() }
            if staged.records[Name.account] != nil { try PreUpgradeSnapshot.removeIfPresent(locations.install.accessGate) }
            // The commit point.
            try PreUpgradeSnapshot.removeIfPresent(locations.importJournal)
        } catch {
            Self.log.error("restore failed; putting this install's data back: \(String(describing: error), privacy: .public)")
            rollBackImport(previous)
            throw error
        }
        try? recordRestored(staged.manifest.transferID, at: now)
        try? PreUpgradeSnapshot.removeIfPresent(locations.importPrevious)
        try? PreUpgradeSnapshot.removeIfPresent(locations.incoming)
        Self.log.notice("restored transfer \(staged.manifest.transferID, privacy: .public): schema \(staged.manifest.schemaVersion, privacy: .public), \(staged.manifest.entries.count, privacy: .public) entries")
    }

    /// Undoes a restore that failed in this process, from what it read before: every step is tried, so one that fails
    /// does not leave the others undone.
    private func rollBackImport(_ previous: Previous) {
        restorePreviousMessaging()
        for item in previous.secrets {
            if let data = item.data { try? secrets.set(item.service, item.account, data) } else { try? secrets.delete(item.service, item.account) }
        }
        locations.install.appDefaults.replace(with: previous.appDefaults)
        locations.install.groupDefaults.replace(with: previous.groupDefaults)
        for domain in [locations.install.appDefaults, locations.install.groupDefaults] { domain.defaults.synchronize() }
        if previous.notificationsDisabled, !FileManager.default.fileExists(atPath: locations.install.accessGate.path) {
            try? Data("disabled\n".utf8).write(to: locations.install.accessGate, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try? PreUpgradeSnapshot.removeIfPresent(locations.importJournal)
        try? PreUpgradeSnapshot.removeIfPresent(locations.importPrevious)
        try? PreUpgradeSnapshot.removeIfPresent(locations.incoming)
    }

    /// Undoes a restore a crash interrupted. The files and preferences come back from `import-previous/`. The Keychain
    /// items it may have written are deleted: the install it replaced held no identity and no signed-in account, so
    /// none of them was in use.
    private func rollBackInterruptedImport() throws {
        let journal = try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: locations.importJournal))
        restorePreviousMessaging()
        for (domain, file) in [(locations.install.appDefaults, "app.plist"), (locations.install.groupDefaults, "group.plist")] {
            if let data = try? Data(contentsOf: locations.importPrevious.appending(path: file)), let contents = try? Self.preferences(data) {
                domain.replace(with: contents)
                domain.defaults.synchronize()
            }
        }
        let keychain = locations.install.keychain
        try? secrets.delete(keychain.accountService, keychain.accountKey)
        try? secrets.delete(locations.encryptionService, locations.storageID)
        for owner in journal?.pushAccounts ?? [] { try? secrets.delete(keychain.pushService, owner) }
        try PreUpgradeSnapshot.removeIfPresent(locations.importJournal)
        try PreUpgradeSnapshot.removeIfPresent(locations.importPrevious)
    }

    private func restorePreviousMessaging() {
        let files = FileManager.default, messaging = locations.install.messaging
        let aside = locations.importPrevious.appending(path: "Messaging", directoryHint: .isDirectory)
        guard files.fileExists(atPath: aside.path) else { return }
        try? PreUpgradeSnapshot.removeIfPresent(messaging)
        try? files.moveItem(at: aside, to: messaging)
    }

    func restoredTransfers() -> Set<String> {
        Set(((try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: locations.imported))) ?? [:]).keys)
    }

    private func recordRestored(_ id: String, at now: Date) throws {
        var restored = (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: locations.imported))) ?? [:]
        restored[id] = now
        try JSONEncoder().encode(restored).write(to: locations.imported, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Helpers

    private func write(_ moved: Moved) throws {
        try JSONEncoder().encode(moved).write(to: locations.marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A contact link photo's two files (`ContactPhoto`) under a `Messaging/` folder.
    static func photoFiles(_ photos: [ContactLinkPhoto], root: URL) -> [URL] {
        photos.flatMap { [AvatarStore.url(root: root, account: $0.accountID, hash: $0.hash),
                          AvatarStore.notificationImageURL(root: root, account: $0.accountID, hash: $0.hash)] }
    }

    static func describe(_ error: any Error) -> String {
        let device = ThisDevice.noun
        switch error {
        case TransferArchiveError.wrongCode: return "That code doesn’t open this file. Check it against the code on the other \(device)."
        case TransferArchiveError.notATransfer: return "This file isn’t a Haus XMPP transfer."
        case TransferArchiveError.truncated: return "This file is incomplete. Copy it again from the other \(device)."
        case TransferArchiveError.damaged, TransferArchiveError.invalidManifest, TransferArchiveError.sourceChanged:
            return "This file is damaged and can’t be restored. Make a new transfer on the other \(device)."
        case TransferArchiveError.newerFormat, TransferArchiveError.newerSchema, Failure.unrecognised:
            return "This version of Haus XMPP is older than your data. Install the latest version from TestFlight or the App Store, then try again."
        case Failure.identityExists, Failure.accountExists:
            return "This \(device) already has an account set up with its own encryption keys. A transfer can only be restored into a fresh install, so nothing was changed."
        case Failure.backupExists:
            return "This \(device) keeps a backup of a previous version’s data. Delete it in Settings first; nothing was changed."
        case Failure.alreadyRestored: return "This transfer was already restored on this \(device)."
        case Failure.alreadyMoved: return "This \(device)’s data was moved to another install."
        case Failure.insufficientSpace(let needed, let available):
            let format = ByteCountFormatter()
            return "There isn’t enough free space on this \(device). The transfer needs \(format.string(fromByteCount: needed)); \(format.string(fromByteCount: max(available, 0))) is free."
        case Failure.keychain: return "The saved account could not be read or written. Unlock your \(device) and try again."
        default: return "Something went wrong, and nothing was changed. Try again."
        }
    }

    static func decodeAccount(_ data: Data) throws -> NotificationAccount {
        try JSONDecoder().decode(NotificationAccount.self, from: NotificationAccount.normalizingIdentity(data))
    }

    static func transferablePreferences(_ contents: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: contents.filter { isTransferable(preference: $0.key) }, format: .binary, options: 0)
    }

    static func preferences(_ data: Data) throws -> [String: Any] {
        guard let contents = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.unrecognised("preferences")
        }
        return contents.filter { isTransferable(preference: $0.key) }
    }

    /// This install's own keys stay; every transferable one is the archive's.
    static func merging(_ imported: [String: Any], into current: [String: Any]) -> [String: Any] {
        current.filter { !isTransferable(preference: $0.key) }.merging(imported) { _, new in new }
    }

    /// An account address as one name component.
    static func encodedComponent(_ value: String) -> String? { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }

    static func bytes(at url: URL) -> Int64 {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return ((try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        var total: Int64 = 0
        guard let items = files.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let item as URL in items {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func availableSpace(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }
}

/// Passes on a byte count only once it moved by a mebibyte or more, so the screen is not redrawn for every frame.
private final class Throttle: @unchecked Sendable {
    private let sink: (Int64) -> Void
    private var last: Int64 = -1
    private let lock = NSLock()
    init(_ sink: @escaping (Int64) -> Void) { self.sink = sink }
    func report(_ value: Int64) {
        lock.lock()
        guard last < 0 || value - last >= 1 << 20 else { lock.unlock(); return }
        last = value
        lock.unlock()
        sink(value)
    }
}
