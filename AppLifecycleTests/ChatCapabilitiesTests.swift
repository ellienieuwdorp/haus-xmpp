import XCTest
import OMEMO
import XMPPProtocol
@testable import XMPPiOS

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
        let suite = "dev.xmpplab.tests.uploads.\(UUID().uuidString)"
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

    func testIncompatibleVersionsAreUnavailableNotReview() {
        let incompatible = DeviceTrustFacts(peerTrust: [.accepted], needsReview: false, incompatible: true, peerKnown: true)
        XCTAssertEqual(direct(.stored(incompatible), ready: true).encryption, .unavailable("Devices use incompatible encryption versions"))
    }
}
