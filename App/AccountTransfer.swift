import Foundation
import MessageStore
import MessagingCore
import os

// Moves an install's accounts to another install as one encrypted file, never a copy: two installs sharing an OMEMO
// identity break contacts' sessions. Export ends "moved" (store in `held/`, marker keeps app and extension off) until
// this copy is deleted or taken back, safe only if the file was never restored anywhere. Push arrives turned off.
struct AccountTransfer: Sendable {
    struct Locations: Sendable {
        let install: PreUpgradeSnapshot.Locations
        let encryptionService: String
        let storageID: String
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

        // DEBUG UI test sessions get their own store, preferences and Keychain items, so a transfer never
        // reaches real data.
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

    // Raw bytes, never decoded on the way through.
    struct Secrets: Sendable {
        var read: @Sendable (_ service: String, _ account: String) throws -> Data?
        var accounts: @Sendable (_ service: String) throws -> [String]
        var set: @Sendable (_ service: String, _ account: String, _ data: Data) throws -> Void
        var delete: @Sendable (_ service: String, _ account: String) throws -> Void

        static let keychain = Secrets(read: PreUpgradeSnapshot.keychainData, accounts: PreUpgradeSnapshot.keychainAccounts,
                                      set: PreUpgradeSnapshot.keychainSet, delete: PreUpgradeSnapshot.keychainDelete)
    }

    struct Moved: Codable, Sendable, Equatable {
        enum Stage: String, Codable, Sendable {
            // A launch that finds this undoes it: no archive was ever offered.
            case exporting
            // Only the user ends this.
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
        let fraction: Double
    }

    enum Failure: Error, Equatable {
        case insufficientSpace(needed: Int64, available: Int64)
        case alreadyMoved
        case identityExists
        case accountExists
        // Its copy is sealed with this install's wrapping key.
        case backupExists
        case alreadyRestored
        case unrecognised(String)
        case heldDataMissing
        // Unreadable before first unlock or when damaged: the data may be moved, so no store may open until it reads.
        case markerUnreadable
        case keychain
    }

    let locations: Locations
    var secrets = Secrets.keychain
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "transfer")
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

    // Install- or device-specific keys stay behind; system keys (capitalised, e.g. `AppleLanguages`) stay too.
    static let installOnlyPrefixes = ["xmppResource.", "leftForeground", "attachmentKeyboard.", "carbonsStream."]

    static func isTransferable(preference key: String) -> Bool {
        guard let first = key.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else { return false }
        return !installOnlyPrefixes.contains { key.hasPrefix($0) }
    }

    // Undoes an export that never completed and rolls back a restore that never reached its commit point.
    func recover() throws -> Moved? {
        let files = FileManager.default
        if files.fileExists(atPath: locations.importJournal.path) {
            Self.log.error("a restore stopped part way; rolling it back")
            try rollBackInterruptedImport()
        } else if files.fileExists(atPath: locations.importPrevious.path) {
            try PreUpgradeSnapshot.removeIfPresent(locations.importPrevious)
        }
        try PreUpgradeSnapshot.removeIfPresent(locations.incoming)
        guard let moved = try readMarker() else {
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

    // A marker that exists but does not read throws rather than counting as absent.
    private func readMarker() throws -> Moved? {
        guard FileManager.default.fileExists(atPath: locations.marker.path) else { return nil }
        do { return try JSONDecoder().decode(Moved.self, from: Data(contentsOf: locations.marker)) }
        catch {
            Self.log.error("the transfer marker is there but cannot be read; storage stays closed")
            throw Failure.markerUnreadable
        }
    }

    // Kept in the Keychain, never beside the archive: the archive carries Keychain secrets, so a code in a file would
    // expose them to anyone who can read this install's files.
    func code(of moved: Moved) -> TransferCode? {
        (try? secrets.read(locations.codeService, moved.transferID)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }.flatMap(TransferCode.init)
    }

    private func deleteCodes() throws {
        for transfer in try secrets.accounts(locations.codeService) { try secrets.delete(locations.codeService, transfer) }
    }

    func archive(of moved: Moved) -> URL { locations.outgoing.appending(path: moved.fileName) }

    // Caller has joined all transport, sender and crypto work and holds `store`'s lease. Before the marker a failure
    // leaves the store untouched; after it the store is closed under the lease and moved, and a failure puts it back.
    // Either way a caller whose call threw opens storage again.
    func export(store: MessageStore, accountID: String, code: TransferCode, now: Date,
                progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Moved {
        let files = FileManager.default
        guard marker() == nil else { throw Failure.alreadyMoved }
        guard await store.holdsTransportOwnership else { throw MessageStoreError.transportOwnershipRequired }
        for folder in [locations.exportStaging, locations.outgoing] { try PreUpgradeSnapshot.removeIfPresent(folder) }
        try PreUpgradeSnapshot.createProtectedDirectory(locations.directory)
        try PreUpgradeSnapshot.createProtectedDirectory(locations.exportStaging)

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
            // What a transfer omits (`AccountTable`, contact links) stays here, and so do the photos only links named.
            deviceLocalPhotos = try MessageStore.removeDeviceLocalRows(fromSnapshotAt: copy)
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

    // A store found where the held one would go back is never overwritten.
    func rollBackExport() throws {
        let files = FileManager.default, messaging = locations.install.messaging
        if files.fileExists(atPath: locations.held.path) {
            if files.fileExists(atPath: messaging.path) {
                guard !files.fileExists(atPath: locations.install.database.path) else { throw Failure.heldDataMissing }
                // Only folders recreated after the move (an attachment cache), never a store.
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

    // The previous-version backup goes too (it holds the same identity). The marker goes last, so an interrupted
    // deletion is offered again on the next launch.
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

    struct Staged: Sendable {
        let manifest: TransferManifest
        let messaging: URL
        let records: [String: Data]
    }

    // Verifies code, manifest version, every entry's size and SHA-256, the database summary and record types;
    // changes nothing outside the staging folder.
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
            // An archive from an older build may hold rows a transfer omits; they go before the commit.
            for file in Self.photoFiles(try MessageStore.removeDeviceLocalRows(fromSnapshotAt: database), root: messaging) {
                try PreUpgradeSnapshot.removeIfPresent(file)
            }
            // The snapshot copy is in rollback-journal mode.
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

    // All or nothing. The caller holds `store`'s lease with nothing running; the store closes under it before any file
    // moves. Until the journal is removed every step is undone on failure, here or by `recover` after a crash.
    // Whatever the outcome, the caller opens storage again.
    func commit(_ staged: Staged, store: MessageStore, now: Date) async throws {
        let files = FileManager.default
        guard await store.holdsTransportOwnership else { throw MessageStoreError.transportOwnershipRequired }
        if let blocker = try await importBlocker(store: store) { throw blocker }
        let keychain = locations.install.keychain

        var writes: [(service: String, account: String, data: Data)] = []
        if let record = staged.records[Name.account] {
            // Without its push subscription: this install registers its own.
            writes.append((keychain.accountService, keychain.accountKey, try JSONEncoder().encode(try Self.decodeAccount(record).replacingPush(nil))))
        }
        if let key = staged.records[Name.wrappingKey] { writes.append((locations.encryptionService, locations.storageID, key)) }
        var pushAccounts: [String] = []
        for (name, data) in staged.records.sorted(by: { $0.key < $1.key }) where name.hasPrefix(Name.pushPrefix) {
            let saved = try JSONDecoder().decode(PushRegistrationState.self, from: data)
            // Revoked at the gateway and disabled at the server on first connection, before this install registers.
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

    // Every step is tried, so one failure does not leave the others undone.
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

    // The Keychain items it wrote are deleted: the replaced install held no identity or signed-in account.
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

    private func write(_ moved: Moved) throws {
        try JSONEncoder().encode(moved).write(to: locations.marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func photoFiles(_ photos: [ContactLinkPhoto], root: URL) -> [URL] {
        photos.flatMap { AvatarStore.files(root: root, account: $0.accountID, hash: $0.hash) }
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

    static func merging(_ imported: [String: Any], into current: [String: Any]) -> [String: Any] {
        current.filter { !isTransferable(preference: $0.key) }.merging(imported) { _, new in new }
    }

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

// `last` changes only under `lock`; `sink` wraps the caller's `@Sendable` progress callback.
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
