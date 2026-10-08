import XCTest
import Security
import MessageStore
import XMPPProtocol
import OMEMO
@testable import HausXMPP

/// Detection and the start-over flow below the screen (docs/development/key-recovery.md). Each test uses its own
/// `lifecycle-key-<uuid>` Keychain item and store and deletes only those; no real Keychain item is touched.
@MainActor final class KeyRecoveryTests: XCTestCase {
    private let account = "recovery@localhost"

    private func makeStore() throws -> (MessageStore, URL, String) {
        let id = "lifecycle-key-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        addTeardownBlock {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
            _ = SecItemDelete(Self.keyQuery(id) as CFDictionary)
        }
        return (store, directory, id)
    }

    private nonisolated static func keyQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "haus.xmpp.encryption-state",
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }

    private func ready(_ access: KeyRecovery.Access, file: StaticString = #filePath, line: UInt = #line) throws -> OMEMOService {
        guard case .ready(let service) = access else { XCTFail("Expected readable state", file: file, line: line); throw CancellationError() }
        return service
    }

    private func plan(_ access: KeyRecovery.Access, file: StaticString = #filePath, line: UInt = #line) throws -> KeyRecoveryPlan {
        guard case .needed(let plan) = access else { XCTFail("Expected the recovery screen", file: file, line: line); throw CancellationError() }
        return plan
    }

    func testMissingKeyWithStateShowsRecoveryAndCreatesNothing() async throws {
        let (store, _, id) = try makeStore()
        let server = RecoveryServer()
        // An empty database creates its key, and its first connection its identity.
        let service = try ready(try await KeyRecovery.open(store: store, storageID: id, account: account))
        try await store.acquireTransportOwnership()
        try await service.initialize(account: account, transport: RecoveryTransport(account: account, server: server))
        let oldID = try await service.overview(account: account, peer: account).localDeviceID
        let sealed = try await store.encryptionState(accountID: account)
        XCTAssertEqual(sealed?.deviceID, oldID)

        XCTAssertEqual(SecItemDelete(Self.keyQuery(id) as CFDictionary), errSecSuccess)
        let plan = try plan(try await KeyRecovery.open(store: store, storageID: id, account: account))
        XCTAssertTrue(plan.keyMissing)
        XCTAssertEqual(plan.states.map(\.accountID), [account])
        XCTAssertEqual(plan.current?.deviceID, oldID)
        XCTAssertTrue(plan.retiresOldDevices)
        XCTAssertEqual(plan.otherAccounts, 0)
        // Detection alone creates no key and changes no state.
        XCTAssertEqual(SecItemCopyMatching(Self.keyQuery(id) as CFDictionary, nil), errSecItemNotFound)
        let after = try await store.encryptionState(accountID: account)
        XCTAssertEqual(after, sealed)
    }

    /// Any other Keychain failure is not key loss: storage fails to open as before, and no recovery is offered.
    func testAnUnreadableKeyItemFailsClosedWithoutOfferingRecovery() async throws {
        let (store, _, id) = try makeStore()
        try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
        var item = Self.keyQuery(id)
        item[kSecValueData as String] = Data(repeating: 7, count: 16) // not a 32-byte key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        do {
            _ = try await KeyRecovery.open(store: store, storageID: id, account: account)
            XCTFail("An unreadable key must not lead to recovery")
        } catch { XCTAssertEqual(error as? EncryptionKeychain.Failure, .unavailable) }
        let state = try await store.encryptionState(accountID: account)
        XCTAssertEqual(state?.data, Data([1]))
    }

    func testStartingOverNeedsTheLeaseThenPublishesANewDeviceAndRetiresTheOldOne() async throws {
        let (store, _, id) = try makeStore()
        let server = RecoveryServer()
        let transport = RecoveryTransport(account: account, server: server)
        let first = try ready(try await KeyRecovery.open(store: store, storageID: id, account: account))
        try await store.acquireTransportOwnership()
        try await first.initialize(account: account, transport: transport)
        let oldID = try await first.overview(account: account, peer: account).localDeviceID
        try await store.releaseTransportOwnership()
        XCTAssertEqual(SecItemDelete(Self.keyQuery(id) as CFDictionary), errSecSuccess)
        let plan = try plan(try await KeyRecovery.open(store: store, storageID: id, account: account))

        // Without the lease nothing happens, not even the new key.
        do { _ = try await KeyRecovery.startOver(plan, store: store, storageID: id); XCTFail("The lease is required") }
        catch { XCTAssertEqual(error as? MessageStoreError, .transportOwnershipRequired) }
        XCTAssertEqual(SecItemCopyMatching(Self.keyQuery(id) as CFDictionary, nil), errSecItemNotFound)

        try await store.acquireTransportOwnership()
        let started = try await KeyRecovery.startOver(plan, store: store, storageID: id)
        let newID = try XCTUnwrap(started)
        XCTAssertNotEqual(newID, oldID)
        // A second confirmation (a stale screen) cannot discard the new identity.
        do { _ = try await KeyRecovery.startOver(plan, store: store, storageID: id); XCTFail("Already started over") }
        catch { XCTAssertEqual(error as? OMEMOError, .concurrentChange) }
        try await store.releaseTransportOwnership()

        // Storage opens normally now, and the first connection publishes the new device and drops the old one.
        let reopened = try ready(try await KeyRecovery.open(store: store, storageID: id, account: account))
        try await store.acquireTransportOwnership()
        try await reopened.initialize(account: account, transport: transport)
        for profile in XMPPOMEMOProfile.allCases {
            let listed = await server.devices(account, profile)
            XCTAssertEqual(listed, [newID], "\(profile)")
        }
        let overview = try await reopened.overview(account: account, peer: account)
        XCTAssertEqual(overview.localDeviceID, newID)
    }
}

private actor RecoveryServer {
    private var lists: [String: [UInt32]] = [:]
    private var bundles: [String: XMPPOMEMOBundle] = [:]
    func devices(_ jid: String, _ profile: XMPPOMEMOProfile) -> [UInt32] { lists[jid + profile.rawValue] ?? [] }
    func bundle(_ jid: String, _ profile: XMPPOMEMOProfile, _ id: UInt32) throws -> XMPPOMEMOBundle {
        guard let value = bundles[jid + profile.rawValue + String(id)] else { throw XMPPIQError.stanza(condition: "item-not-found") }
        return value
    }
    func publish(_ jid: String, _ ids: [UInt32], _ profile: XMPPOMEMOProfile) { lists[jid + profile.rawValue] = ids }
    func publish(_ jid: String, _ bundle: XMPPOMEMOBundle) { bundles[jid + bundle.profile.rawValue + String(bundle.deviceID)] = bundle }
}

private struct RecoveryTransport: OMEMOTransport {
    let account: String
    let server: RecoveryServer
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async -> [UInt32] { await server.devices(jid, profile) }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        try await server.bundle(jid, profile, deviceID)
    }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async { await server.publish(account, devices, profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async { await server.publish(account, bundle) }
}
