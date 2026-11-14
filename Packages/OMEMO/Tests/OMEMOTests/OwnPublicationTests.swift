import Foundation
import XCTest
import MessageStore
import OMEMOCrypto
import XMPPProtocol
@testable import OMEMO

// `initialize` on every connection: it reads both versions' own lists and bundles, and writes only what is missing,
// older or pending.
@MainActor
final class OwnPublicationTests: XCTestCase {
    private func publications(_ log: TransportLog) async -> [TransportLog.Call] {
        await log.calls.filter { if case .publishBundle = $0 { return true }; if case .publishDevices = $0 { return true }; return false }
    }

    private func reads(_ f: ServiceFixture, _ local: UInt32) -> Set<String> {
        Set([TransportLog.Call.devices(f.alice, .legacy), .bundle(f.alice, local, .legacy), .devices(f.alice, .modern),
             .bundle(f.alice, local, .modern)].map { "\($0)" })
    }

    func testACurrentPublicationIsOnlyReadOncePerVersion() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        let local = try await f.a.overview(account: f.alice, peer: f.alice).localDeviceID
        let log = TransportLog()
        try await OMEMOService(store: f.aStore, protection: f.protection)
            .initialize(account: f.alice, transport: CountingTransport(base: f.aTransport, log: log))
        let calls = await log.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(Set(calls.map { "\($0)" }), reads(f, local))
    }

    // A pending publication (a prekey consumed by a key exchange) goes out even when the server copy looks current,
    // and is cleared afterwards.
    func testAPendingPublicationIsPublishedAndCleared() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        let (revision, old) = try await f.a.load(f.alice)
        var state = old
        state.pendingBundlePublications = [XMPPOMEMOProfile.modern.rawValue]
        try await f.a.save(state, revision: revision, account: f.alice)

        let log = TransportLog()
        try await f.a.initialize(account: f.alice, transport: CountingTransport(base: f.aTransport, log: log))
        let published = await publications(log)
        XCTAssertEqual(published, [.publishBundle(.modern)])
        let after = try await f.a.load(f.alice).1
        XCTAssertTrue(after.pendingBundlePublications.isEmpty)
    }

    // The server holds an older copy of our bundle (fewer prekeys): ours replaces it in that version only.
    func testAnOlderServerCopyIsReplacedInItsVersionOnly() async throws {
        for profile in XMPPOMEMOProfile.allCases {
            let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
            try await f.a.initialize(account: f.alice, transport: f.aTransport)
            let local = try await f.a.overview(account: f.alice, peer: f.alice).localDeviceID
            let current = try await f.server.bundle(f.alice, local, profile)
            let first = try XCTUnwrap(current.preKeys.keys.min())
            var fewer = current.preKeys
            fewer[first] = nil
            await f.server.publish(f.alice, XMPPOMEMOBundle(profile: profile, deviceID: local, identityKey: current.identityKey,
                                                            signedPreKeyID: current.signedPreKeyID, signedPreKey: current.signedPreKey,
                                                            signedPreKeySignature: current.signedPreKeySignature, preKeys: fewer))
            let log = TransportLog()
            try await f.a.initialize(account: f.alice, transport: CountingTransport(base: f.aTransport, log: log))
            let published = await publications(log)
            XCTAssertEqual(published, [.publishBundle(profile)], "\(profile)")
            let restored = try await f.server.bundle(f.alice, local, profile)
            XCTAssertEqual(restored, current, "\(profile)")
        }
    }

    // Dropped from a list but still holding a current bundle: only the list is written, after reading it again.
    func testAnUnlistedDeviceIsListedAgainWithoutRepublishingItsBundle() async throws {
        for profile in XMPPOMEMOProfile.allCases {
            let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
            try await f.a.initialize(account: f.alice, transport: f.aTransport)
            let local = try await f.a.overview(account: f.alice, peer: f.alice).localDeviceID
            await f.server.publish(f.alice, [424_242], profile)
            let log = TransportLog()
            try await f.a.initialize(account: f.alice, transport: CountingTransport(base: f.aTransport, log: log))
            let published = await publications(log)
            XCTAssertEqual(published, [.publishDevices(profile)], "\(profile)")
            let listed = await f.server.devices(f.alice, profile)
            XCTAssertEqual(Set(listed), [local, 424_242], "\(profile)")
            // Read before and after the list publication, plus the other version's single read.
            let listReads = await log.calls.filter { $0 == .devices(f.alice, profile) }.count
            XCTAssertEqual(listReads, 3, "\(profile)")
        }
    }

    // Decrypts and seals run under the operation gate; the server round trips of `initialize` must not hold it.
    func testTheOperationGateIsFreeWhileTheServerIsRead() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        let service = f.a, account = f.alice, base = f.aTransport
        let log = TransportLog()
        // Deadlocks if the bundle read ran inside the gate: the flush needs it.
        let transport = CountingTransport(base: base, log: log, beforeBundle: { _, _ in
            try await service.flushBundlePublications(account: account, transport: base)
            await log.note("gated work ran")
        })
        try await service.initialize(account: account, transport: transport)
        let notes = await log.notes
        XCTAssertEqual(notes, ["gated work ran", "gated work ran"])
    }

    // Another identity under our ID is refused even when the device list was read concurrently with it, and nothing
    // is written.
    func testAnotherIdentityUnderOurListedIDWritesNothing() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        let local = try await f.a.overview(account: f.alice, peer: f.alice).localDeviceID
        let engine = try OMEMOEngine(profile: .modern, deviceID: local).bundle()
        await f.server.publish(f.alice, XMPPOMEMOBundle(profile: .modern, deviceID: local, identityKey: engine.identityKey,
                                                        signedPreKeyID: engine.signedPreKeyID, signedPreKey: engine.signedPreKey,
                                                        signedPreKeySignature: engine.signedPreKeySignature, preKeys: engine.preKeys))
        let log = TransportLog()
        do {
            try await f.a.initialize(account: f.alice, transport: CountingTransport(base: f.aTransport, log: log))
            XCTFail("Initialized over another identity")
        } catch { XCTAssertEqual(error as? OMEMOError, .identityChanged) }
        let published = await publications(log)
        XCTAssertEqual(published, [])
    }
}
