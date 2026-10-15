import XCTest
import Foundation
import MessageStore
import MessagingCore
import OMEMO
import XMPPProtocol
@testable import HausXMPP

/// A transfer between two installs, through `AccountTransfer` with isolated locations for each: a temporary App Group
/// root, throwaway preference domains and Keychain services of its own. Never the app's real data. The source holds a
/// real OMEMO identity with a trusted peer device, so "the same identity arrives" is checked by the OMEMO service
/// reading the target's store with the target's own Keychain item.
@MainActor final class AccountTransferTests: XCTestCase {
    private let account = "ellie@localhost"
    private let peer = "bob@localhost"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor private final class Install {
        let root: URL
        let id = UUID().uuidString
        let locations: AccountTransfer.Locations
        var stores: [MessageStore] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "transfer-\(UUID())", directoryHint: .isDirectory)
            let messaging = root.appending(path: "Messaging", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: messaging, withIntermediateDirectories: true)
            // Suites named by a path inside the root keep their plists there.
            let app = root.appending(path: "app-preferences").path, group = root.appending(path: "group-preferences").path
            let install = PreUpgradeSnapshot.Locations(
                groupRoot: root, messaging: messaging,
                appDefaults: .init(defaults: UserDefaults(suiteName: app)!, name: app),
                groupDefaults: .init(defaults: UserDefaults(suiteName: group)!, name: group),
                keychain: .init(accountService: "haus.xmpp.transfer-test.\(id).account", accountKey: "primary",
                                pushService: "haus.xmpp.transfer-test.\(id).push", snapshotService: "haus.xmpp.transfer-test.\(id).snapshot"),
                accessGate: root.appending(path: "notification-access-disabled"), installation: "/install/\(id)")
            locations = AccountTransfer.Locations(install: install, encryptionService: "haus.xmpp.transfer-test.\(id).encryption", storageID: "primary")
        }

        var transfer: AccountTransfer { AccountTransfer(locations: locations) }
        var keychain: PreUpgradeSnapshot.KeychainNames { locations.install.keychain }
        var appDefaults: UserDefaults { locations.install.appDefaults.defaults }
        var groupDefaults: UserDefaults { locations.install.groupDefaults.defaults }

        func openStore() throws -> MessageStore {
            let store = try MessageStore(url: locations.install.database)
            stores.append(store)
            return store
        }

        /// The service as the app makes it: the store with this install's own wrapping key.
        func encryption(_ store: MessageStore) throws -> OMEMOService {
            let key = try XCTUnwrap(try PreUpgradeSnapshot.keychainData(service: locations.encryptionService, account: locations.storageID))
            return OMEMOService(store: store, protection: try StateProtection(key: key))
        }

        func remove() async {
            for store in stores { try? await store.close() }
            for domain in [locations.install.appDefaults, locations.install.groupDefaults] {
                domain.defaults.removePersistentDomain(forName: domain.name)
                domain.defaults.synchronize()
            }
            try? FileManager.default.removeItem(at: root)
            let names = locations.install.keychain
            for service in [names.accountService, names.pushService, names.snapshotService(generation: PreUpgradeHold.generation), locations.encryptionService] {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
            }
        }
    }

    private func makeInstall() throws -> Install {
        let made = try Install()
        addTeardownBlock { await made.remove() }
        return made
    }

    private func randomKey() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    private struct Signed {
        let store: MessageStore
        let overview: EncryptionOverview
        let messages: [StoredMessage]
        let photo: Data
    }

    /// A signed-in install as the app leaves it: an identity, a peer device the user accepted, a chat with messages
    /// and a received photo, the account record and a settled push registration in the Keychain, and preferences
    /// that travel (the selected account, the accent) beside ones that belong to the install (the resource, a
    /// keyboard measurement).
    private func signedIn(_ install: Install) async throws -> Signed {
        let server = LifecyclePublicationServer()
        let store = try install.openStore()
        try PreUpgradeSnapshot.keychainSet(service: install.locations.encryptionService, account: install.locations.storageID, data: randomKey())
        let service = try install.encryption(store)
        try await service.initialize(account: account, transport: LocalPublicationFixture(account: account, server: server))

        let peerStore = try MessageStore(url: install.root.appending(path: "peer.sqlite"))
        install.stores.append(peerStore)
        let peerService = OMEMOService(store: peerStore, protection: try StateProtection(key: randomKey()))
        try await peerService.initialize(account: peer, transport: LocalPublicationFixture(account: peer, server: server))

        try await store.upsertChat(accountID: account, chatID: peer, title: "Bob")
        let found = try await service.refreshDevices(account: account, peer: peer, profile: .legacy,
                                                     transport: LocalPublicationFixture(account: account, server: server))
        for device in found.devices where device.jid == peer { try await service.setTrust(account: account, deviceID: device.id, trust: .accepted) }
        for (index, body) in ["Morning!", "Coffee at nine?"].enumerated() {
            try await store.insertMessage(StoredMessage(id: "m\(index)", accountID: account, chatID: peer, senderID: index == 0 ? peer : account, body: body,
                                                        sentAt: now.addingTimeInterval(Double(index)), isOutgoing: index == 1))
        }
        let photo = Data("synthetic photo bytes".utf8)
        let cache = AttachmentFiles.root(directory: install.locations.install.messaging, account: account).appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try photo.write(to: cache.appending(path: "photo.jpg"))

        let push = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "source-node")
        let record = NotificationAccount(accountID: account, host: "localhost", port: 5223, domain: "localhost", username: "ellie",
                                         password: "synthetic-password", push: push)
        try PreUpgradeSnapshot.keychainSet(service: install.keychain.accountService, account: install.keychain.accountKey, data: JSONEncoder().encode(record))
        var journal = PushRegistrationJournal()
        let registration = try journal.stageFreshRegistration(deviceToken: "AABBCC")
        XCTAssertTrue(journal.acknowledge(try XMPPPushRegistrationResult(revision: registration.revision, action: .register), for: registration))
        try PreUpgradeSnapshot.keychainSet(service: install.keychain.pushService, account: account,
                                           data: JSONEncoder().encode(PushRegistrationState(accountID: account, configuration: push, journal: journal)))

        install.appDefaults.set(account, forKey: "lastAccount")
        install.appDefaults.set("mint", forKey: "accentTheme")
        install.appDefaults.set(301.0, forKey: "attachmentKeyboard.height.portrait")
        install.groupDefaults.set("source-resource", forKey: "xmppResource.\(account)")
        install.groupDefaults.set(["spam@example.org"], forKey: "blocklist.\(account)")

        let overview = try await service.overview(account: account, peer: peer)
        XCTAssertTrue(overview.devices.contains { $0.jid == peer && $0.trust == .accepted }, "the fixture trusts the peer's device")
        return Signed(store: store, overview: overview, messages: try await store.messages(accountID: account, chatID: peer), photo: photo)
    }

    private func export(_ install: Install, store: MessageStore, code: TransferCode) async throws -> AccountTransfer.Moved {
        try await store.acquireTransportOwnership()
        return try await install.transfer.export(store: store, accountID: account, code: code, now: now)
    }

    /// The move the owner makes: export leaves the source moved, with its store out of reach; the target, a fresh
    /// install with its own locations, ends up with the same messages, files, identity and trust, its own Keychain
    /// items and preferences, push to be set up again, and the install's own preferences left behind; deleting the
    /// source's copy afterwards leaves nothing of the account there.
    func testAMoveCarriesTheIdentityTrustAndMessagesToAFreshInstall() async throws {
        let source = try makeInstall(), target = try makeInstall()
        let signed = try await signedIn(source)
        let code = TransferCode.generate()
        let moved = try await export(source, store: signed.store, code: code)

        XCTAssertEqual(moved.stage, .moved)
        XCTAssertTrue(TransferHold.isMoved(groupRoot: source.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.locations.install.database.path), "the store is out of reach of every process")
        XCTAssertEqual(try source.transfer.recover(), moved, "a relaunch finds the install still moved")
        let archive = source.transfer.archive(of: moved)
        XCTAssertGreaterThan(moved.fileSize, 0)

        let fresh = try target.openStore()
        try PreUpgradeSnapshot.keychainSet(service: target.locations.encryptionService, account: target.locations.storageID, data: randomKey())
        target.appDefaults.set(280.0, forKey: "attachmentKeyboard.height.portrait")
        let staged = try target.transfer.stage(archive: archive, code: try XCTUnwrap(TransferCode(code.grouped.lowercased())))
        XCTAssertEqual(staged.manifest.accountID, account)
        XCTAssertEqual(staged.manifest.schemaVersion, MessageStore.currentSchemaVersion)
        try await fresh.acquireTransportOwnership()
        try await target.transfer.commit(staged, store: fresh, now: now)

        let restored = try target.openStore()
        let service = try target.encryption(restored)
        let overview = try await service.overview(account: account, peer: peer)
        XCTAssertEqual(overview.localDeviceID, signed.overview.localDeviceID, "the same device: contacts see no new one")
        XCTAssertEqual(overview.localFingerprint, signed.overview.localFingerprint)
        XCTAssertEqual(overview.devices, signed.overview.devices, "trust decisions came along")
        let bodies = try await restored.messages(accountID: account, chatID: peer).map(\.body)
        XCTAssertEqual(bodies, signed.messages.map(\.body))
        let photo = AttachmentFiles.root(directory: target.locations.install.messaging, account: account).appending(path: "cache/photo.jpg")
        XCTAssertEqual(try Data(contentsOf: photo), signed.photo)

        // Re-keyed into the target's own Keychain items, without the source's push subscription.
        let record = try JSONDecoder().decode(NotificationAccount.self, from: XCTUnwrap(try PreUpgradeSnapshot.keychainData(service: target.keychain.accountService, account: "primary")))
        XCTAssertEqual(record.password, "synthetic-password")
        XCTAssertNil(record.push, "this install registers its own device")
        let push = try PushRegistrationState.load(accountID: account, service: target.keychain.pushService)
        XCTAssertEqual(push?.configuration.node, "source-node")
        XCTAssertEqual(push?.journal.pending?.action, .revoke, "the source device's registration is revoked first")
        XCTAssertEqual(push?.disablePending, true)

        XCTAssertEqual(target.appDefaults.string(forKey: "lastAccount"), account)
        XCTAssertEqual(target.appDefaults.string(forKey: "accentTheme"), "mint")
        XCTAssertEqual(target.appDefaults.double(forKey: "attachmentKeyboard.height.portrait"), 280, "this device's measurement stays")
        XCTAssertNil(target.groupDefaults.string(forKey: "xmppResource.\(account)"), "this install binds its own resource")
        XCTAssertEqual(target.groupDefaults.stringArray(forKey: "blocklist.\(account)"), ["spam@example.org"])

        // One-time: the same file is refused here from now on.
        XCTAssertThrowsError(try target.transfer.stage(archive: archive, code: code)) {
            XCTAssertEqual($0 as? AccountTransfer.Failure, .alreadyRestored)
        }

        try source.transfer.deleteMovedData()
        XCTAssertNil(try source.transfer.recover())
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.locations.held.path))
        XCTAssertNil(try PreUpgradeSnapshot.keychainData(service: source.keychain.accountService, account: "primary"))
        XCTAssertNil(try PreUpgradeSnapshot.keychainData(service: source.locations.encryptionService, account: "primary"))
        XCTAssertEqual(try PreUpgradeSnapshot.keychainAccounts(service: source.keychain.pushService), [])
        XCTAssertNil(source.appDefaults.string(forKey: "lastAccount"))
        XCTAssertEqual(source.appDefaults.double(forKey: "attachmentKeyboard.height.portrait"), 301)
    }

    /// An install that has an identity of its own never takes a restore: nothing in it changes.
    func testARestoreIsRefusedWhenTheTargetHasAnIdentity() async throws {
        let source = try makeInstall(), target = try makeInstall()
        let signed = try await signedIn(source)
        let code = TransferCode.generate()
        let moved = try await export(source, store: signed.store, code: code)

        let existing = try target.openStore()
        try PreUpgradeSnapshot.keychainSet(service: target.locations.encryptionService, account: target.locations.storageID, data: randomKey())
        try await target.encryption(existing).initialize(account: "other@localhost", transport: LocalPublicationFixture(account: "other@localhost"))
        let before = try await existing.encryptionState(accountID: "other@localhost")
        let key = try PreUpgradeSnapshot.keychainData(service: target.locations.encryptionService, account: "primary")

        let staged = try target.transfer.stage(archive: source.transfer.archive(of: moved), code: code)
        try await existing.acquireTransportOwnership()
        let blocker = try await target.transfer.importBlocker(store: existing)
        XCTAssertEqual(blocker, .identityExists)
        do {
            try await target.transfer.commit(staged, store: existing, now: now)
            XCTFail("restored over an identity")
        } catch { XCTAssertEqual(error as? AccountTransfer.Failure, .identityExists) }
        let stillLeased = await existing.holdsTransportOwnership
        XCTAssertTrue(stillLeased, "refused before the store was touched")
        let after = try await existing.encryptionState(accountID: "other@localhost")
        XCTAssertEqual(after, before)
        let imported = try await existing.encryptionState(accountID: account)
        XCTAssertNil(imported)
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: target.locations.encryptionService, account: "primary"), key)
        XCTAssertNil(try PreUpgradeSnapshot.keychainData(service: target.keychain.accountService, account: "primary"))
    }

    /// A restore that fails after the store was swapped in puts everything back: the target's own data, Keychain and
    /// preferences, with no journal left. The same file then restores.
    func testARestoreThatFailsPartWayPutsTheTargetBack() async throws {
        let source = try makeInstall(), target = try makeInstall()
        let signed = try await signedIn(source)
        let code = TransferCode.generate()
        let moved = try await export(source, store: signed.store, code: code)

        // The target shows the sample conversations, which a restore may replace.
        let samples = try target.openStore()
        try await samples.upsertChat(accountID: DemoSamples.account, chatID: "alex@preview.local", title: "Alex")
        target.appDefaults.set(DemoSamples.account, forKey: "lastAccount")
        let leftover = randomKey()
        try PreUpgradeSnapshot.keychainSet(service: target.locations.encryptionService, account: target.locations.storageID, data: leftover)

        var failing = target.transfer
        let pushService = target.keychain.pushService
        failing.secrets.set = { service, account, data in
            // The last Keychain write fails, after the store and the other records are in place.
            guard service != pushService else { throw AccountTransfer.Failure.keychain }
            try PreUpgradeSnapshot.keychainSet(service: service, account: account, data: data)
        }
        let staged = try failing.stage(archive: source.transfer.archive(of: moved), code: code)
        try await samples.acquireTransportOwnership()
        do {
            try await failing.commit(staged, store: samples, now: now)
            XCTFail("the failing write went through")
        } catch { XCTAssertEqual(error as? AccountTransfer.Failure, .keychain) }

        let reopened = try target.openStore()
        let sampleChats = try await reopened.chats(accountID: DemoSamples.account).map(\.id)
        XCTAssertEqual(sampleChats, ["alex@preview.local"])
        let accounts = try await reopened.storedAccountIDs()
        XCTAssertEqual(accounts, [DemoSamples.account])
        XCTAssertEqual(try PreUpgradeSnapshot.keychainData(service: target.locations.encryptionService, account: "primary"), leftover)
        XCTAssertNil(try PreUpgradeSnapshot.keychainData(service: target.keychain.accountService, account: "primary"))
        XCTAssertEqual(target.appDefaults.string(forKey: "lastAccount"), DemoSamples.account)
        for leftover in [target.locations.importJournal, target.locations.importPrevious, target.locations.incoming] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), leftover.lastPathComponent)
        }

        try await reopened.acquireTransportOwnership()
        try await target.transfer.commit(try target.transfer.stage(archive: source.transfer.archive(of: moved), code: code), store: reopened, now: now)
        let restored = try target.openStore()
        let device = try await target.encryption(restored).overview(account: account, peer: peer).localDeviceID
        XCTAssertEqual(device, signed.overview.localDeviceID)
    }

    /// The source's way back. An export a crash interrupted (marker still exporting) is undone at the next launch;
    /// "Use Here Again" after a finished one puts the store back as it was. Either way the archive is gone and the
    /// identity is the same.
    func testTheSourceGetsItsDataBackAfterAnInterruptedExportOrUseHereAgain() async throws {
        let source = try makeInstall()
        let signed = try await signedIn(source)
        var moved = try await export(source, store: signed.store, code: .generate())
        // As a crash just before the final marker write leaves it.
        moved.stage = .exporting
        try JSONEncoder().encode(moved).write(to: source.locations.marker)
        XCTAssertNil(try source.transfer.recover())
        XCTAssertFalse(TransferHold.isMoved(groupRoot: source.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.locations.outgoing.path))
        let back = try source.openStore()
        let fingerprint = try await source.encryption(back).overview(account: account, peer: peer).localFingerprint
        XCTAssertEqual(fingerprint, signed.overview.localFingerprint)

        let again = try await export(source, store: back, code: .generate())
        try source.transfer.rollBackExport()
        XCTAssertNil(try source.transfer.recover())
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.transfer.archive(of: again).path))
        let resumed = try source.openStore()
        let resumedBodies = try await resumed.messages(accountID: account, chatID: peer).map(\.body)
        XCTAssertEqual(resumedBodies, signed.messages.map(\.body))
        let resumedDevice = try await source.encryption(resumed).overview(account: account, peer: peer).localDeviceID
        XCTAssertEqual(resumedDevice, signed.overview.localDeviceID)
    }

    /// A marker that is there but does not read (before the first unlock, or damaged) keeps storage closed: counting
    /// it as absent would let a launch create a new store, and a new identity, while the real one is held.
    func testAnUnreadableMarkerKeepsStorageClosed() async throws {
        let source = try makeInstall()
        let signed = try await signedIn(source)
        _ = try await export(source, store: signed.store, code: .generate())
        try Data("{".utf8).write(to: source.locations.marker)
        XCTAssertThrowsError(try source.transfer.recover()) { XCTAssertEqual($0 as? AccountTransfer.Failure, .markerUnreadable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.locations.held.path), "the held data stays where it is")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.locations.install.database.path))
    }

    /// The owner's update in place, from a build that predates transfers: `Messaging/`, the Keychain records and the
    /// preferences are there, but no `Transfer/` folder and no transfer Keychain item. The launch's transfer step
    /// changes and creates nothing, and the saved account counts as this install's, whether that build remembered the
    /// selected account or not.
    func testAnUpdateFromABuildBeforeTransfersKeepsItsDataAndAccount() async throws {
        let install = try makeInstall()
        let signed = try await signedIn(install)
        try await signed.store.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.locations.directory.path))

        XCTAssertNil(try install.transfer.recover())
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.locations.directory.path), "nothing created for transfers")
        XCTAssertFalse(TransferHold.isMoved(groupRoot: install.root))

        let store = try install.openStore()
        let bodies = try await store.messages(accountID: account, chatID: peer).map(\.body)
        XCTAssertEqual(bodies, signed.messages.map(\.body))
        let device = try await install.encryption(store).overview(account: account, peer: peer).localDeviceID
        XCTAssertEqual(device, signed.overview.localDeviceID)
        let record = try AccountTransfer.decodeAccount(XCTUnwrap(try PreUpgradeSnapshot.keychainData(service: install.keychain.accountService, account: "primary")))
        let last = try XCTUnwrap(install.appDefaults.string(forKey: "lastAccount"))
        var owned = try await AppModel.ownsSavedAccount(record, lastAccount: last, store: store)
        XCTAssertTrue(owned, "the selected account")
        owned = try await AppModel.ownsSavedAccount(record, lastAccount: "", store: store)
        XCTAssertTrue(owned, "no selection remembered: the store holds the account's identity")
    }

    /// A reinstall: the Keychain kept the deleted install's account record, but this install never selected it and
    /// its store holds no identity for it, so the app starts signed out.
    func testARecordADeletedInstallLeftBehindIsNotThisInstalls() async throws {
        let install = try makeInstall()
        let store = try install.openStore()
        let record = NotificationAccount(accountID: account, host: "localhost", port: 5223, domain: "localhost", username: "ellie",
                                         password: "synthetic-password", push: nil)
        var owned = try await AppModel.ownsSavedAccount(record, lastAccount: "", store: store)
        XCTAssertFalse(owned)
        owned = try await AppModel.ownsSavedAccount(record, lastAccount: "other@localhost", store: store)
        XCTAssertFalse(owned)
    }
}
