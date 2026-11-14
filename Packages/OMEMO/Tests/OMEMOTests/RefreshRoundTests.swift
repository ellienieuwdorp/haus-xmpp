import Foundation
import XCTest
import MessageStore
import XMPPProtocol
@testable import OMEMO

// Holds every lookup until the test lets the round go, so the lookups a refresh asks before it hears any answer are
// exactly one round trip's worth.
private actor HeldLookups {
    private(set) var asked: [TransportLog.Call] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private var expectation: (count: Int, fulfil: XCTestExpectation)?

    func expect(_ count: Int, _ expectation: XCTestExpectation) {
        self.expectation = (count, expectation)
        if asked.count >= count { expectation.fulfill() }
    }

    func hold(_ call: TransportLog.Call) async {
        asked.append(call)
        if let expectation, asked.count == expectation.count { expectation.fulfil.fulfill() }
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    // Answers what is held and everything asked from now on.
    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

private struct RoundTransport: OMEMOGroupTransport {
    let base: TestTransport
    let held: HeldLookups
    var members: [String] = []
    func refreshGroupRoom(_ room: String) throws -> XMPPGroupRoomSnapshot {
        try XMPPGroupRoomSnapshot(room: room, members: members, revision: 1, joined: true)
    }
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        await held.hold(.devices(jid, profile))
        return try await base.fetchOMEMODevices(for: jid, profile: profile)
    }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        await held.hold(.bundle(jid, deviceID, profile))
        return try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile)
    }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { try await base.publishOMEMODevices(devices, profile: profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { try await base.publishOMEMOBundle(bundle) }
}

private func sameCalls(_ a: [TransportLog.Call], _ b: [TransportLog.Call]) -> Bool {
    a.count == b.count && a.allSatisfy(b.contains) && b.allSatisfy(a.contains)
}

@MainActor final class RefreshRoundTests: XCTestCase {
    private func bobDevice(_ f: ServiceFixture) async throws -> UInt32 {
        try await f.b.localIdentity(account: f.bob, profile: .modern).deviceID
    }

    // Unchanged lists: both versions of both owners' lists and the stored peer device's bundle go out before any answer,
    // and nothing follows them.
    func testAnUnchangedChatRefreshesInOneRound() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let held = HeldLookups()
        let firstRound: [TransportLog.Call] = [.devices(f.alice, .legacy), .devices(f.alice, .modern), .devices(f.bob, .legacy),
                                               .devices(f.bob, .modern), .bundle(f.bob, try await bobDevice(f), .modern)]
        let asked = expectation(description: "the first round")
        await held.expect(firstRound.count, asked)
        let service = f.a, alice = f.alice, bob = f.bob, transport = RoundTransport(base: f.aTransport, held: held)
        let refresh = Task { try await service.refreshDevices(account: alice, peer: bob, transport: transport) }
        await fulfillment(of: [asked], timeout: 5)
        let round = await held.asked
        await held.release()
        let overview = try await refresh.value
        XCTAssertTrue(sameCalls(round, firstRound), "\(round)")
        let all = await held.asked
        XCTAssertEqual(all.count, firstRound.count)
        XCTAssertEqual(overview.devices.filter { $0.jid == f.bob && $0.active }.map(\.trust), [.accepted])
    }

    // A device the list newly names is asked in a second round and is stored undecided.
    func testANewlyListedDeviceIsAskedInASecondRoundAndStaysUndecided() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let store = try f.openStore("bob-second.sqlite")
        try await store.acquireTransportOwnership()
        let second = OMEMOService(store: store, protection: f.protection)
        try await second.initialize(account: f.bob, transport: f.bTransport)
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            try await f.b.maintainLocalAdvertisement(account: f.bob, profile: profile, transport: f.bTransport)
        }
        let secondID = try await second.localIdentity(account: f.bob, profile: .modern).deviceID
        let held = HeldLookups()
        await held.release()
        let overview = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: RoundTransport(base: f.aTransport, held: held))
        let asked = await held.asked
        XCTAssertEqual(asked.count, 6)
        XCTAssertEqual(asked.last, .bundle(f.bob, secondID, .modern))
        let added = try XCTUnwrap(overview.devices.first { $0.jid == f.bob && $0.deviceID == secondID })
        XCTAssertEqual(added.trust, .undecided)
        XCTAssertTrue(overview.needsTrust)
    }

    // A room's members are read together, the account's own lists once for all of them.
    func testARoomRefreshAsksEveryMembersListsInOneRound() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = "private@conference.localhost"
        var transport = RoundTransport(base: f.aTransport, held: HeldLookups(), members: [f.alice, f.bob])
        await transport.held.release()
        _ = try await f.a.refreshGroupDevices(account: f.alice, room: room, transport: transport)
        let held = HeldLookups()
        transport = RoundTransport(base: f.aTransport, held: held, members: [f.alice, f.bob])
        let firstRound: [TransportLog.Call] = [.devices(f.alice, .legacy), .devices(f.alice, .modern), .devices(f.bob, .legacy),
                                               .devices(f.bob, .modern), .bundle(f.bob, try await bobDevice(f), .modern)]
        let asked = expectation(description: "the first round")
        await held.expect(firstRound.count, asked)
        let service = f.a, alice = f.alice, current = transport
        let refresh = Task { try await service.refreshGroupDevices(account: alice, room: room, transport: current) }
        await fulfillment(of: [asked], timeout: 5)
        let round = await held.asked
        await held.release()
        let overview = try await refresh.value
        XCTAssertTrue(sameCalls(round, firstRound), "\(round)")
        let all = await held.asked
        XCTAssertEqual(all.count, firstRound.count)
        XCTAssertEqual(overview.devices.map(\.jid), [f.bob])
    }
}
