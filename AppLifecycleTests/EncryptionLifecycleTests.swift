import XCTest
import UIKit
import Security
import MessageStore
import XMPPProtocol
import OMEMO
@testable import HausXMPP

/// Synthetic accounts/keys only. No network, real-account state or private lock API.
@MainActor final class EncryptionLifecycleTests: XCTestCase {
    func testKeychainUsesDeviceLocalAfterFirstUnlockProtection() throws {
        let id = "lifecycle-" + UUID().uuidString
        defer { deleteKey(id) }
        let key = try EncryptionKeychain.load(storageID: id, allowCreation: true)
        XCTAssertEqual(key.count, 32)
        let reloaded = try EncryptionKeychain.load(storageID: id, allowCreation: false)
        XCTAssertTrue(key == reloaded, "Reload must preserve wrapping key bytes")
        var query = keyQuery(id)
        query[kSecReturnAttributes as String] = true
        var value: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &value), errSecSuccess)
        let attributes = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertFalse(attributes[kSecAttrSynchronizable as String] as? Bool ?? false)
    }

    /// Wrapping keys saved before every query named the data protection keychain must still be found, never replaced.
    /// The flag is a no-op on iOS, so this guards the service, account and synchronizable value the shared query uses;
    /// whether the app and extension share items on macOS needs a Mac test target.
    func testWrappingKeySavedWithoutDataProtectionFlagIsStillFound() throws {
        let id = "lifecycle-" + UUID().uuidString
        defer { deleteKey(id) }
        let saved = Data((0..<32).map { UInt8($0) })
        var item = keyQuery(id)
        item[kSecValueData as String] = saved
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(try EncryptionKeychain.load(storageID: id, allowCreation: true), saved)
    }

    func testProtectedSnapshotAndIdentitySurviveStoreReopen() async throws {
        let fixture = try Fixture()
        addTeardownBlock { try await fixture.remove() }
        let first = try await fixture.initializeIdentity()
        let identity = try await first.service.overview(account: fixture.account, peer: fixture.account)
        let before = try await first.store.encryptionState(accountID: fixture.account)
        XCTAssertNotNil(before)
        XCTAssertTrue(try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let reopened = try fixture.openStore()
        let protectedKey = try EncryptionKeychain.load(storageID: fixture.id, allowCreation: false)
        let service = OMEMOService(store: reopened, protection: try StateProtection(key: protectedKey))
        let restored = try await service.overview(account: fixture.account, peer: fixture.account)
        XCTAssertEqual(restored.localDeviceID, identity.localDeviceID)
        XCTAssertTrue(restored.localFingerprint == identity.localFingerprint, "Reopen must preserve identity")
        let after = try await reopened.encryptionState(accountID: fixture.account)
        XCTAssertTrue(before == after, "Read-only reopen must preserve the protected snapshot exactly")
    }

    func testFileProtectionMetadataOnPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator filesystem does not implement physical iOS Data Protection attributes")
        #else
        let fixture = try Fixture()
        addTeardownBlock { try await fixture.remove() }
        let initialized = try await fixture.initializeIdentity()
        _ = try await initialized.store.encryptionState(accountID: fixture.account)
        for name in ["", "messages.sqlite", "messages.sqlite-wal", "messages.sqlite-shm", "messages.sqlite.transport-lock"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.appending(path: name).path)
            let actual = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? attributes[.protectionKey] as? String
            XCTAssertEqual(actual, FileProtectionType.completeUntilFirstUserAuthentication.rawValue, name)
        }
        XCTAssertTrue(try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let stillOpen = try await initialized.store.encryptionState(accountID: fixture.account)
        XCTAssertNotNil(stillOpen) // Keep the SQLite connection alive while inspecting its sidecars.
        #endif
    }

    func testMissingWrappingKeyFailsClosedWithoutReplacingIdentity() async throws {
        let fixture = try Fixture()
        addTeardownBlock { try await fixture.remove() }
        let initialized = try await fixture.initializeIdentity()
        let before = try await initialized.store.encryptionState(accountID: fixture.account)
        deleteKey(fixture.id)
        let mayCreate = try await !initialized.store.hasAnyEncryptionState()
        XCTAssertFalse(mayCreate)
        XCTAssertThrowsError(try EncryptionKeychain.load(storageID: fixture.id, allowCreation: mayCreate))
        var query = keyQuery(fixture.id)
        query[kSecReturnData as String] = true
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        let after = try await initialized.store.encryptionState(accountID: fixture.account)
        XCTAssertTrue(before == after, "Missing wrapping key must never replace stored device identity")
    }

    /// Run twice in separate test-host launches with the same explicit UUID: phase seed, then verify.
    /// Uses actual Keychain retrieval and existing encrypted snapshot, never in-memory test carryover.
    func testIdentityAcrossSeparateProcessLaunches() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["XMPP_LIFECYCLE_RUN_ID"], UUID(uuidString: value) != nil,
              let phase = env["XMPP_LIFECYCLE_PHASE"], ["seed", "verify"].contains(phase) else {
            throw XCTSkip("Set XMPP_LIFECYCLE_RUN_ID to a UUID and phase seed/verify for two separate test-host launches")
        }
        let fixture = try Fixture(id: "lifecycle-relaunch-" + value)
        addTeardownBlock { try await fixture.closeStores() }
        let manifestURL = fixture.directory.appending(path: "identity-manifest.json")
        if phase == "seed" {
            guard !FileManager.default.fileExists(atPath: manifestURL.path) else { throw FixtureError.existingFixture }
            let initialized = try await fixture.initializeIdentity()
            let overview = try await initialized.service.overview(account: fixture.account, peer: fixture.account)
            let manifest = IdentityManifest(deviceID: overview.localDeviceID, fingerprint: overview.localFingerprint,
                                            processID: ProcessInfo.processInfo.processIdentifier)
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            attachMarker("RELAUNCH_SEED_COMPLETE")
        } else {
            addTeardownBlock { try await fixture.remove() }
            let manifest = try JSONDecoder().decode(IdentityManifest.self, from: Data(contentsOf: manifestURL))
            XCTAssertNotEqual(manifest.processID, ProcessInfo.processInfo.processIdentifier, "Verify requires a new test-host process")
            let store = try fixture.openStore()
            let hasState = try await store.hasAnyEncryptionState()
            XCTAssertTrue(hasState)
            let key = try EncryptionKeychain.load(storageID: fixture.id, allowCreation: false)
            let service = OMEMOService(store: store, protection: try StateProtection(key: key))
            let overview = try await service.overview(account: fixture.account, peer: fixture.account)
            XCTAssertEqual(overview.localDeviceID, manifest.deviceID)
            XCTAssertTrue(overview.localFingerprint == manifest.fingerprint, "Identity must survive actual process relaunch")
            attachMarker("RELAUNCH_VERIFICATION_COMPLETE")
        }
    }

    func testPreparedIncomingPacketsCommitUsingOnlyPersistentIdentity() async throws {
        let recipient = try Fixture()
        let sender = try Fixture(account: "sender-lifecycle@localhost")
        addTeardownBlock { try await recipient.remove(); try await sender.remove() }
        let prepared = try await prepareIncomingPackets(recipient: recipient, sender: sender)
        try await verifyIncomingPackets(prepared.packets, recipient: recipient, sender: sender,
                                        baseline: prepared.baseline)
    }

    /// Opt-in, attended physical-device test. Requires passcode and immediate lock policy.
    /// Protected-data false PLUS a newly unreadable complete-protection sentinel proves lock.
    func testLockedDeviceCanReadAfterFirstUnlockEncryptionState() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator cannot establish physical Data Protection behavior")
        #else
        guard ProcessInfo.processInfo.environment["XMPP_LIFECYCLE_MANUAL_LOCK"] == "1" else {
            throw XCTSkip("Set XMPP_LIFECYCLE_MANUAL_LOCK=1 for an attended physical-device lock test")
        }
        guard UIApplication.shared.isProtectedDataAvailable else {
            XCTFail("Start unlocked after entering the device passcode")
            return
        }
        let fixture = try Fixture()
        addTeardownBlock { try await fixture.remove() }
        let sender = try Fixture(account: "sender-lifecycle@localhost")
        addTeardownBlock { try await sender.remove() }
        let prepared = try await prepareIncomingPackets(recipient: fixture, sender: sender)
        let sentinel = fixture.directory.appending(path: "complete-protection-sentinel")
        try Data([1, 2, 3]).write(to: sentinel, options: .completeFileProtection)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Encryption lifecycle lock probe", expirationHandler: nil)
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        guard background != .invalid else {
            XCTFail("Could not obtain bounded background time for the physical probe")
            return
        }
        attachMarker("LOCK_PROBE_ARMED: Lock the iPhone now; keep it locked until verification completes")
        let deadline = Date().addingTimeInterval(25)
        while UIApplication.shared.isProtectedDataAvailable && Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard !UIApplication.shared.isProtectedDataAvailable else {
            XCTFail("No physical protected-data-unavailable transition observed; lock behavior was NOT verified")
            return
        }
        do {
            _ = try Data(contentsOf: sentinel)
            XCTFail("Complete-protection sentinel was still readable; physical lock was NOT verified")
            return
        } catch { /* Expected: the complete-protection key is unavailable while locked. */ }
        try await verifyIncomingPackets(prepared.packets, recipient: fixture, sender: sender, baseline: prepared.baseline)
        guard !UIApplication.shared.isProtectedDataAvailable else {
            XCTFail("The device must remain locked throughout actual decryption and atomic persistence")
            return
        }
        attachMarker("LOCK_PROBE_VERIFIED: class-A sentinel unavailable; fresh Keychain/SQLite restored identity; legacy and modern OMEMO decrypted and committed while locked")
        #endif
    }

    private func prepareIncomingPackets(recipient: Fixture, sender: Fixture) async throws
        -> (packets: [XMPPEncryptedMessage], baseline: EncryptionOverview) {
        let server = LifecyclePublicationServer()
        let recipientTransport = LocalPublicationFixture(account: recipient.account, server: server)
        let senderTransport = LocalPublicationFixture(account: sender.account, server: server)
        let receiving = try await recipient.initializeIdentity(transport: recipientTransport)
        let sending = try await sender.initializeIdentity(transport: senderTransport)
        try await sending.store.upsertChat(accountID: sender.account, chatID: recipient.account, title: "Synthetic recipient")
        var packets: [XMPPEncryptedMessage] = []
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let recipients = try await sending.service.refreshDevices(account: sender.account, peer: recipient.account,
                                                                      profile: profile, transport: senderTransport)
            let senders = try await receiving.service.refreshDevices(account: recipient.account, peer: sender.account,
                                                                      profile: profile, transport: recipientTransport)
            // Automatic approval belongs exclusively to these generated, network-free test fixtures.
            for device in recipients.devices where device.active {
                try await sending.service.setTrust(account: sender.account, deviceID: device.id, trust: .accepted)
            }
            for device in senders.devices where device.active {
                try await receiving.service.setTrust(account: recipient.account, deviceID: device.id, trust: .accepted)
            }
            let messageID = UUID().uuidString
            try await sending.store.enqueueOutgoing(StoredMessage(id: messageID, accountID: sender.account,
                chatID: recipient.account, senderID: sender.account, body: "Synthetic locked " + profile.rawValue,
                isOutgoing: true, encryptionProfile: "pending"))
            try await sending.service.prepareQueuedMessages(account: sender.account, transport: senderTransport)
            let envelope = try await sending.service.outgoingEnvelope(account: sender.account, messageID: messageID)
            XCTAssertEqual(envelope.profile, profile)
            packets.append(XMPPEncryptedMessage(id: messageID, from: sender.account + "/fixture",
                                                 to: recipient.account, originID: messageID, envelope: envelope))
        }
        let baseline = try await receiving.service.overview(account: recipient.account, peer: sender.account)
        return (packets, baseline)
    }

    private func verifyIncomingPackets(_ packets: [XMPPEncryptedMessage], recipient: Fixture, sender: Fixture,
                                       baseline: EncryptionOverview) async throws {
        let key = try EncryptionKeychain.load(storageID: recipient.id, allowCreation: false)
        let store = try recipient.openStore()
        let savedBefore = try await store.encryptionState(accountID: recipient.account)
        let before = try XCTUnwrap(savedBefore)
        let service = OMEMOService(store: store, protection: try StateProtection(key: key))
        for packet in packets {
            let committed = try await service.receive(account: recipient.account, message: packet, transport: UnavailablePublicationFixture())
            guard committed else { throw FixtureError.missingCommit }
        }
        let messages = try await store.messages(accountID: recipient.account, chatID: sender.account)
        guard messages.count == 2,
              Set(messages.map(\.body)) == Set(["Synthetic locked legacy", "Synthetic locked modern"]),
              Set(messages.compactMap(\.encryptionProfile)) == Set(["legacy", "modern"]),
              try await store.pendingEncryptedIncoming(accountID: recipient.account).isEmpty else { throw FixtureError.missingCommit }
        let restored = try await service.overview(account: recipient.account, peer: sender.account)
        guard restored.localDeviceID == baseline.localDeviceID,
              restored.localFingerprint == baseline.localFingerprint else { throw FixtureError.identityChanged }
        let savedAfter = try await store.encryptionState(accountID: recipient.account)
        let after = try XCTUnwrap(savedAfter)
        guard after.revision > before.revision, after.data != before.data else { throw FixtureError.missingCommit }
        for packet in packets {
            guard try await !service.receive(account: recipient.account, message: packet, transport: UnavailablePublicationFixture()) else {
                throw FixtureError.duplicateCommit
            }
        }
        let afterReplay = try await store.encryptionState(accountID: recipient.account)
        guard afterReplay == after else { throw FixtureError.duplicateCommit }
    }

    private func attachMarker(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        print(text)
    }
}

private struct IdentityManifest: Codable { let deviceID: UInt32; let fingerprint: String; let processID: Int32 }
private enum FixtureError: Error { case existingFixture, missingCommit, identityChanged, duplicateCommit }

@MainActor private final class Fixture {
    private var stores: [MessageStore] = []
    let id: String
    let account: String
    let directory: URL
    var database: URL { directory.appending(path: "messages.sqlite") }
    init(id: String = "lifecycle-" + UUID().uuidString, account: String = "lifecycle@localhost") throws {
        self.id = id
        self.account = account
        var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Messaging/LifecycleTests/" + id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        directory = root
    }
    func initializeIdentity(transport: (any OMEMOTransport)? = nil) async throws -> (store: MessageStore, service: OMEMOService) {
        let store = try openStore()
        let mayCreate = try await !store.hasAnyEncryptionState()
        let key = try EncryptionKeychain.load(storageID: id, allowCreation: mayCreate)
        let service = OMEMOService(store: store, protection: try StateProtection(key: key))
        try await service.initialize(account: account, transport: transport ?? LocalPublicationFixture(account: account))
        return (store, service)
    }
    func openStore() throws -> MessageStore {
        let store = try MessageStore(url: database)
        stores.append(store)
        return store
    }
    func closeStores() async throws {
        for store in stores { try await store.close() }
        stores.removeAll()
    }
    func remove() async throws {
        try await closeStores()
        try FileManager.default.removeItem(at: directory)
        deleteKey(id)
    }
}

private func keyQuery(_ id: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "haus.xmpp.encryption-state",
     kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
}
private func deleteKey(_ id: String) { _ = SecItemDelete(keyQuery(id) as CFDictionary) }

actor LifecyclePublicationServer {
    private var lists: [String: [UInt32]] = [:]
    private var bundles: [String: XMPPOMEMOBundle] = [:]
    func devices(_ account: String, _ profile: XMPPOMEMOProfile) -> [UInt32] { lists[account + profile.rawValue] ?? [] }
    func bundle(_ account: String, _ profile: XMPPOMEMOProfile, _ id: UInt32) throws -> XMPPOMEMOBundle {
        guard let value = bundles[account + profile.rawValue + String(id)] else { throw OMEMOError.noDevices }
        return value
    }
    func publish(_ account: String, _ ids: [UInt32], _ profile: XMPPOMEMOProfile) { lists[account + profile.rawValue] = ids }
    func publish(_ account: String, _ bundle: XMPPOMEMOBundle) { bundles[account + bundle.profile.rawValue + String(bundle.deviceID)] = bundle }
}

struct LocalPublicationFixture: OMEMOTransport {
    let account: String
    var server = LifecyclePublicationServer()
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async -> [UInt32] { await server.devices(jid, profile) }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        try await server.bundle(jid, profile, deviceID)
    }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async { await server.publish(account, devices, profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async { await server.publish(account, bundle) }
}

private struct UnavailablePublicationFixture: OMEMOTransport {
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) throws -> [UInt32] { throw OMEMOError.unavailable }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) throws -> XMPPOMEMOBundle { throw OMEMOError.unavailable }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) throws { throw OMEMOError.unavailable }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) throws { throw OMEMOError.unavailable }
}
