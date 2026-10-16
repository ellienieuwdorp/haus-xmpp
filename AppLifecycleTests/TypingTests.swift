import XCTest
import XMPPProtocol
@testable import HausXMPP

final class TypingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testComposingExpiresWithoutARefresh() {
        var tracker = TypingTracker()
        tracker.apply(.composing, chat: "alex@x", participant: "alex@x", now: start)
        XCTAssertEqual(tracker.typing, ["alex@x": ["alex@x"]])
        tracker.apply(.composing, chat: "alex@x", participant: "alex@x", now: start + 10)
        tracker.expire(now: start + 20)
        XCTAssertEqual(tracker.typing, ["alex@x": ["alex@x"]], "a refresh extends it")
        XCTAssertEqual(tracker.nextExpiry, start + 10 + TypingTracker.composingLifetime)
        tracker.expire(now: start + 10 + TypingTracker.composingLifetime)
        XCTAssertEqual(tracker.typing, [:])
        XCTAssertNil(tracker.nextExpiry)
    }

    func testGroupsTrackEachParticipant() {
        var tracker = TypingTracker()
        tracker.apply(.composing, chat: "room@x", participant: "sam@x", now: start)
        tracker.apply(.composing, chat: "room@x", participant: "maya@x", now: start)
        XCTAssertEqual(tracker.typing, ["room@x": ["maya@x", "sam@x"]])
        tracker.apply(.paused, chat: "room@x", participant: "sam@x", now: start + 1)
        XCTAssertEqual(tracker.typing, ["room@x": ["maya@x"]])
    }

    /// A stop that came with a message stays until the load that shows the message, or briefly if that never comes.
    func testAMessageSettlesTypingUntilItIsShown() {
        var tracker = TypingTracker()
        tracker.apply(.composing, chat: "alex@x", participant: "alex@x", now: start)
        tracker.apply(.active, chat: "alex@x", participant: "alex@x", settles: true, now: start + 1)
        XCTAssertEqual(tracker.typing, ["alex@x": ["alex@x"]])
        tracker.flushSettled()
        XCTAssertEqual(tracker.typing, [:])

        tracker.apply(.composing, chat: "alex@x", participant: "alex@x", now: start)
        tracker.messageArrived(chat: "alex@x", participant: "alex@x", now: start + 1)
        tracker.expire(now: start + 1 + TypingTracker.settleLifetime)
        XCTAssertEqual(tracker.typing, [:], "falls back to a short expiry")

        // A new composing after the message is not flushed with it.
        tracker.apply(.composing, chat: "alex@x", participant: "alex@x", now: start)
        tracker.messageArrived(chat: "alex@x", participant: "alex@x", now: start + 1)
        tracker.apply(.composing, chat: "alex@x", participant: "alex@x", now: start + 2)
        tracker.flushSettled()
        XCTAssertEqual(tracker.typing, ["alex@x": ["alex@x"]])
        // A message from someone who was not typing adds nothing.
        tracker.messageArrived(chat: "maya@x", participant: "maya@x", now: start)
        XCTAssertNil(tracker.typing["maya@x"])
    }

    func testClearingAChatStopsEveryoneTypingThere() {
        var tracker = TypingTracker()
        tracker.apply(.composing, chat: "alex@x", participant: "alex@x", now: start)
        tracker.messageArrived(chat: "alex@x", participant: "alex@x", now: start + 1)
        tracker.apply(.composing, chat: "maya@x", participant: "maya@x", now: start)
        tracker.clear(chat: "alex@x")
        XCTAssertEqual(tracker.typing, ["maya@x": ["maya@x"]])
        XCTAssertEqual(tracker.nextExpiry, start + TypingTracker.composingLifetime)
    }

    func testSenderSendsComposingThrottledPausedAndActive() {
        var sender = TypingSender()
        XCTAssertNil(sender.draftChanged(isEmpty: true, now: start), "an untouched empty draft says nothing")
        XCTAssertEqual(sender.draftChanged(isEmpty: false, now: start), .composing)
        XCTAssertNil(sender.draftChanged(isEmpty: false, now: start + 3))
        XCTAssertNil(sender.draftChanged(isEmpty: false, now: start + 9.9))
        XCTAssertEqual(sender.draftChanged(isEmpty: false, now: start + 10), .composing, "a long burst is refreshed")
        XCTAssertEqual(sender.idle(), .paused)
        XCTAssertNil(sender.idle())
        XCTAssertEqual(sender.draftChanged(isEmpty: false, now: start + 16), .composing, "resuming after a pause")
        XCTAssertEqual(sender.draftChanged(isEmpty: true, now: start + 17), .active, "sent or cleared")
        XCTAssertNil(sender.draftChanged(isEmpty: true, now: start + 18))
        XCTAssertNil(sender.left(), "nothing to retract after active")
        XCTAssertEqual(sender.draftChanged(isEmpty: false, now: start + 19), .composing)
        XCTAssertEqual(sender.left(), .inactive)
        XCTAssertNil(sender.sent, "leaving starts over")
    }
}
