import XCTest
import OMEMO
import XMPPProtocol
@testable import HausXMPP

/// A chat's review lists exactly the devices that keep it waiting, each to be decided on its own.
final class ChatDeviceReviewTests: XCTestCase {
    private let account = "me@example.org", contact = "alex@example.org", member = "maya@example.org"

    private func device(_ jid: String, _ id: UInt32, _ profile: XMPPOMEMOProfile = .modern, trust: DeviceTrust = .undecided,
                        active: Bool = true) -> EncryptionDevice {
        let keys = OwnDeviceReview.sampleIdentities[Int(id % 2)]
        return EncryptionDevice(jid: jid, profile: profile, deviceID: id, identityKey: profile == .legacy ? keys.legacy : keys.modern,
                                trust: trust, active: active, identityChanged: false)
    }

    /// In a 1:1 chat: the contact's and the account's undecided devices in both versions (sending waits on one, reading
    /// on the other), the contact's first; decided and no longer advertised devices are not asked about.
    func testDirectChatListsUndecidedDevicesOfBothOwners() {
        let devices = [device(account, 7), device(contact, 9, .legacy), device(contact, 4), device(contact, 5, trust: .accepted),
                       device(contact, 6, trust: .rejected), device(contact, 8, active: false), device(account, 3, trust: .verified)]
        let listed = ChatDeviceReview.devices(devices, account: account, isGroup: false)
        XCTAssertEqual(listed.map(\.deviceID), [4, 9, 7])
    }

    /// A group also waits on another member's blocked device, which the review offers to trust; the account's own
    /// blocked device is left out of group sends instead and is not listed.
    func testGroupListsDevicesThatHoldItsSends() {
        let devices = [device(member, 2, trust: .rejected), device(member, 1), device(account, 3, trust: .rejected),
                       device(member, 5, trust: .accepted)]
        let listed = ChatDeviceReview.devices(devices, account: account, isGroup: true)
        XCTAssertEqual(listed.map(\.deviceID), [1, 2])
        XCTAssertEqual(ChatDeviceReview.devices(devices, account: account, isGroup: false).map(\.deviceID), [1])
    }

    /// A listed device shows its decision once the stored record no longer holds the chat; accepted stays accepted. A
    /// record that is gone (another key replaced it) is no outcome, and a group's blocked member device still waits.
    func testOutcomeIsReadFromTheStoredRecord() {
        let listed = device(contact, 4)
        XCTAssertNil(ChatDeviceReview.outcome(of: listed, in: [listed], account: account, isGroup: false))
        XCTAssertEqual(ChatDeviceReview.outcome(of: listed, in: [device(contact, 4, trust: .accepted)], account: account, isGroup: false), .accepted)
        XCTAssertEqual(ChatDeviceReview.outcome(of: listed, in: [device(contact, 4, trust: .rejected)], account: account, isGroup: false), .rejected)
        XCTAssertNil(ChatDeviceReview.outcome(of: listed, in: [], account: account, isGroup: false))
        XCTAssertNil(ChatDeviceReview.outcome(of: listed, in: [device(contact, 4, active: false)], account: account, isGroup: false))

        let groupDevice = device(member, 1)
        XCTAssertNil(ChatDeviceReview.outcome(of: groupDevice, in: [device(member, 1, trust: .rejected)], account: account, isGroup: true))
        XCTAssertEqual(ChatDeviceReview.outcome(of: groupDevice, in: [device(member, 1, trust: .verified)], account: account, isGroup: true), .verified)
    }

    /// A chat sending legacy OMEMO lists an OMEMO 2 device only while it holds messages; once decided and released it
    /// leaves the chat's devices, and the review shows the decision it saved (then a later verification) rather than
    /// asking again. The stored record wins while there is one.
    func testReadingOnlyDeviceKeepsTheSavedDecisionAfterLeavingTheChat() {
        let listed = device(contact, 4, .modern)
        XCTAssertEqual(ChatDeviceReview.devices([device(contact, 2, .legacy, trust: .accepted), listed], account: account, isGroup: false), [listed])
        XCTAssertNil(ChatDeviceReview.outcome(of: listed, in: [device(contact, 2, .legacy, trust: .accepted)], decided: [:], account: account, isGroup: false))
        XCTAssertEqual(ChatDeviceReview.outcome(of: listed, in: [], decided: [listed.id: .accepted], account: account, isGroup: false), .accepted)
        XCTAssertEqual(ChatDeviceReview.outcome(of: listed, in: [], decided: [listed.id: .verified], account: account, isGroup: false), .verified)
        XCTAssertEqual(ChatDeviceReview.outcome(of: listed, in: [], decided: [listed.id: .rejected], account: account, isGroup: false), .rejected)
        XCTAssertEqual(ChatDeviceReview.outcome(of: listed, in: [device(contact, 4, .modern, trust: .rejected)], decided: [listed.id: .accepted],
                                                account: account, isGroup: false), .rejected)
        // A decision saved for another key of the same device ID is not this one's.
        let replaced = EncryptionDevice(jid: contact, profile: .modern, deviceID: 4, identityKey: OwnDeviceReview.sampleIdentities[1].modern,
                                        trust: .undecided, active: true, identityChanged: true)
        XCTAssertNil(ChatDeviceReview.outcome(of: replaced, in: [], decided: [listed.id: .accepted], account: account, isGroup: false))
    }
}
