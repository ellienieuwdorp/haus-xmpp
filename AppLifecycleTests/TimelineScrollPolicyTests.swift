import XCTest
@testable import HausXMPP

/// The scrolling decisions on their own. `TimelinePositionTests` and `TimelineOffsetTests` check that the iPhone's
/// controller carries them out; these cover the cases that are slow or fiddly to stage in a real collection view.
final class TimelineScrollPolicyTests: XCTestCase {
    private typealias Update = TimelineScrollPolicy.Update

    private func rows(_ ids: [String], outgoing: Set<String> = []) -> [TimelineRow] {
        TimelineItems.rows(for: ids.map { TimelineMessage(id: $0, body: $0, isOutgoing: outgoing.contains($0), isStarred: false) })
    }

    private func update(from tail: String?, to ids: [String], outgoing: Set<String> = [], nearBottom: Bool, typingChanged: Bool = false,
                        typingLeft: Bool = false, canAnimate: Bool = true) -> Update {
        Update(previousTailID: tail, rows: rows(ids, outgoing: outgoing), wasNearBottom: nearBottom,
               typingChanged: typingChanged, typingLeft: typingLeft, canAnimate: canAnimate)
    }

    func testEachUpdateFollowsTheBottomOnlyWhenTheReaderWasThereOrSent() {
        let cases: [(update: Update, placement: Update.Placement, follows: Bool, line: UInt)] = [
            // A chat opens at its newest message, wherever the list was.
            (update(from: nil, to: ["a", "b"], nearBottom: false), .newestAtOnce, true, #line),
            // A peer's message at the tail slides in for a reader at the bottom, and jumps when nothing may animate.
            (update(from: "b", to: ["a", "b", "c"], nearBottom: true), .slideToNewest, true, #line),
            (update(from: "b", to: ["a", "b", "c"], nearBottom: true, canAnimate: false), .followNewest, true, #line),
            // Up in history the reader stays put, unless the new message is their own.
            (update(from: "b", to: ["a", "b", "c"], nearBottom: false), .keepAnchor, false, #line),
            (update(from: "b", to: ["a", "b", "c"], outgoing: ["c"], nearBottom: false), .followNewest, true, #line),
            // An older page arriving at the top is not an arrival, even for a reader at the bottom.
            (update(from: "b", to: ["y", "z", "a", "b"], nearBottom: false), .keepAnchor, false, #line),
            (update(from: "b", to: ["y", "z", "a", "b"], nearBottom: true), .followNewest, true, #line),
            // The loaded window is the newest N: its head drops as the tail grows, and that is still an arrival.
            (update(from: "c", to: ["b", "c", "d"], nearBottom: true), .slideToNewest, true, #line),
            // Typing coming or going at the tail moves like a message.
            (update(from: "b", to: ["a", "b"], nearBottom: true, typingChanged: true), .slideToNewest, true, #line),
            // A status tick or star changes no position.
            (update(from: "b", to: ["a", "b"], nearBottom: false), .keepAnchor, false, #line),
            // The previous newest message is gone (another chat's window): nothing counts as appended.
            (update(from: "gone", to: ["a", "b"], outgoing: ["b"], nearBottom: false), .keepAnchor, false, #line),
        ]
        for (update, placement, follows, line) in cases {
            XCTAssertEqual(update.placement, placement, line: line)
            XCTAssertEqual(update.follows, follows, line: line)
        }
    }

    /// The typing bubble leaving shrinks the content and clamps the offset during the apply, so its slide back down
    /// plays from where the list was; a message arriving as it leaves slides from wherever the apply left it.
    func testTheTypingBubbleLeavingSlidesFromThePreviousOffset() {
        XCTAssertTrue(update(from: "b", to: ["a", "b"], nearBottom: true, typingChanged: true, typingLeft: true).slidesFromPreviousOffset)
        XCTAssertFalse(update(from: "b", to: ["a", "b", "c"], nearBottom: true, typingChanged: true, typingLeft: true).slidesFromPreviousOffset)
    }

    func testAReaderLeftInHistoryFollowsAgainOnceBackNearTheBottom() {
        let stayed = update(from: "b", to: ["a", "b", "c"], nearBottom: false)
        XCTAssertFalse(stayed.followsAfterwards(isNearBottom: false))
        XCTAssertTrue(stayed.followsAfterwards(isNearBottom: true))
    }

    /// Older history is asked for a few screens before the oldest loaded message, and only by the reader's own scroll.
    func testOnlyTheReadersScrollNearTheTopAsksForOlderHistory() {
        XCTAssertTrue(TimelineScrollPolicy.requestsOlderHistory(readerScrolling: true, distanceFromTop: 0))
        XCTAssertTrue(TimelineScrollPolicy.requestsOlderHistory(readerScrolling: true, distanceFromTop: 1199))
        XCTAssertFalse(TimelineScrollPolicy.requestsOlderHistory(readerScrolling: true, distanceFromTop: 1200))
        XCTAssertFalse(TimelineScrollPolicy.requestsOlderHistory(readerScrolling: false, distanceFromTop: 0))
    }

    func testTheViewportClampsToItsContentAndKnowsTheBottom() {
        let viewport = TimelineViewport(offset: 900, height: 800, contentHeight: 2000, insetTop: 100, insetBottom: 60)
        XCTAssertEqual(viewport.clamped(-500), -100)
        XCTAssertEqual(viewport.clamped(.greatestFiniteMagnitude), 1260)
        XCTAssertFalse(viewport.isNearBottom, "360 pt above the end")
        XCTAssertTrue(TimelineViewport(offset: 1181, height: 800, contentHeight: 2000, insetTop: 100, insetBottom: 60).isNearBottom)
        // Content shorter than the screen rests at the top.
        XCTAssertEqual(TimelineViewport(offset: 0, height: 800, contentHeight: 300, insetTop: 100, insetBottom: 60).clamped(400), -100)
        XCTAssertFalse(TimelineScrollPolicy.canAnchor(on: TimelineItems.loadingEarlierID))
        XCTAssertTrue(TimelineScrollPolicy.canAnchor(on: "m1"))
    }

    /// The loading cell first, the typing bubble last, and a repeated ID listed once.
    func testItemsListTheLoadingCellMessagesAndTypingInOrder() {
        let rows = TimelineItems.rows(for: ["a", "b", "a"].map { TimelineMessage(id: $0, body: $0, isOutgoing: false, isStarred: false) })
        XCTAssertEqual(TimelineItems.identifiers(rows: rows, loadingEarlier: true, typing: true),
                       [TimelineItems.loadingEarlierID, "a", "b", TimelineItems.typingID])
        XCTAssertEqual(TimelineItems.identifiers(rows: rows, loadingEarlier: false, typing: false), ["a", "b"])
    }
}
