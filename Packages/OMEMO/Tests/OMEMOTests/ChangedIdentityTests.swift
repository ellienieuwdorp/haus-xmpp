import Foundation
import XCTest
import MessageStore
import XMPPProtocol
import OMEMOCrypto
@testable import OMEMO

private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
private func expectTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a, file: file, line: line) }
private func expectFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(a, file: file, line: line) }
private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

private struct RoomTransport: OMEMOGroupTransport {
    let base: TestTransport
    let room: String
    let members: [String]
    let log: TransportLog
    func refreshGroupRoom(_ requested: String) async throws -> XMPPGroupRoomSnapshot {
        await log.record(.refreshRoom(requested))
        return try .init(room: room, members: members, revision: 1, joined: true)
    }
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        await log.record(.devices(jid, profile))
        return try await base.fetchOMEMODevices(for: jid, profile: profile)
    }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        await log.record(.bundle(jid, deviceID, profile))
        return try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile)
    }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { try await base.publishOMEMODevices(devices, profile: profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { try await base.publishOMEMOBundle(bundle) }
}

// A prekey message under Alice's approved device ID, sent by another identity: a reinstall that kept the ID, or an
// attacker. Libomemo-c refuses it before any ratchet step.
@MainActor final class ChangedIdentityTests: XCTestCase {
    private struct Impostor {
        let original: EncryptionDevice
        let newKey: Data
        let envelope: XMPPOMEMOEnvelope
    }

    // `publishing` puts the new identity's bundle under the same device ID first.
    private func impostor(_ f: ServiceFixture, publishing: Bool, body: String = "Not really Alice") async throws -> Impostor {
        let (_, state) = try await f.b.load(f.bob)
        let original = try unwrap(state.devices.last { $0.jid == f.alice && $0.profile == .modern && $0.active })
        expectEqual(original.trust, .accepted)
        let engine = try OMEMOEngine(profile: .modern, deviceID: original.deviceID)
        let replacement = try engine.bundle()
        if publishing {
            await f.server.publish(f.alice, XMPPOMEMOBundle(profile: .modern, deviceID: replacement.deviceID, identityKey: replacement.identityKey,
                                                            signedPreKeyID: replacement.signedPreKeyID, signedPreKey: replacement.signedPreKey,
                                                            signedPreKeySignature: replacement.signedPreKeySignature, preKeys: replacement.preKeys))
        }
        let bobID = try await f.b.localDeviceID(state, .modern)
        let bob = try await f.server.bundle(f.bob, bobID, .modern)
        let address = DeviceAddress(jid: f.bob, deviceID: bobID)
        try engine.trustIdentity(bob.identityKey, for: address)
        try engine.establishSession(with: address, bundle: DeviceBundle(deviceID: bob.deviceID, identityKey: bob.identityKey,
                                                                         signedPreKeyID: bob.signedPreKeyID, signedPreKey: bob.signedPreKey,
                                                                         signedPreKeySignature: bob.signedPreKeySignature, preKeys: bob.preKeys))
        let xml = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>\(body)</body></content><rpad>padding</rpad>"
            + "<from jid='alice@localhost'/><to jid='bob@localhost'/></envelope>"
        let payload = try PayloadCrypto.seal(Data(xml.utf8), profile: .modern)
        let key = try engine.encrypt(payload.keyMaterial, to: address)
        expectTrue(key.isPreKey)
        let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: original.deviceID,
            keys: [XMPPOMEMOKey(recipientJID: f.bob, deviceID: bobID, keyExchange: true, data: key.data)], iv: nil, payload: payload.payload)
        return Impostor(original: original, newKey: replacement.identityKey, envelope: envelope)
    }

    private func records(_ f: ServiceFixture, _ device: EncryptionDevice) async throws -> [EncryptionDevice] {
        try await f.b.load(f.bob).1.devices.filter { $0.jid == f.alice && $0.profile == .modern && $0.deviceID == device.deviceID }
    }

    func testChangedIdentityOnAKnownDeviceIsNeverDecryptedAndWaitsForReviewOfTheNewKey() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let forged = try await impostor(f, publishing: true)
        let message = f.message(forged.envelope, id: "impostor", fallbackBody: true)
        let engines = try await f.engines(f.bStore, account: f.bob)
        let log = TransportLog()
        do {
            _ = try await f.b.receive(account: f.bob, message: message, transport: CountingTransport(base: f.bTransport, log: log))
            XCTFail("A new identity decrypted under the old approval")
        }
        catch { expectEqual(error as? OMEMOError, .trustRequired) }
        // One targeted lookup; the ciphertext waits for review and alerts once, without content.
        expectEqual(await log.calls, [.devices(f.alice, .modern), .bundle(f.alice, forged.original.deviceID, .modern)])
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).count, 0)
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        expectEqual(try await f.bStore.pendingNotifications(accountID: f.bob).candidates.map(\.content), [.pendingEncrypted])
        // No repair: every ratchet byte (the old session too) stays, and no key transport answers.
        expectEqual(try await f.engines(f.bStore, account: f.bob), engines)
        expectEqual(try await f.bStore.queuedUpdates(accountID: f.bob, kind: .keyTransport).count, 0)
        // The new key is its own undecided record, flagged as changed; the approved one stays for history.
        let stored = try await records(f, forged.original)
        expectEqual(stored.map(\.identityKey), [forged.original.identityKey, forged.newKey])
        let last = try unwrap(stored.last)
        expectEqual(last.trust, .undecided)
        expectTrue(last.identityChanged)
        // Only an explicit decision about the new key opens the kept message.
        try await f.b.setTrust(account: f.bob, deviceID: last.id, trust: .accepted)
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport)
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), ["Not really Alice"])
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
    }

    func testChangedIdentityThatIsNotPublishedBecomesAPlaceholderWithoutReview() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let forged = try await impostor(f, publishing: false)
        let engines = try await f.engines(f.bStore, account: f.bob)
        let message = f.message(forged.envelope, id: "impostor", fallbackBody: true)
        do { _ = try await f.b.receive(account: f.bob, message: message, transport: f.bTransport); XCTFail("Decrypted") }
        catch { expectEqual(error as? OMEMOError, .undecryptable) }
        // The published key is still the approved one: nothing to review, one content-free placeholder that alerts once.
        let rows = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        expectEqual(rows.map(\.unreadableReason), [.decryptFailed])
        expectTrue(rows.allSatisfy { $0.body.isEmpty })
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        expectEqual(try await f.bStore.pendingNotifications(accountID: f.bob).candidates.count, 1)
        expectEqual(try await f.engines(f.bStore, account: f.bob), engines)
        expectEqual(try await f.bStore.queuedUpdates(accountID: f.bob, kind: .keyTransport).count, 0)
        let stored = try await records(f, forged.original)
        expectEqual(stored.map(\.trust), [.accepted])
        expectFalse(stored.contains { $0.identityChanged })
    }

    func testChangedIdentityLookupThatFailsKeepsTheCiphertextForTheNextConnection() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let forged = try await impostor(f, publishing: true)
        let message = f.message(forged.envelope, id: "impostor", fallbackBody: true)
        let offline = CountingTransport(base: f.bTransport, log: TransportLog(), beforeBundle: { _, _ in throw OMEMOError.unavailable })
        do { _ = try await f.b.receive(account: f.bob, message: message, transport: offline); XCTFail("The lookup failed") }
        catch { expectEqual(error as? OMEMOError, .unavailable) }
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        expectEqual(try await f.bStore.pendingNotifications(accountID: f.bob).candidates.map(\.content), [.pendingEncrypted])
        // A connection's retry repeats the lookup; the row then waits for the new key's review.
        do { try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport); XCTFail("Still waiting for review") }
        catch { expectEqual(error as? OMEMOError, .trustRequired) }
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
        expectEqual(try await f.bStore.pendingNotifications(accountID: f.bob).candidates.count, 1)
        let last = try unwrap(try await records(f, forged.original).last)
        expectEqual(last.identityKey, forged.newKey)
        expectTrue(last.identityChanged)
    }

    func testChangedIdentityOfAnApprovedMemberDeviceWaitsForReviewWithoutRepair() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = "private@conference.localhost"
        let setup = RoomTransport(base: f.bTransport, room: room, members: [f.alice, f.bob], log: TransportLog())
        for device in try await f.b.refreshGroupDevices(account: f.bob, room: room, transport: setup).devices where device.active {
            try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        }
        let forged = try await impostor(f, publishing: true)
        let message = try XMPPEncryptedGroupMessage(id: "impostor", room: room, occupant: room + "/alice", sender: f.alice,
                                                    envelope: forged.envelope, hasFallbackBody: true)
        let engines = try await f.engines(f.bStore, account: f.bob)
        let log = TransportLog()
        let transport = RoomTransport(base: f.bTransport, room: room, members: [f.alice, f.bob], log: log)
        do { _ = try await f.b.receiveGroup(account: f.bob, message: message, transport: transport); XCTFail("Decrypted under the old approval") }
        catch { expectEqual(error as? OMEMOError, .trustRequired) }
        expectEqual(await log.calls, [.devices(f.alice, .modern), .bundle(f.alice, forged.original.deviceID, .modern)])
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: room).count, 0)
        expectEqual(try await f.bStore.pendingNotifications(accountID: f.bob).candidates.map(\.content), [.pendingEncrypted])
        expectEqual(try await f.engines(f.bStore, account: f.bob), engines)
        expectEqual(try await f.bStore.queuedUpdates(accountID: f.bob, kind: .keyTransport).count, 0)
        let last = try unwrap(try await records(f, forged.original).last)
        expectEqual(last.identityKey, forged.newKey)
        expectEqual(last.trust, .undecided)
        expectTrue(last.identityChanged)
    }
}
