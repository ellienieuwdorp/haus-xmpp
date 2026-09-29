import XCTest
import XMPPProtocol
@testable import HausXMPP

final class LastSeenTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let me = "me@x", alex = "alex@x"

    private func presence(_ resource: String?, available: Bool, idle: Date? = nil, contact: String = "alex@x") -> XMPPContactPresence {
        XMPPContactPresence(contact: contact, resource: resource, available: available, idleSince: idle)
    }

    private func loaded(_ items: [XMPPRosterItem] = []) -> LastSeenTracker {
        var tracker = LastSeenTracker()
        tracker.applyRoster(items, replacesAll: true)
        return tracker
    }

    // MARK: Derivation

    func testAnyActiveResourceIsOnline() {
        var tracker = LastSeenTracker()
        tracker.apply(presence("phone", available: true, idle: start), account: me, isContact: true, now: start)
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start), "one idle resource dates the contact")
        tracker.apply(presence("laptop", available: true), account: me, isContact: true, now: start + 5)
        XCTAssertEqual(tracker.lastSeen(for: alex), .online)
    }

    func testAllIdleUsesTheNewestIdleStart() {
        var tracker = LastSeenTracker()
        tracker.apply(presence("phone", available: true, idle: start - 600), account: me, isContact: true, now: start)
        tracker.apply(presence("laptop", available: true, idle: start - 60), account: me, isContact: true, now: start)
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start - 60))
    }

    func testWatchedDepartureDatesTheContact() {
        var tracker = LastSeenTracker()
        tracker.apply(presence("phone", available: true), account: me, isContact: true, now: start)
        tracker.apply(presence("laptop", available: true), account: me, isContact: true, now: start)
        tracker.apply(presence("phone", available: false), account: me, isContact: true, now: start + 10)
        XCTAssertEqual(tracker.lastSeen(for: alex), .online, "another resource is still there")
        tracker.apply(presence("laptop", available: false), account: me, isContact: true, now: start + 20)
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start + 20))
    }

    func testAProbeAnswerForAnOfflineContactIsNotADeparture() {
        var tracker = LastSeenTracker()
        XCTAssertTrue(tracker.apply(presence(nil, available: false), account: me, isContact: true, now: start))
        XCTAssertNil(tracker.lastSeen(for: alex), "offline without a time stays unknown")
        tracker.apply(presence("phone", available: true), account: me, isContact: true, now: start)
        tracker.apply(presence(nil, available: false), account: me, isContact: true, now: start + 30)
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start + 30), "a bare unavailable ends every resource we saw")
    }

    func testLastActivitySecondsAndZeroMeansUnknown() {
        var tracker = LastSeenTracker()
        tracker.recordLastActivity(seconds: 0, of: alex, now: start)
        XCTAssertNil(tracker.lastSeen(for: alex))
        tracker.recordLastActivity(seconds: 300, of: alex, now: start)
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start - 300))
        tracker.apply(presence("phone", available: true), account: me, isContact: true, now: start)
        XCTAssertEqual(tracker.lastSeen(for: alex), .online, "an available resource outranks the server's answer")
    }

    func testReconnectKeepsWhatWasSeenButForgetsWhoIsAvailable() {
        var tracker = loaded([XMPPRosterItem(jid: alex, subscription: .both)])
        tracker.apply(presence("phone", available: true), account: me, isContact: true, now: start)
        XCTAssertEqual(tracker.askStep(for: alex, now: start), .nothing)
        tracker.resetConnection()
        XCTAssertNil(tracker.lastSeen(for: alex), "online is not assumed across a reconnect")
        XCTAssertFalse(tracker.rosterLoaded)
        XCTAssertTrue(tracker.roster.isEmpty)
        tracker.apply(presence("phone", available: true), account: me, isContact: true, now: start)
        tracker.apply(presence("phone", available: false), account: me, isContact: true, now: start + 5)
        tracker.resetConnection()
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start + 5))
    }

    func testANewSessionDropsWhoWasAvailableButAResumedOneKeepsIt() {
        var tracker = loaded([XMPPRosterItem(jid: alex, subscription: .both)])
        tracker.apply(presence("phone", available: true), account: me, isContact: true, now: start)
        tracker.resetConnection()
        tracker.resetConnection() // a disconnect followed by a session reset must not lose what was held
        tracker.beginConnection(resumed: true)
        XCTAssertEqual(tracker.lastSeen(for: alex), .online, "a resumed session gets no probe answer for an unchanged contact")
        tracker.applyRoster([XMPPRosterItem(jid: alex, subscription: .both)], replacesAll: true)
        XCTAssertEqual(tracker.askStep(for: alex, now: start + 1), .nothing, "no XEP-0012 query for a contact still online")
        tracker.apply(presence("phone", available: false), account: me, isContact: true, now: start + 30)
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start + 30), "a departure queued while detached still dates the contact")

        tracker.apply(presence("phone", available: true), account: me, isContact: true, now: start + 40)
        tracker.resetConnection()
        tracker.beginConnection(resumed: false)
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start + 30), "a new session waits for the probe answers")
        tracker.beginConnection(resumed: true)
        XCTAssertEqual(tracker.lastSeen(for: alex), .lastSeen(start + 30), "what a new session dropped is not restored later")
    }

    // MARK: Filtering

    func testOwnAccountAndGroupsAreIgnored() {
        var tracker = LastSeenTracker()
        XCTAssertFalse(tracker.apply(presence("tablet", available: true, contact: me), account: me, isContact: true, now: start))
        XCTAssertNil(tracker.lastSeen(for: me))
        XCTAssertFalse(tracker.apply(presence("phone", available: true), account: me, isContact: false, now: start), "groups")
        XCTAssertNil(tracker.lastSeen(for: alex))
    }

    // MARK: Asking

    func testNothingIsAskedBeforeTheRosterIsKnown() {
        var tracker = LastSeenTracker()
        XCTAssertEqual(tracker.askStep(for: alex, now: start), .nothing)
    }

    func testSubscribeOncePerConnection() {
        var tracker = loaded()
        XCTAssertEqual(tracker.askStep(for: alex, now: start), .subscribe)
        XCTAssertEqual(tracker.askStep(for: alex, now: start + 600), .nothing)
        tracker.resetConnection()
        tracker.applyRoster([], replacesAll: true)
        XCTAssertEqual(tracker.askStep(for: alex, now: start + 700), .subscribe, "a new connection may ask again")
    }

    func testAPendingRequestIsNotRepeated() {
        var tracker = loaded([XMPPRosterItem(jid: alex, subscription: .none, askPending: true)])
        XCTAssertEqual(tracker.askStep(for: alex, now: start), .nothing)
        tracker.applyRoster([XMPPRosterItem(jid: alex, subscription: .from, askPending: true)], replacesAll: false)
        XCTAssertEqual(tracker.askStep(for: alex, now: start), .nothing)
    }

    func testLastActivityIsQueriedAtMostOnceAMinuteWhileNothingIsAvailable() {
        var tracker = loaded([XMPPRosterItem(jid: alex, subscription: .to)])
        XCTAssertEqual(tracker.askStep(for: alex, now: start), .queryLastActivity)
        XCTAssertEqual(tracker.askStep(for: alex, now: start + 59), .nothing)
        XCTAssertEqual(tracker.askStep(for: alex, now: start + 60), .queryLastActivity)
        tracker.apply(presence("phone", available: true), account: me, isContact: true, now: start + 61)
        XCTAssertEqual(tracker.askStep(for: alex, now: start + 200), .nothing, "an available contact needs no query")
    }

    func testRosterPushesUpdateAndRemove() {
        var tracker = loaded([XMPPRosterItem(jid: alex, subscription: .none, askPending: true)])
        tracker.applyRoster([XMPPRosterItem(jid: alex, subscription: .both)], replacesAll: false)
        XCTAssertTrue(tracker.holdsSubscription(to: alex))
        XCTAssertEqual(tracker.sharingWith, [alex])
        tracker.applyRoster([XMPPRosterItem(jid: alex, subscription: .remove)], replacesAll: false)
        XCTAssertNil(tracker.roster[alex])
        XCTAssertTrue(tracker.sharingWith.isEmpty)
    }

    // MARK: Subscription policy

    func testSharingApprovesChatContactsAndAsksBackOnce() {
        var tracker = loaded()
        XCTAssertEqual(tracker.answerSubscribe(from: alex, sharesLastSeen: true, isDirectChat: true), .approve(alsoSubscribe: true))
        XCTAssertEqual(tracker.answerSubscribe(from: alex, sharesLastSeen: true, isDirectChat: true), .approve(alsoSubscribe: false))
        XCTAssertEqual(tracker.askStep(for: alex, now: start), .nothing, "asking back counts as this connection's subscribe")
    }

    func testSharingLeavesStrangersPending() {
        var tracker = loaded()
        XCTAssertEqual(tracker.answerSubscribe(from: "stranger@x", sharesLastSeen: true, isDirectChat: false), .leavePending)
    }

    func testNotSharingDeniesEveryone() {
        var tracker = loaded()
        XCTAssertEqual(tracker.answerSubscribe(from: alex, sharesLastSeen: false, isDirectChat: true), .deny)
        XCTAssertEqual(tracker.answerSubscribe(from: "stranger@x", sharesLastSeen: false, isDirectChat: false), .deny)
    }
}
