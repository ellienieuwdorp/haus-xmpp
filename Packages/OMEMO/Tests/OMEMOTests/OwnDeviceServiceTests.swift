import Foundation
import XCTest
import MessageStore
import XMPPProtocol
import OMEMOCrypto
@testable import OMEMO

/// The account-level review of the account's other devices: what is stored, and that one decision reaches every chat.
@MainActor
final class OwnDeviceServiceTests: XCTestCase {
    let carol = "carol@localhost"

    /// Alice's second installation, initialized but reviewed by nobody; both installations advertise in both versions.
    private func addUnreviewedSecondDevice(_ f: ServiceFixture) async throws -> UInt32 {
        let store = try f.openStore("alice-second.sqlite")
        try await store.acquireTransportOwnership()
        let second = OMEMOService(store: store, protection: f.protection)
        try await second.initialize(account: f.alice, transport: f.aTransport)
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            try await f.a.maintainLocalAdvertisement(account: f.alice, profile: profile, transport: f.aTransport)
        }
        return try await second.localIdentity(account: f.alice, profile: .modern).deviceID
    }

    /// Carol with one installation, accepted on Alice's side in `profile`, and a chat with her.
    private func addCarol(_ f: ServiceFixture, profile: XMPPOMEMOProfile) async throws {
        let store = try f.openStore("carol.sqlite")
        try await store.acquireTransportOwnership()
        let service = OMEMOService(store: store, protection: f.protection)
        try await service.initialize(account: carol, transport: TestTransport(account: carol, server: f.server))
        let overview = try await f.a.refreshDevices(account: f.alice, peer: carol, profile: profile, transport: f.aTransport)
        for device in overview.devices where device.active && device.jid == carol {
            try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
        }
    }

    private func queue(_ f: ServiceFixture, to chat: String) async throws -> String {
        try await f.aStore.upsertChat(accountID: f.alice, chatID: chat, title: chat)
        let message = StoredMessage(id: UUID().uuidString, accountID: f.alice, chatID: chat, senderID: f.alice, body: "Hi", isOutgoing: true)
        _ = try await f.aStore.enqueueOutgoing(message)
        return message.id
    }

    /// A new installation of the account appears in both versions as one identity, undecided, without a chat having
    /// to be opened and without choosing a version for any chat; a later key change is a new undecided record.
    func testRefreshStoresOtherInstallationsUndecidedAndFlagsChangedKeys() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let second = try await addUnreviewedSecondDevice(f)
        let local = try await f.a.localIdentity(account: f.alice, profile: .modern).deviceID

        let devices = try await f.a.refreshOwnDevices(account: f.alice, transport: f.aTransport)
        XCTAssertEqual(Set(devices.map(\.profile)), [.legacy, .modern])
        XCTAssertTrue(devices.allSatisfy { $0.deviceID == second && $0.jid == f.alice && $0.active && $0.trust == .undecided && !$0.identityChanged })
        XCTAssertFalse(devices.contains { $0.deviceID == local })
        // The same identity reads as one fingerprint in both versions.
        XCTAssertEqual(Set(devices.map(\.fingerprint)).count, 1)
        let stored = try await f.a.ownDevices(account: f.alice)
        XCTAssertEqual(stored, devices)
        let carolOverview = try await f.a.overview(account: f.alice, peer: carol)
        XCTAssertFalse(carolOverview.isPeerKnown)

        // The same device ID later publishes another OMEMO 2 identity (a reinstall that reused the ID, or an attacker):
        // a new undecided record flagged as changed, while the earlier decision stays on the old key and the legacy record.
        try await f.a.setTrust(account: f.alice, deviceIDs: devices.map(\.id), trust: .accepted)
        let replacement = try OMEMOEngine(profile: .modern, deviceID: second).bundle()
        await f.server.publish(f.alice, XMPPOMEMOBundle(profile: .modern, deviceID: second, identityKey: replacement.identityKey,
                                                        signedPreKeyID: replacement.signedPreKeyID, signedPreKey: replacement.signedPreKey,
                                                        signedPreKeySignature: replacement.signedPreKeySignature, preKeys: replacement.preKeys))
        let after = try await f.a.refreshOwnDevices(account: f.alice, transport: f.aTransport)
        let activeModern = after.filter { $0.profile == .modern && $0.active }
        XCTAssertEqual(activeModern.map(\.trust), [.undecided])
        XCTAssertEqual(activeModern.map(\.identityChanged), [true])
        XCTAssertEqual(after.first { $0.profile == .legacy }?.trust, .accepted)
    }

    /// Trust is per device record, not per chat: accepting the new installation once releases held sends in two chats,
    /// and both envelopes then carry a key for it. Accepted stays accepted, never verified.
    func testOneDecisionReleasesSendsHeldInEveryChat() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        try await addCarol(f, profile: .modern)
        let second = try await addUnreviewedSecondDevice(f)
        let devices = try await f.a.refreshOwnDevices(account: f.alice, transport: f.aTransport)
        let toBob = try await queue(f, to: f.bob)
        let toCarol = try await queue(f, to: carol)

        let held = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        XCTAssertTrue(held.messageIDs.isEmpty)
        XCTAssertEqual(Set(held.blockedChats.keys), [f.bob, carol])
        XCTAssertEqual(Set(held.blockedChats.values), [OMEMOError.trustRequired.errorDescription!])

        try await f.a.setTrust(account: f.alice, deviceIDs: devices.map(\.id), trust: .accepted)
        let decided = try await f.a.ownDevices(account: f.alice)
        XCTAssertTrue(decided.allSatisfy { $0.trust == .accepted })
        let released = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        XCTAssertEqual(released.messageIDs, [toBob, toCarol])
        XCTAssertTrue(released.blockedChats.isEmpty)
        for id in [toBob, toCarol] {
            let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: id)
            XCTAssertTrue(envelope.keys.contains { $0.recipientJID == f.alice && $0.deviceID == second })
        }
    }

    /// Not trusting the other installation keeps 1:1 sending going to every remaining trusted device.
    func testRejectedOwnDeviceIsLeftOutWhileDirectSendingContinues() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let second = try await addUnreviewedSecondDevice(f)
        let devices = try await f.a.refreshOwnDevices(account: f.alice, transport: f.aTransport)
        try await f.a.setTrust(account: f.alice, deviceIDs: devices.map(\.id), trust: .rejected)
        let toBob = try await queue(f, to: f.bob)

        let prepared = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        XCTAssertEqual(prepared.messageIDs, [toBob])
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: toBob)
        XCTAssertFalse(envelope.keys.contains { $0.deviceID == second })
        XCTAssertTrue(envelope.keys.contains { $0.recipientJID == f.bob })
    }

    /// Remove from Account in the review, for a device the user does not recognise: the undecided device leaves the
    /// account's lists in both versions without a chat, sends held for it go out without it, and if it is still signed in
    /// and advertises itself again it comes back not trusted rather than asking again.
    func testRemovingAnUndecidedDeviceReleasesHeldSendsAndAReturnStaysUntrusted() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let store = try f.openStore("alice-second.sqlite")
        try await store.acquireTransportOwnership()
        let secondService = OMEMOService(store: store, protection: f.protection)
        try await secondService.initialize(account: f.alice, transport: f.aTransport)
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            try await f.a.maintainLocalAdvertisement(account: f.alice, profile: profile, transport: f.aTransport)
        }
        let second = try await secondService.localIdentity(account: f.alice, profile: .modern).deviceID
        let local = try await f.a.localIdentity(account: f.alice, profile: .modern).deviceID
        let devices = try await f.a.refreshOwnDevices(account: f.alice, transport: f.aTransport)
        let toBob = try await queue(f, to: f.bob)
        let held = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        XCTAssertEqual(Array(held.blockedChats.keys), [f.bob])

        try await f.a.retireOwnDevice(account: f.alice, deviceID: try XCTUnwrap(devices.first).id, transport: f.aTransport)
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let listed = await f.server.devices(f.alice, profile)
            XCTAssertEqual(listed, [local], "\(profile) list")
        }
        let removed = try await f.a.ownDevices(account: f.alice)
        XCTAssertTrue(removed.allSatisfy { !$0.active && $0.trust == .rejected })
        let released = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        XCTAssertEqual(released.messageIDs, [toBob])
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: toBob)
        XCTAssertFalse(envelope.keys.contains { $0.deviceID == second })

        // Still signed in: it adds itself back with the same identity.
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            try await secondService.maintainLocalAdvertisement(account: f.alice, profile: profile, transport: f.aTransport)
        }
        let returned = try await f.a.refreshOwnDevices(account: f.alice, transport: f.aTransport)
        XCTAssertEqual(returned.filter(\.active).map(\.trust), [.rejected, .rejected])
        let next = try await queue(f, to: f.bob)
        let after = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        XCTAssertTrue(after.messageIDs.contains(next))
        XCTAssertTrue(after.blockedChats.isEmpty)
        let nextEnvelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: next)
        XCTAssertFalse(nextEnvelope.keys.contains { $0.deviceID == second })
    }

    /// The multi-record decision is all or nothing: a stale identifier among them changes none of them.
    func testDecisionWithAStaleIdentifierChangesNothing() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        _ = try await addUnreviewedSecondDevice(f)
        let devices = try await f.a.refreshOwnDevices(account: f.alice, transport: f.aTransport)
        do {
            try await f.a.setTrust(account: f.alice, deviceIDs: devices.map(\.id) + ["\(f.alice)|modern|1|00"], trust: .accepted)
            XCTFail("Accepted a decision naming an unknown key")
        } catch { XCTAssertEqual(error as? OMEMOError, .identityChanged) }
        let unchanged = try await f.a.ownDevices(account: f.alice)
        XCTAssertTrue(unchanged.allSatisfy { $0.trust == .undecided })
    }

    /// The refresh runs on every connection, so its round trips must not hold the service's gate: work that takes the
    /// gate (here a decision; decrypts and seals in the app) completes while a bundle request is still outstanding.
    func testRefreshDoesNotHoldTheGateDuringNetworkRequests() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        _ = try await addUnreviewedSecondDevice(f)
        let probe = GateProbe()
        let service = f.a, account = f.alice
        let transport = CountingTransport(base: f.aTransport, log: TransportLog()) { _, _ in
            guard await probe.start() else { return }
            _ = Task { try await service.setTrust(account: account, deviceIDs: [], trust: .accepted); await probe.finish() }
            // Bounded, so a regression fails instead of deadlocking: the gated call cannot run until this returns.
            for _ in 0..<300 where !(await probe.finished) { try await Task.sleep(for: .milliseconds(10)) }
            await probe.record()
        }
        _ = try await f.a.refreshOwnDevices(account: f.alice, transport: transport)
        let finishedDuringFetch = await probe.finishedDuringFetch
        XCTAssertTrue(finishedDuringFetch)
    }
}

private actor GateProbe {
    private var started = false
    private(set) var finished = false
    private(set) var finishedDuringFetch = false
    func start() -> Bool { defer { started = true }; return !started }
    func finish() { finished = true }
    func record() { finishedDuringFetch = finished }
}
