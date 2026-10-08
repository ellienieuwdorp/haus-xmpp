import XCTest
import OMEMO
import XMPPProtocol
@testable import HausXMPP

/// The account-level review lists the account's undecided devices once each, whatever chat they would block.
final class OwnDeviceReviewTests: XCTestCase {
    private let account = "me@example.org"

    private func device(_ id: UInt32, _ profile: XMPPOMEMOProfile, identity: Int = 0, trust: DeviceTrust = .undecided,
                        active: Bool = true, changed: Bool = false) -> EncryptionDevice {
        let keys = OwnDeviceReview.sampleIdentities[identity]
        return EncryptionDevice(jid: account, profile: profile, deviceID: id, identityKey: profile == .legacy ? keys.legacy : keys.modern,
                                trust: trust, active: active, identityChanged: changed)
    }

    /// A freshly signed-in installation sees every other device of the account at once; one identity published in both
    /// versions is one entry decided for both records.
    func testEveryUndecidedDeviceAppearsOnceWithBothVersionsTogether() {
        let devices = [device(9, .modern, identity: 1), device(5, .modern), device(5, .legacy)]
        let candidates = OwnDeviceReview.candidates(devices)
        XCTAssertEqual(candidates.map(\.deviceID), [5, 9])
        XCTAssertEqual(candidates[0].records.map(\.profile), [.legacy, .modern])
        XCTAssertEqual(candidates[0].versions, "Both encryption versions")
        XCTAssertEqual(candidates[1].records.map(\.profile), [.modern])
        XCTAssertEqual(OwnDeviceReview.headline(candidates), "2 devices on your account need review")
    }

    /// Only the same fingerprint is decided together: a device ID publishing two identities is two entries.
    func testDifferentIdentitiesUnderOneDeviceIDAreReviewedSeparately() {
        let candidates = OwnDeviceReview.candidates([device(5, .legacy), device(5, .modern, identity: 1)])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.records.count == 1 })
        XCTAssertNotEqual(candidates[0].fingerprint, candidates[1].fingerprint)
    }

    /// Decided and no-longer-advertised devices are not asked about; a decision elsewhere (a chat's Devices page) on one
    /// version leaves only the other version's record to review.
    func testDecidedAndInactiveDevicesAreLeftOut() {
        let devices = [device(5, .legacy, trust: .accepted), device(5, .modern), device(6, .modern, trust: .rejected),
                       device(7, .modern, trust: .verified), device(8, .modern, identity: 1, active: false)]
        let candidates = OwnDeviceReview.candidates(devices)
        XCTAssertEqual(candidates.map(\.deviceID), [5])
        XCTAssertEqual(candidates[0].records.map(\.profile), [.modern])
        XCTAssertTrue(OwnDeviceReview.candidates([]).isEmpty)
    }

    /// A changed identity is called out as changed, never as a new device.
    func testChangedIdentityIsCalledOut() {
        let candidates = OwnDeviceReview.candidates([device(5, .legacy), device(5, .modern, changed: true)])
        XCTAssertTrue(candidates[0].identityChanged)
        XCTAssertEqual(OwnDeviceReview.headline(candidates), "A device on your account changed its identity")
        XCTAssertEqual(OwnDeviceReview.headline(OwnDeviceReview.candidates([device(5, .modern)])), "New device on your account")
        // Several waiting devices do not hide the changed one in a count.
        let several = OwnDeviceReview.candidates([device(5, .modern), device(9, .modern, identity: 1, changed: true)])
        XCTAssertEqual(OwnDeviceReview.headline(several), "2 devices on your account need review, one changed its identity")
    }

    /// The review shows an outcome only once every record carries it; accepted stays accepted, never verified.
    func testDecisionIsReadFromTheStoredRecords() throws {
        let candidate = try XCTUnwrap(OwnDeviceReview.candidates([device(5, .legacy), device(5, .modern)]).first)
        XCTAssertNil(OwnDeviceReview.decision(on: candidate, in: [device(5, .legacy), device(5, .modern)]))
        XCTAssertNil(OwnDeviceReview.decision(on: candidate, in: [device(5, .legacy, trust: .accepted), device(5, .modern)]))
        XCTAssertEqual(OwnDeviceReview.decision(on: candidate, in: [device(5, .legacy, trust: .accepted), device(5, .modern, trust: .accepted)]), .accepted)
        XCTAssertEqual(OwnDeviceReview.decision(on: candidate, in: [device(5, .legacy, trust: .rejected), device(5, .modern, trust: .rejected)]), .rejected)
        // A record that is gone (replaced by another key) is not an outcome: the next decision reports the change.
        XCTAssertNil(OwnDeviceReview.decision(on: candidate, in: [device(5, .legacy, trust: .accepted)]))
    }
}
