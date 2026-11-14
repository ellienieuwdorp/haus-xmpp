import Foundation
import XCTest
import MessageStore
@testable import XMPPProtocol
@testable import OMEMO

private actor Stream {
    var epoch: XMPPDeviceEpoch? = XMPPDeviceEpoch(session: UUID(), changes: 0, notified: [])
    var lookups = 0
    // Applied to the epoch once, while the next lookup is in flight.
    var duringLookup: (@Sendable (XMPPDeviceEpoch?) -> XMPPDeviceEpoch?)?

    func set(_ epoch: XMPPDeviceEpoch?) { self.epoch = epoch }
    func move() { epoch = epoch.map { XMPPDeviceEpoch(session: $0.session, changes: $0.changes + 1, notified: $0.notified) } }
    func notify(_ owners: [String]) {
        // A notification is itself a device-list event.
        let notified = Set(owners.map { DeviceListObservation.key($0, .modern) })
        epoch = epoch.map { XMPPDeviceEpoch(session: $0.session, changes: $0.changes + 1, notified: notified) }
    }
    func onNextLookup(_ change: @escaping @Sendable (XMPPDeviceEpoch?) -> XMPPDeviceEpoch?) { duringLookup = change }
    func lookedUp() {
        lookups += 1
        if let change = duringLookup { epoch = change(epoch); duringLookup = nil }
    }
}

private struct StreamTransport: OMEMOGroupTransport {
    let base: TestTransport
    let stream: Stream
    var members: [String] = []
    func refreshGroupRoom(_ room: String) throws -> XMPPGroupRoomSnapshot {
        try XMPPGroupRoomSnapshot(room: room, members: members, revision: 1, joined: true)
    }
    func omemoDeviceEpoch() async -> XMPPDeviceEpoch? { await stream.epoch }
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        await stream.lookedUp()
        return try await base.fetchOMEMODevices(for: jid, profile: profile)
    }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        await stream.lookedUp()
        return try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile)
    }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { try await base.publishOMEMODevices(devices, profile: profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { try await base.publishOMEMOBundle(bundle) }
}

@MainActor final class DeviceReuseTests: XCTestCase {
    private let clock = ManualClock()

    private func fixture() async throws -> (ServiceFixture, Stream, StreamTransport) {
        let f = try ServiceFixture()
        try await f.initialize(.modern)
        let stream = Stream(), clock = clock
        await f.a.useDeviceClock { clock.now() }
        return (f, stream, StreamTransport(base: f.aTransport, stream: stream))
    }

    // Each pass prepares what is queued now; returns how many lookups it asked and what it may send.
    private func pass(_ f: ServiceFixture, _ stream: Stream, _ transport: StreamTransport, _ body: String) async throws -> (lookups: Int, ready: Bool) {
        let before = await stream.lookups
        let message = try await f.queue(body)
        let result = try await f.a.prepareAvailableMessages(account: f.alice, transport: transport)
        return (await stream.lookups - before, result.messageIDs.contains(message.id))
    }

    private func expectLookups(_ expected: Int, _ f: ServiceFixture, _ stream: Stream, _ transport: StreamTransport, _ body: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await pass(f, stream, transport, body)
        // Messages prepared by earlier passes stay queued and are checked again under their saved version: a refresh
        // per version when nothing is reused.
        if expected == 0 { XCTAssertEqual(result.lookups, 0, body, file: file, line: line) }
        else { XCTAssertGreaterThanOrEqual(result.lookups, expected, body, file: file, line: line) }
        XCTAssertTrue(result.ready, body, file: file, line: line)
    }

    func testAChatReadOnThisStreamIsNotLookedUpAgainUntilSomethingCouldHaveChangedIt() async throws {
        let (f, stream, transport) = try await fixture(); addTeardownBlock { try await f.cleanup() }
        let first = try await pass(f, stream, transport, "first")
        XCTAssertEqual(first.lookups, 5)
        XCTAssertTrue(first.ready)
        let second = try await pass(f, stream, transport, "second")
        XCTAssertEqual(second.lookups, 0)
        XCTAssertTrue(second.ready)
        // A device-list event, a bounce or a roster change on the stream moves its epoch.
        await stream.move()
        try await expectLookups(5, f, stream, transport, "after an event")
        // So does a new stream.
        await stream.set(XMPPDeviceEpoch(session: UUID(), changes: 0, notified: []))
        try await expectLookups(5, f, stream, transport, "on a new stream")
        // A stream that cannot vouch (offline, CSI inactive) never skips them.
        await stream.set(nil)
        try await expectLookups(5, f, stream, transport, "inactive")
        try await expectLookups(5, f, stream, transport, "inactive again")
    }

    func testAnOwnerWhoseChangesAreNotAnnouncedIsLookedUpAgainAfterTheWindow() async throws {
        let (f, stream, transport) = try await fixture(); addTeardownBlock { try await f.cleanup() }
        try await expectLookups(5, f, stream, transport, "first")
        clock.advance(DeviceFreshness.window - .milliseconds(1))
        try await expectLookups(0, f, stream, transport, "inside")
        clock.advance(.milliseconds(1))
        try await expectLookups(5, f, stream, transport, "at the window")
        // Both owners' lists arrived as notifications on this stream: their changes are announced, so no window applies.
        await stream.notify([f.alice, f.bob])
        try await expectLookups(5, f, stream, transport, "notified")
        clock.advance(.seconds(3_600))
        try await expectLookups(0, f, stream, transport, "an hour later")
        // Only one notified owner is not enough.
        await stream.notify([f.alice])
        try await expectLookups(5, f, stream, transport, "one owner notified")
        clock.advance(DeviceFreshness.window)
        try await expectLookups(5, f, stream, transport, "after its window")
    }

    // An event that arrives while the lookups are out may postdate their answers: nothing is recorded.
    func testAnEventDuringTheLookupsIsNotRecordedAsCurrent() async throws {
        let (f, stream, transport) = try await fixture(); addTeardownBlock { try await f.cleanup() }
        await stream.onNextLookup { $0.map { XMPPDeviceEpoch(session: $0.session, changes: $0.changes + 1, notified: $0.notified) } }
        try await expectLookups(5, f, stream, transport, "first")
        try await expectLookups(5, f, stream, transport, "second")
        try await expectLookups(0, f, stream, transport, "third")
    }

    // A skipped lookup changes no trust rule: the seal reads the stored devices, so a decision made since holds the chat.
    func testAReusedRefreshStillHoldsForADeviceDecidedSince() async throws {
        let (f, stream, transport) = try await fixture(); addTeardownBlock { try await f.cleanup() }
        try await expectLookups(5, f, stream, transport, "first")
        let devices = try await f.a.overview(account: f.alice, peer: f.bob).devices
        let bob = try XCTUnwrap(devices.first { $0.jid == f.bob && $0.active })
        try await f.a.setTrust(account: f.alice, deviceID: bob.id, trust: .rejected)
        let held = try await pass(f, stream, transport, "after the rejection")
        XCTAssertEqual(held.lookups, 0)
        XCTAssertFalse(held.ready)
    }

    // A sender device we did not know means the owner's list moved: the next send reads it whole.
    func testAnUnknownSenderDeviceEndsTheReuseForItsOwner() async throws {
        let (f, stream, transport) = try await fixture(); addTeardownBlock { try await f.cleanup() }
        try await expectLookups(5, f, stream, transport, "first")
        try await f.a.refreshSenderDeviceLocked(account: f.alice, owner: f.bob, deviceID: 4_242, profile: .modern, transport: f.aTransport)
        try await expectLookups(5, f, stream, transport, "second")
    }

    // A room reuses its members' devices, never its membership: both room reads still happen on every send.
    func testARoomReusesItsMembersDevicesButReadsTheRoomEachTime() async throws {
        let (f, stream, base) = try await fixture(); addTeardownBlock { try await f.cleanup() }
        var transport = base
        transport.members = [f.alice, f.bob]
        let room = "private@conference.localhost"
        _ = try await f.a.refreshGroupDevices(account: f.alice, room: room, transport: transport)
        let before = await stream.lookups
        let overview = try await f.a.refreshGroupDevices(account: f.alice, room: room, transport: transport)
        let after = await stream.lookups
        XCTAssertEqual(after, before)
        XCTAssertEqual(overview.room.members, [f.alice, f.bob])
        // A new member has never been read on this stream.
        transport.members = [f.alice, f.bob, "carol@localhost"]
        _ = try await f.a.refreshGroupDevices(account: f.alice, room: room, transport: transport)
        let withCarol = await stream.lookups
        XCTAssertGreaterThan(withCarol, after)
    }
}

// Time moves only when the test advances it.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    func now() -> Duration { lock.withLock { elapsed } }
    func advance(_ duration: Duration) { lock.withLock { elapsed += duration } }
}
