import Foundation
import XCTest
import SQLite3
import MessageStore
import XMPPProtocol
import OMEMOCrypto
@testable import OMEMO

private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
private func expectTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a, file: file, line: line) }
private func expectNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(a, file: file, line: line) }
/// Another client's freshly generated bundle.
private func otherClientBundle(_ profile: XMPPOMEMOProfile, deviceID: UInt32) throws -> XMPPOMEMOBundle {
    let bundle = try OMEMOEngine(profile: profile == .legacy ? .legacy : .modern, deviceID: deviceID).bundle()
    return XMPPOMEMOBundle(profile: profile, deviceID: bundle.deviceID, identityKey: bundle.identityKey, signedPreKeyID: bundle.signedPreKeyID,
                           signedPreKey: bundle.signedPreKey, signedPreKeySignature: bundle.signedPreKeySignature, preKeys: bundle.preKeys)
}

/// Writes back `putBack` after every device-list publication, as another client with a stale read-modify-write would.
private struct StaleListTransport: OMEMOTransport {
    let base: TestTransport
    let putBack: UInt32
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] { try await base.fetchOMEMODevices(for: jid, profile: profile) }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle { try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile) }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws {
        try await base.publishOMEMODevices((devices + [putBack]).sorted(), profile: profile)
    }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { try await base.publishOMEMOBundle(bundle) }
}

/// Starting encryption over after the wrapping key was lost (docs/development/key-recovery.md): Bob's store keeps its
/// sealed state, but his device only has a different key now.
@MainActor
final class KeyRecoveryServiceTests: XCTestCase {
    private let replacementKey = Data(repeating: 0x55, count: 32)

    /// Alice, untrusted on Bob's side, sends him one message: Bob retains its ciphertext waiting for a decision.
    private func retainOneMessageForBob(_ f: ServiceFixture) async throws -> UInt32 {
        try await f.initialize(.modern, trust: false)
        for device in try await f.a.overview(account: f.alice, peer: f.bob).devices where device.active {
            try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
        }
        let message = try await f.queue("Waiting for Bob")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: message.id)
        do { _ = try await f.b.receive(account: f.bob, message: f.message(envelope, fallbackBody: true), transport: f.bTransport); XCTFail("Trust undecided") }
        catch { XCTAssertEqual(error as? OMEMOError, .trustRequired) }
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).count, 1)
        return try await f.b.overview(account: f.bob, peer: f.alice).localDeviceID
    }

    func testStartOverCreatesANewDeviceAndRetiresTheOldOneFromBothLists() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let oldID = try await retainOneMessageForBob(f)
        let oldFingerprint = try await f.b.overview(account: f.bob, peer: f.alice).localFingerprint
        // Initialize recorded the ID in plain text.
        expectEqual(try await f.bStore.encryptionState(accountID: f.bob)?.deviceID, oldID)
        for profile in XMPPOMEMOProfile.allCases {
            let listed = await f.server.devices(f.bob, profile)
            XCTAssertTrue(listed.contains(oldID))
        }
        let sealed = try await f.bStore.encryptionState(accountID: f.bob)

        let protection = try StateProtection(key: replacementKey)
        let lost = try await OMEMOService.unreadableStates(store: f.bStore, protection: protection)
        XCTAssertEqual(lost, [UnreadableEncryptionState(accountID: f.bob, revision: try XCTUnwrap(sealed).revision, deviceID: oldID,
                                                        loss: EncryptionLossCounts(waitingMessages: 1, unsendableFiles: 0))])
        let missingKey = try await OMEMOService.unreadableStates(store: f.bStore, protection: nil)
        XCTAssertEqual(missingKey, lost)
        let readable = try await OMEMOService.unreadableStates(store: f.bStore, protection: f.protection)
        XCTAssertEqual(readable, [])

        // No identity is created or replaced without the explicit call...
        let recovered = OMEMOService(store: f.bStore, protection: protection)
        do { try await recovered.initialize(account: f.bob, transport: f.bTransport); XCTFail("The old state cannot be opened") }
        catch { XCTAssertEqual(error as? OMEMOError, .stateUnavailable) }
        // ...and the explicit call refuses state its key can still read.
        do { try await f.b.startOver(account: f.bob, discarding: lost); XCTFail("Readable state is never discarded") }
        catch { XCTAssertEqual(error as? OMEMOError, .stateReadable) }
        let unchanged = try await f.bStore.encryptionState(accountID: f.bob)
        XCTAssertEqual(unchanged, sealed)

        let started = try await recovered.startOver(account: f.bob, discarding: lost)
        let newID = try XCTUnwrap(started)
        XCTAssertNotEqual(newID, oldID)
        expectEqual(try await f.bStore.encryptionState(accountID: f.bob)?.deviceID, newID)
        expectEqual(try await f.bStore.retiredOwnDevices(accountID: f.bob), [oldID])
        // The message encrypted for the old device is a quiet placeholder now; nothing waits any more.
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        let placeholders = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        XCTAssertEqual(placeholders.map(\.unreadableReason), [.encryptionReset])
        XCTAssertEqual(placeholders.first?.senderID, f.alice)
        // Nothing is published until the next connection.
        for profile in XMPPOMEMOProfile.allCases {
            let listed = await f.server.devices(f.bob, profile)
            XCTAssertFalse(listed.contains(newID))
        }

        try await recovered.initialize(account: f.bob, transport: f.bTransport)
        for profile in XMPPOMEMOProfile.allCases {
            let listed = await f.server.devices(f.bob, profile)
            XCTAssertTrue(listed.contains(newID), "\(profile) lists the new device")
            XCTAssertFalse(listed.contains(oldID), "\(profile) no longer lists the dead device")
            expectEqual(try await f.server.bundle(f.bob, newID, profile).deviceID, newID)
        }
        // Kept for good: the dead ID is never taken again and is removed whenever a list names it again.
        expectEqual(try await f.bStore.retiredOwnDevices(accountID: f.bob), [oldID])
        let overview = try await recovered.overview(account: f.bob, peer: f.alice)
        XCTAssertEqual(overview.localDeviceID, newID)
        XCTAssertNotEqual(overview.localFingerprint, oldFingerprint)
        // Alice sees a new device of Bob's to review, and nothing under the old ID.
        let aliceView = try await f.a.refreshDevices(account: f.alice, peer: f.bob, profile: .modern, transport: f.aTransport)
        XCTAssertEqual(aliceView.devices.filter { $0.jid == f.bob && $0.active }.map(\.deviceID), [newID])
        XCTAssertEqual(aliceView.devices.first { $0.jid == f.bob && $0.deviceID == newID }?.trust, .undecided)
    }

    /// The old ID stays listed while the removal has not reached the server: the dead device is never offered for review.
    func testARetiredDeviceStillListedIsSkippedByRefresh() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let oldID = try await retainOneMessageForBob(f)
        let protection = try StateProtection(key: replacementKey)
        let recovered = OMEMOService(store: f.bStore, protection: protection)
        let lost = try await OMEMOService.unreadableStates(store: f.bStore, protection: protection)
        let started = try await recovered.startOver(account: f.bob, discarding: lost)
        let newID = try XCTUnwrap(started)
        // Another of Bob's clients is listed beside the dead device.
        await f.server.publish(f.bob, [oldID, 4242], .modern)
        await f.server.publish(f.bob, try otherClientBundle(.modern, deviceID: 4242))
        let overview = try await recovered.refreshDevices(account: f.bob, peer: f.alice, profile: .modern, transport: f.bTransport)
        let own = overview.devices.filter { $0.jid == f.bob }.map(\.deviceID)
        XCTAssertEqual(own, [4242])
        XCTAssertFalse(own.contains(oldID) || own.contains(newID))
    }

    /// Every unreadable row goes, each under its own account; only the current account gets an identity now, the other
    /// one at its next initialize, and each retires only its own old ID.
    func testAnotherAccountsLostStateIsDiscardedAndGetsItsIdentityOnItsNextConnection() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let oldID = try await retainOneMessageForBob(f)
        let carol = "carol@localhost"
        let carolTransport = TestTransport(account: carol, server: f.server)
        try await f.b.initialize(account: carol, transport: carolTransport)
        let carolOld = try await f.b.overview(account: carol, peer: carol).localDeviceID

        let protection = try StateProtection(key: replacementKey)
        let recovered = OMEMOService(store: f.bStore, protection: protection)
        let lost = try await OMEMOService.unreadableStates(store: f.bStore, protection: protection)
        XCTAssertEqual(Set(lost.map(\.accountID)), [f.bob, carol])
        let started = try await recovered.startOver(account: f.bob, discarding: lost)
        let newID = try XCTUnwrap(started)
        expectNil(try await f.bStore.encryptionState(accountID: carol))
        expectEqual(try await f.bStore.retiredOwnDevices(accountID: carol), [carolOld])
        expectEqual(try await f.bStore.retiredOwnDevices(accountID: f.bob), [oldID])

        try await recovered.initialize(account: carol, transport: carolTransport)
        let carolNew = try await recovered.overview(account: carol, peer: carol).localDeviceID
        XCTAssertNotEqual(carolNew, carolOld)
        for profile in XMPPOMEMOProfile.allCases {
            let listed = await f.server.devices(carol, profile)
            XCTAssertEqual(listed, [carolNew])
            // Bob's list is untouched by Carol's connection.
            let bob = await f.server.devices(f.bob, profile)
            XCTAssertTrue(bob.contains(oldID) && !bob.contains(newID))
        }
        expectEqual(try await f.bStore.retiredOwnDevices(accountID: f.bob), [oldID])
    }

    /// A row from before the device ID was recorded: discarded all the same, but nothing can be retired automatically.
    func testARowWithoutARecordedDeviceIDRetiresNothing() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let oldID = try await retainOneMessageForBob(f)
        XCTAssertTrue(execute(f.directory.appendingPathComponent("bob.sqlite"), "UPDATE encryption_state SET device_id=NULL"))
        let protection = try StateProtection(key: replacementKey)
        let lost = try await OMEMOService.unreadableStates(store: f.bStore, protection: protection)
        XCTAssertEqual(lost.map(\.deviceID), [nil])
        let recovered = OMEMOService(store: f.bStore, protection: protection)
        try await recovered.startOver(account: f.bob, discarding: lost)
        expectEqual(try await f.bStore.retiredOwnDevices(accountID: f.bob), [])
        try await recovered.initialize(account: f.bob, transport: f.bTransport)
        let listed = await f.server.devices(f.bob, .modern)
        XCTAssertTrue(listed.contains(oldID))
    }

    /// A readable row without a recorded ID (written before schema 25) gets it on the next open, without a connection.
    func testRecordLocalDeviceIDsFillsRowsThatPredateTheColumn() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let oldID = try await retainOneMessageForBob(f)
        XCTAssertTrue(execute(f.directory.appendingPathComponent("bob.sqlite"), "UPDATE encryption_state SET device_id=NULL"))
        expectNil(try await f.bStore.encryptionState(accountID: f.bob)?.deviceID)
        try await OMEMOService(store: f.bStore, protection: f.protection).recordLocalDeviceIDs()
        expectEqual(try await f.bStore.encryptionState(accountID: f.bob)?.deviceID, oldID)
    }

    /// Recording runs at every launch for every account: a row that opens but does not decode is that account's own
    /// problem and must not keep storage closed (or stop the other rows from being recorded).
    func testRecordLocalDeviceIDsSkipsARowThatOpensButDoesNotDecode() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let oldID = try await retainOneMessageForBob(f)
        XCTAssertTrue(execute(f.directory.appendingPathComponent("bob.sqlite"), "UPDATE encryption_state SET device_id=NULL"))
        let carol = "carol@localhost"
        try await f.bStore.saveEncryptionState(accountID: carol, expectedRevision: nil, data: try f.protection.seal(Data("{}".utf8), account: carol))
        // Not key loss: the key opens both rows.
        let lost = try await OMEMOService.unreadableStates(store: f.bStore, protection: f.protection)
        XCTAssertEqual(lost, [])
        try await OMEMOService(store: f.bStore, protection: f.protection).recordLocalDeviceIDs()
        expectEqual(try await f.bStore.encryptionState(accountID: f.bob)?.deviceID, oldID)
        expectNil(try await f.bStore.encryptionState(accountID: carol)?.deviceID)
    }

    /// Another client keeps writing back a stale device list that names the dead device. Setup still succeeds once the
    /// new device is listed, and the next connection takes the dead ID out again: retired IDs are kept for good.
    func testARetiredDevicePutBackDoesNotFailSetupAndIsRemovedAgain() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let oldID = try await retainOneMessageForBob(f)
        let protection = try StateProtection(key: replacementKey)
        let recovered = OMEMOService(store: f.bStore, protection: protection)
        let lost = try await OMEMOService.unreadableStates(store: f.bStore, protection: protection)
        let started = try await recovered.startOver(account: f.bob, discarding: lost)
        let newID = try XCTUnwrap(started)

        try await recovered.initialize(account: f.bob, transport: StaleListTransport(base: f.bTransport, putBack: oldID))
        for profile in XMPPOMEMOProfile.allCases {
            let listed = await f.server.devices(f.bob, profile)
            XCTAssertTrue(listed.contains(newID) && listed.contains(oldID), "\(profile) still names the dead device")
        }
        try await recovered.initialize(account: f.bob, transport: f.bTransport)
        for profile in XMPPOMEMOProfile.allCases {
            let listed = await f.server.devices(f.bob, profile)
            XCTAssertEqual(listed, [newID], "\(profile)")
        }
    }

    func testANewDeviceIDIsNeverOneAlreadyUsed() throws {
        var draws: [UInt32] = [7, 9, 7, 11]
        let id = try OMEMOService.newDeviceID(avoiding: [7, 9]) { draws.removeFirst() }
        XCTAssertEqual(id, 11)
    }

    private func execute(_ url: URL, _ sql: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
