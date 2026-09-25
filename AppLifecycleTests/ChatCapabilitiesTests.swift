import XCTest
import OMEMO
import XMPPProtocol
@testable import HausXMPP

/// Chat-level state derives from stored facts only, so launch, disconnect and reconnect cannot flip it.
final class ChatCapabilitiesTests: XCTestCase {
    private func direct(_ knowledge: EncryptionKnowledge, review: Bool = false, uploads: Bool = true, ready: Bool) -> ChatCapabilities {
        ChatCapabilities.derive(isDemo: false, isGroup: false, knowledge: knowledge, reviewPending: review, uploadAvailable: uploads, sessionReady: ready)
    }

    private func group(_ knowledge: EncryptionKnowledge, joined: Bool, issue: String? = nil, ready: Bool) -> ChatCapabilities {
        ChatCapabilities.derive(isDemo: false, isGroup: true, knowledge: knowledge, reviewPending: false,
                                groupJoined: joined, groupIssue: issue, uploadAvailable: true, sessionReady: ready)
    }

    private let verified = DeviceTrustFacts(peerTrust: [.verified], needsReview: false, peerKnown: true)

    /// (a) A cold launch shows stored trust and the remembered attach button before any connection.
    func testLaunchBeforeConnectKeepsStoredTrust() {
        let launch = direct(.stored(verified), ready: false)
        XCTAssertEqual(launch.encryption, .encrypted(verified: true))
        XCTAssertTrue(launch.canAttach)
        XCTAssertTrue(launch.canSend, "a 1:1 message is queued offline")
        XCTAssertEqual(launch.deviceCount, 1)
    }

    /// (b) connect → disconnect → reconnect, with the refresh fence moving stored → refreshed → stored → refreshed.
    func testConnectDisconnectReconnectNeverChangesEncryptionOrAttach() {
        let accepted = DeviceTrustFacts(peerTrust: [.accepted], needsReview: false, peerKnown: true)
        let empty = DeviceTrustFacts(peerTrust: [], needsReview: false, peerKnown: true)
        for facts in [verified, accepted, empty] {
            let sequence: [(EncryptionKnowledge, Bool)] = [(.stored(facts), false), (.stored(facts), true), (.refreshed(facts), true),
                                                           (.stored(facts), false), (.stored(facts), true), (.refreshed(facts), true)]
            let values = sequence.map { direct($0.0, ready: $0.1) }
            XCTAssertEqual(Set(values.map { "\($0)" }).count, 1, "\(facts): \(values)")
        }
        // A group keeps its pill; only sending follows the room presence.
        let facts = DeviceTrustFacts(peerTrust: [.accepted, .verified], needsReview: false, peerKnown: true)
        let steps = [group(.stored(facts), joined: false, ready: false), group(.refreshed(facts), joined: true, ready: true),
                     group(.stored(facts), joined: false, ready: false), group(.refreshed(facts), joined: true, ready: true)]
        XCTAssertEqual(Set(steps.map { "\($0.encryption)" }), ["encrypted(verified: false)"])
        XCTAssertEqual(steps.map(\.canSend), [false, true, false, true])
        XCTAssertEqual(Set(steps.map(\.deviceCount)), [2])
    }

    /// (c) Accepted is not verified: every active peer device must be verified.
    func testAcceptedIsNotVerified() {
        let mixed = DeviceTrustFacts(peerTrust: [.accepted, .verified], needsReview: false, peerKnown: true)
        XCTAssertEqual(direct(.stored(mixed), ready: true).encryption, .encrypted(verified: false))
        let withRejected = DeviceTrustFacts(peerTrust: [.verified, .rejected], needsReview: false, peerKnown: true)
        XCTAssertEqual(direct(.stored(withRejected), ready: true).encryption, .encrypted(verified: false))
        XCTAssertEqual(direct(.refreshed(verified), ready: true).encryption, .encrypted(verified: true))
    }

    /// (d) Not yet known is pending, never "not encrypted"; only a completed answer makes it unavailable.
    func testPendingIsNotUnavailable() {
        XCTAssertEqual(direct(.pending, ready: false).encryption, .pending)
        XCTAssertNil(direct(.pending, ready: false).deviceCount)
        let neverFetched = DeviceTrustFacts(peerTrust: [], needsReview: false, peerKnown: false)
        XCTAssertEqual(direct(.stored(neverFetched), ready: true).encryption, .pending)
        XCTAssertEqual(direct(.refreshed(neverFetched), ready: true).encryption, .unavailable("No compatible encryption devices"))
        let answeredEmpty = DeviceTrustFacts(peerTrust: [], needsReview: false, peerKnown: true)
        XCTAssertEqual(direct(.stored(answeredEmpty), ready: false).encryption, .unavailable("No compatible encryption devices"),
                       "a stored empty answer survives relaunch")
        XCTAssertEqual(group(.pending, joined: false, ready: false).encryption, .pending)
        XCTAssertEqual(group(.stored(verified), joined: false, issue: "Not a member", ready: true).encryption, .unavailable("Not a member"))
        XCTAssertEqual(group(.stored(verified), joined: true, issue: "Old failure", ready: true).encryption, .encrypted(verified: true))
    }

    /// (e) The attach button follows the last completed discovery only; groups never show it.
    func testAttachFollowsRememberedUploadsNotTheSocket() {
        XCTAssertFalse(direct(.stored(verified), uploads: false, ready: true).canAttach)
        XCTAssertTrue(direct(.stored(verified), uploads: true, ready: false).canAttach)
        XCTAssertTrue(direct(.pending, uploads: true, ready: false).canAttach)
        XCTAssertFalse(group(.stored(verified), joined: true, ready: true).canAttach)
        let demo = ChatCapabilities.derive(isDemo: true, isGroup: false, knowledge: .pending, reviewPending: false, uploadAvailable: false, sessionReady: false)
        XCTAssertTrue(demo.canAttach)
    }

    func testThrownDiscoveryKeepsTheServiceAndACompletedNilClearsIt() throws {
        let suite = "haus.xmpp.tests.uploads.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let memory = UploadServiceMemory(defaults: defaults)
        let account = "alice@example.org"
        let service = XMPPUploadService(jid: "upload.example.org", maximumFileSize: 10_485_760)
        XCTAssertNil(memory.load(account: account))

        var current = memory.settle(account: account, previous: nil, discovery: .success(service))
        XCTAssertEqual(current, service)
        XCTAssertEqual(memory.load(account: account), service, "a relaunch restores it")
        XCTAssertNil(memory.load(account: "bob@example.org"), "per account")

        current = memory.settle(account: account, previous: current, discovery: .failure(XMPPClientError.connectionClosed))
        XCTAssertEqual(current, service, "a thrown discovery keeps the last answer")
        XCTAssertEqual(memory.load(account: account), service)

        current = memory.settle(account: account, previous: current, discovery: .success(nil))
        XCTAssertNil(current, "a completed answer without uploads is definitive")
        XCTAssertNil(memory.load(account: account))

        _ = memory.settle(account: account, previous: nil, discovery: .success(XMPPUploadService(jid: "upload.example.org", maximumFileSize: nil)))
        XCTAssertEqual(memory.load(account: account)?.maximumFileSize, nil)
        memory.forget(account: account)
        XCTAssertNil(memory.load(account: account), "sign-out clears it")
    }

    func testRetainedCiphertextForcesReviewOnlyForThatChat() {
        XCTAssertEqual(direct(.stored(verified), review: true, ready: true).encryption, .needsReview)
        XCTAssertEqual(direct(.pending, review: true, ready: false).encryption, .needsReview)
        XCTAssertEqual(direct(.stored(verified), review: false, ready: true).encryption, .encrypted(verified: true))
        let undecided = DeviceTrustFacts(peerTrust: [.undecided, .verified], needsReview: true, peerKnown: true)
        XCTAssertEqual(direct(.stored(undecided), ready: false).encryption, .needsReview)
    }

    /// A stored group device, decoded because `EncryptionDevice` has no public initializer.
    private func device(_ jid: String, _ id: UInt32, _ trust: DeviceTrust, active: Bool = true) throws -> EncryptionDevice {
        let json: [String: Any] = ["jid": jid, "profile": "modern", "deviceID": id, "identityKey": Data(repeating: UInt8(id), count: 32).base64EncodedString(),
                                   "trust": trust.rawValue, "active": active, "identityChanged": false]
        return try JSONDecoder().decode(EncryptionDevice.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A member with no active device keeps the group from reading as verified, even when every listed device is.
    func testGroupMemberWithoutDevicesIsNotVerified() throws {
        let me = "me@example.org", bob = "bob@example.org", carol = "carol@example.org"
        let bobVerified = try device(bob, 11, .verified)
        let carolVerified = try device(carol, 12, .verified)
        var room = GroupChatState(members: [me, bob, carol], devices: [try device(me, 1, .accepted), bobVerified])
        room.joined = true
        let noCarol = DeviceTrustFacts(room, account: me)
        XCTAssertFalse(noCarol.everyPeerHasDevice)
        XCTAssertEqual(group(.stored(noCarol), joined: true, ready: true).encryption, .encrypted(verified: false))

        room.devices.append(try device(carol, 12, .verified, active: false))
        XCTAssertEqual(group(.stored(DeviceTrustFacts(room, account: me)), joined: true, ready: true).encryption, .encrypted(verified: false),
                       "an inactive device does not count")

        room.devices = [try device(me, 1, .accepted), bobVerified, carolVerified]
        let everyone = DeviceTrustFacts(room, account: me)
        XCTAssertTrue(everyone.everyPeerHasDevice, "our own devices never count for or against the group")
        XCTAssertEqual(group(.stored(everyone), joined: true, ready: true).encryption, .encrypted(verified: true))

        room.devices = [bobVerified, try device(carol, 12, .accepted)]
        XCTAssertEqual(group(.stored(DeviceTrustFacts(room, account: me)), joined: true, ready: true).encryption, .encrypted(verified: false),
                       "accepted is not verified")
    }

    /// A decryption failure, blocked plaintext or failed refresh is a footnote: it never moves the pill or opens review.
    func testDecryptFailureLandsInDiagnosticsAndKeepsTheTrustLevel() {
        var attention = EncryptionAttention()
        let before = direct(.stored(verified), review: attention.heldForTrust.contains("bob@example.org"), ready: true)
        attention.note("An encrypted message could not be opened")
        XCTAssertEqual(attention.diagnostics, "An encrypted message could not be opened")
        XCTAssertTrue(attention.heldForTrust.isEmpty)
        let after = direct(.stored(verified), review: attention.heldForTrust.contains("bob@example.org"), ready: true)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.encryption, .encrypted(verified: true))
        // Unknown stays pending, never "off", whatever the footer says.
        XCTAssertEqual(direct(.pending, review: attention.heldForTrust.contains("bob@example.org"), ready: false).encryption, .pending)
        XCTAssertFalse(EncryptionAttention.needsTrustDecision(OMEMOError.invalidContent))
        XCTAssertFalse(EncryptionAttention.needsTrustDecision(OMEMOError.notForThisDevice))
    }

    /// A send held for a fingerprint decision shows the review card for that chat only; other holds are footnotes.
    func testTrustHeldSendShowsReviewForThatChatOnly() throws {
        var attention = EncryptionAttention()
        let bob = "bob@example.org", carol = "carol@example.org", dave = "dave@example.org"
        let trust = try XCTUnwrap(OMEMOError.trustRequired.errorDescription)
        let noDevices = try XCTUnwrap(OMEMOError.noDevices.errorDescription)
        let changed = try XCTUnwrap(OMEMOError.recipientSetChanged.errorDescription)
        let held = attention.hold([bob: trust, carol: noDevices, dave: changed], shownChat: carol)
        XCTAssertEqual(held, [bob])
        XCTAssertEqual(attention.heldForTrust, [bob])
        XCTAssertEqual(attention.diagnostics, noDevices, "the shown chat's reason is the footnote")
        XCTAssertEqual(direct(.stored(verified), review: attention.heldForTrust.contains(bob), ready: true).encryption, .needsReview)
        XCTAssertEqual(direct(.stored(verified), review: attention.heldForTrust.contains(carol), ready: true).encryption, .encrypted(verified: true))
        XCTAssertEqual(direct(.stored(verified), review: attention.heldForTrust.contains(dave), ready: true).encryption, .encrypted(verified: true))

        // A changed identity is a trust decision too; a group hold is keyed by its room.
        attention.hold(["room@muc.example.org": try XCTUnwrap(OMEMOError.identityChanged.errorDescription)], shownChat: nil)
        XCTAssertEqual(attention.heldForTrust, [bob, "room@muc.example.org"])
        XCTAssertEqual(attention.diagnostics, noDevices, "a hold for another chat leaves the footer alone")

        attention.trustDecided(in: bob)
        XCTAssertEqual(attention.heldForTrust, ["room@muc.example.org"])
        attention.settlePass(heldForTrust: [])
        XCTAssertTrue(attention.heldForTrust.isEmpty, "a completed pass that held nothing clears the marks")
        XCTAssertTrue(EncryptionAttention.needsTrustDecision(OMEMOError.trustRequired))
    }

    /// A failed group refresh is read-only text for Group Details until a refresh succeeds.
    func testGroupRefreshFailureIsAFootnoteUntilARefreshSucceeds() {
        var attention = EncryptionAttention()
        let room = "room@muc.example.org"
        attention.groupDevices(room, problem: "Last group refresh failed: timeout")
        XCTAssertEqual(attention.groupProblems[room], "Last group refresh failed: timeout")
        XCTAssertEqual(attention.diagnostics, "Last group refresh failed: timeout")
        XCTAssertTrue(attention.heldForTrust.isEmpty)
        attention.groupDevices(room, problem: nil)
        XCTAssertNil(attention.groupProblems[room])
    }

    /// A device published only in the other OMEMO version is a notice on the Devices screen; the chat keeps sending
    /// to the devices that are in this version (the old rule paused the chat indefinitely).
    func testDevicesInOnlyTheOtherVersionDoNotHoldTheChat() {
        let facts = DeviceTrustFacts(peerTrust: [.accepted], needsReview: false, peerKnown: true)
        XCTAssertEqual(direct(.stored(facts), ready: true).encryption, .encrypted(verified: false))
        XCTAssertTrue(direct(.stored(facts), ready: true).canSend)
    }
}

extension ChatCapabilitiesTests {
    /// Retained ciphertext alone never asks for a review: only an undecided stored device or a trust hold does.
    func testRetainedCiphertextWithoutUndecidedDevicesIsNotAReview() {
        var attention = EncryptionAttention()
        attention.hold(["alex@example.com": "An encrypted message could not be opened."], shownChat: nil)
        XCTAssertFalse(attention.heldForTrust.contains("alex@example.com"))
        let stored = DeviceTrustFacts(peerTrust: [.accepted], needsReview: false, peerKnown: true)
        let capabilities = ChatCapabilities.derive(isDemo: false, isGroup: false, knowledge: .stored(stored),
                                                   reviewPending: attention.heldForTrust.contains("alex@example.com"),
                                                   uploadAvailable: true, sessionReady: false)
        XCTAssertEqual(capabilities.encryption, .encrypted(verified: false))
    }
}
