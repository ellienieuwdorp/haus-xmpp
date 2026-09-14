import XCTest
import Foundation
import MessageStore
import OMEMO
import XMPPProtocol
@testable import XMPPiOS

@MainActor final class SharedStorageTests: XCTestCase {
    func testMigrationPreservesProtectedIdentityAndMessages() async throws {
        let fixture = try MigrationFixture()
        addTeardownBlock { try await fixture.remove() }
        let store = try fixture.open(fixture.legacy)
        let key = Data(repeating: 37, count: 32)
        let service = OMEMOService(store: store, protection: try StateProtection(key: key))
        try await service.initialize(account: fixture.account, transport: MigrationPublicationFixture())
        let identity = try await service.overview(account: fixture.account, peer: fixture.account)
        let snapshot = try await store.encryptionState(accountID: fixture.account)
        try await store.upsertChat(accountID: fixture.account, chatID: "peer@localhost", title: "Synthetic peer")
        try await store.insertMessage(StoredMessage(id: "migration-message", accountID: fixture.account,
            chatID: "peer@localhost", senderID: "peer@localhost", body: "Synthetic preserved message"))
        try await store.close()

        let migrated = try await SharedStorage.resolve(legacy: fixture.legacy, destination: fixture.destination, migrate: true)
        XCTAssertEqual(migrated, fixture.destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacy.path))
        let reopened = try fixture.open(migrated)
        let restoredSnapshot = try await reopened.encryptionState(accountID: fixture.account)
        XCTAssertEqual(snapshot, restoredSnapshot)
        let restoredService = OMEMOService(store: reopened, protection: try StateProtection(key: key))
        let restored = try await restoredService.overview(account: fixture.account, peer: fixture.account)
        XCTAssertEqual(identity.localDeviceID, restored.localDeviceID)
        XCTAssertEqual(identity.localFingerprint, restored.localFingerprint)
        let messages = try await reopened.messages(accountID: fixture.account, chatID: "peer@localhost")
        XCTAssertEqual(messages.map(\.body), ["Synthetic preserved message"])
        XCTAssertTrue(try migrated.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try await reopened.acquireTransportOwnership()
        try await reopened.releaseTransportOwnership()
        let repeated = try await SharedStorage.resolve(legacy: fixture.legacy, destination: fixture.destination, migrate: true)
        XCTAssertEqual(repeated, migrated)
    }

    func testConflictingStoresFailWithoutChoosingOrDeletingEitherIdentity() async throws {
        let fixture = try MigrationFixture()
        addTeardownBlock { try await fixture.remove() }
        let old = try fixture.open(fixture.legacy)
        let current = try fixture.open(fixture.destination)
        try await old.saveEncryptionState(accountID: fixture.account, expectedRevision: nil, data: Data([1, 2, 3]))
        try await current.saveEncryptionState(accountID: fixture.account, expectedRevision: nil, data: Data([4, 5, 6]))
        try await old.close()
        try await current.close()
        do {
            _ = try await SharedStorage.resolve(legacy: fixture.legacy, destination: fixture.destination, migrate: true)
            XCTFail("Conflicting stores must require an explicit recovery decision")
        } catch { XCTAssertEqual(error as? SharedStorage.Failure, .conflictingStores) }
        let oldAgain = try fixture.open(fixture.legacy)
        let newAgain = try fixture.open(fixture.destination)
        let oldState = try await oldAgain.encryptionState(accountID: fixture.account)
        let newState = try await newAgain.encryptionState(accountID: fixture.account)
        XCTAssertEqual(oldState?.data, Data([1, 2, 3]))
        XCTAssertEqual(newState?.data, Data([4, 5, 6]))
    }

    func testBusyLegacyStoreCannotMoveAndExtensionCannotCreateFreshStore() async throws {
        let fixture = try MigrationFixture()
        addTeardownBlock { try await fixture.remove() }
        let old = try fixture.open(fixture.legacy)
        try await old.acquireTransportOwnership()
        do {
            _ = try await SharedStorage.resolve(legacy: fixture.legacy, destination: fixture.destination, migrate: true)
            XCTFail("A live owner must prevent migration")
        } catch { XCTAssertEqual(error as? MessageStoreError, .transportOwnedElsewhere) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacy.appending(path: "messages.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        do {
            _ = try await SharedStorage.resolve(legacy: fixture.legacy, destination: fixture.destination, migrate: false)
            XCTFail("An extension must never initialize or migrate absent app storage")
        } catch { XCTAssertEqual(error as? SharedStorage.Failure, .unavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
}

@MainActor private final class MigrationFixture {
    let account = "migration@localhost"
    let root: URL
    var legacy: URL { root.appending(path: "private-Messaging") }
    var destination: URL { root.appending(path: "shared-Messaging") }
    private var stores: [MessageStore] = []
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "storage-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func open(_ directory: URL) throws -> MessageStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        stores.append(store)
        return store
    }
    func remove() async throws {
        for store in stores { try await store.close() }
        stores.removeAll()
        try FileManager.default.removeItem(at: root)
    }
}

private actor MigrationPublicationFixture: OMEMOTransport {
    private var lists: [XMPPOMEMOProfile: [UInt32]] = [:]
    private var bundles: [XMPPOMEMOProfile: XMPPOMEMOBundle] = [:]
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) -> [UInt32] { lists[profile] ?? [] }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) throws -> XMPPOMEMOBundle {
        guard let bundle = bundles[profile], bundle.deviceID == deviceID else { throw OMEMOError.noDevices }
        return bundle
    }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) { lists[profile] = devices }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) { bundles[bundle.profile] = bundle }
}
