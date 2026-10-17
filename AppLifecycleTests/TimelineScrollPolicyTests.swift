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

    /// Older history is asked for a few screens before the oldest loaded message. That only the reader's own scroll
    /// asks is the caller's part, checked in `TimelinePositionTests`.
    func testOlderHistoryIsAskedForAFewScreensBeforeTheOldestMessage() {
        // Measured from the top inset: at offset -100 the oldest loaded message sits right under a 100 pt bar.
        func asks(atOffset offset: CGFloat) -> Bool {
            TimelineScrollPolicy.requestsOlderHistory(in: TimelineViewport(offset: offset, height: 800, contentHeight: 20_000, insetTop: 100, insetBottom: 60))
        }
        XCTAssertTrue(asks(atOffset: -100))
        XCTAssertTrue(asks(atOffset: 1099))
        XCTAssertFalse(asks(atOffset: 1100))
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

/// The desktop timeline's decisions: paging lead and requests, the reader's row, placement through a scroll to a row,
/// the jump button and the floating day chip.
final class DesktopTimelineScrollPolicyTests: XCTestCase {
    private typealias Policy = TimelineScrollPolicy
    private typealias Placed = TimelineScrollPolicy.PlacedRow

    /// Two screens ahead, never less than the iPhone's lead.
    func testThePagingLeadGrowsWithTheViewport() {
        XCTAssertEqual(Policy.olderHistoryLead(viewportHeight: 400), 1200)
        XCTAssertEqual(Policy.olderHistoryLead(viewportHeight: 900), 1800)
    }

    func testOlderHistoryIsAskedOneRequestAtATimeWhileTheReaderIsInTheLead() {
        var requests = Policy.OlderHistoryRequests()
        // Opening the chat or jumping programmatically near the top never pages.
        XCTAssertFalse(requests.shouldRequest(oldestID: "m100", distanceFromTop: 0, viewportHeight: 700, byReader: false))
        XCTAssertTrue(requests.shouldRequest(oldestID: "m100", distanceFromTop: 1300, viewportHeight: 700, byReader: true))
        XCTAssertFalse(requests.shouldRequest(oldestID: "m100", distanceFromTop: 600, viewportHeight: 700, byReader: true))
        // A page landed: the reader's next scroll inside the lead asks again.
        XCTAssertFalse(requests.finished(oldestID: "m50", broughtOlder: true, mayBringMore: true))
        XCTAssertTrue(requests.shouldRequest(oldestID: "m50", distanceFromTop: 900, viewportHeight: 700, byReader: true))
        // Nothing loaded, nothing to page from.
        var empty = Policy.OlderHistoryRequests()
        XCTAssertFalse(empty.shouldRequest(oldestID: nil, distanceFromTop: 0, viewportHeight: 700, byReader: true))
    }

    /// A window raised over a store with no older messages brings nothing, but the archive behind it may: the request
    /// is repeated once at once rather than waiting for the reader to leave the lead.
    func testARequestThatBroughtNothingButMayBringMoreIsRepeatedOnce() {
        var requests = Policy.OlderHistoryRequests()
        XCTAssertTrue(requests.shouldRequest(oldestID: "m1", distanceFromTop: 0, viewportHeight: 700, byReader: true))
        XCTAssertTrue(requests.finished(oldestID: "m1", broughtOlder: false, mayBringMore: true))
        XCTAssertFalse(requests.shouldRequest(oldestID: "m1", distanceFromTop: 0, viewportHeight: 700, byReader: true), "still in flight")
        // The repeat started an archive fetch whose pages land later; the reader's scrolling asks again meanwhile.
        XCTAssertFalse(requests.finished(oldestID: "m1", broughtOlder: false, mayBringMore: true))
        XCTAssertTrue(requests.shouldRequest(oldestID: "m1", distanceFromTop: 0, viewportHeight: 700, byReader: true))
    }

    /// Exhausted history is not asked again from the same oldest message until the reader leaves the lead and comes
    /// back, so an archive that failed earlier gets another try.
    func testExhaustedHistoryIsAskedAgainOnlyAfterLeavingTheLead() {
        var requests = Policy.OlderHistoryRequests()
        XCTAssertTrue(requests.shouldRequest(oldestID: "m1", distanceFromTop: 0, viewportHeight: 700, byReader: true))
        XCTAssertFalse(requests.finished(oldestID: "m1", broughtOlder: false, mayBringMore: false))
        XCTAssertFalse(requests.shouldRequest(oldestID: "m1", distanceFromTop: 0, viewportHeight: 700, byReader: true))
        XCTAssertFalse(requests.shouldRequest(oldestID: "m1", distanceFromTop: 1500, viewportHeight: 700, byReader: true))
        XCTAssertTrue(requests.shouldRequest(oldestID: "m1", distanceFromTop: 1000, viewportHeight: 700, byReader: true))
    }

    func testTheJumpButtonShowsOnceHalfAScreenAboveTheNewest() {
        XCTAssertFalse(Policy.showsJumpToNewest(distanceFromBottom: 0, viewportHeight: 700))
        XCTAssertFalse(Policy.showsJumpToNewest(distanceFromBottom: 350, viewportHeight: 700))
        XCTAssertTrue(Policy.showsJumpToNewest(distanceFromBottom: 351, viewportHeight: 700))
        // A short window still waits until the reader is past the near-bottom distance.
        XCTAssertFalse(Policy.showsJumpToNewest(distanceFromBottom: 70, viewportHeight: 100))
    }

    func testTheReaderIsTheFirstMessageWhoseTopIsOnScreen() {
        let rows = [Placed(id: TimelineItems.loadingEarlierID, index: -1, top: 10, bottom: 54, dayHeader: nil),
                    Placed(id: "a", index: 0, top: -30, bottom: 20, dayHeader: nil),
                    Placed(id: "b", index: 1, top: 20, bottom: 70, dayHeader: nil)]
        XCTAssertEqual(Policy.readerRow(rows, visibleTop: 0, visibleBottom: 700)?.id, "b")
        XCTAssertNil(Policy.readerRow(Array(rows.prefix(1)), visibleTop: 0, visibleBottom: 700))
    }

    /// Inside a message taller than the screen no top edge is visible: that message is held, at its negative offset.
    func testTheReaderInsideATallMessageIsThatMessage() {
        let rows = [Placed(id: "a", index: 0, top: -900, bottom: -200, dayHeader: nil),
                    Placed(id: "b", index: 1, top: -200, bottom: 1200, dayHeader: nil),
                    Placed(id: "c", index: 2, top: 1200, bottom: 1260, dayHeader: nil)]
        XCTAssertEqual(Policy.readerRow(rows, visibleTop: 0, visibleBottom: 600), rows[1])
    }

    /// A scroll to a row lines up the same unit point of the row and the frame, and that point stays inside 0…1.
    func testPlacementAnchorsAndTheirReach() throws {
        let y = try XCTUnwrap(Policy.anchorY(placingTopAt: 120, rowHeight: 60, frameHeight: 700))
        XCTAssertEqual(y * (700 - 60), 120, accuracy: 0.001)
        XCTAssertNil(Policy.anchorY(placingTopAt: 0, rowHeight: 700, frameHeight: 700))
        XCTAssertEqual(Policy.reachableTop(-40, rowHeight: 60, frameHeight: 700), 0)
        XCTAssertEqual(Policy.reachableTop(680, rowHeight: 60, frameHeight: 700), 640)
        XCTAssertEqual(Policy.reachableTop(300, rowHeight: 60, frameHeight: 700), 300)
        // Taller than the frame: the frame stays inside the row.
        XCTAssertEqual(Policy.reachableTop(50, rowHeight: 900, frameHeight: 700), 0)
        XCTAssertEqual(Policy.reachableTop(-500, rowHeight: 900, frameHeight: 700), -200)
    }

    /// Page Up and Page Down move through the row that carries the content furthest: below a message taller than the
    /// screen that is the tall message, which a scroll to the short row under it could move only a few points.
    func testAScrollStepGoesThroughTheRowThatCarriesItFurthest() throws {
        let tall = Placed(id: "tall", index: 0, top: -2450, bottom: 550, dayHeader: nil)
        let short = Placed(id: "short", index: 1, top: 550, bottom: 600, dayHeader: nil)
        let up = try XCTUnwrap(Policy.scrollStep([tall, short], by: 560, frameHeight: 600))
        XCTAssertEqual(up.row, tall)
        XCTAssertEqual(up.top, -1890)
        // Down, the tall message would have to leave the frame uncovered: only the short row moves, by what it can.
        let down = try XCTUnwrap(Policy.scrollStep([tall, short], by: -560, frameHeight: 600))
        XCTAssertEqual(down.row, short)
        XCTAssertEqual(down.top, 0)
        // A row laid out off screen would jump to the edge, further than asked.
        let above = Placed(id: "above", index: 0, top: -1500, bottom: -1450, dayHeader: nil)
        XCTAssertNil(Policy.scrollStep([above], by: 560, frameHeight: 600))
    }

    func testAMovePastTheLaidOutRowsLandsOnTheRowItBringsToTheTopEdge() {
        // Rows 80 to 95 laid out, 50 pt each, row 82 at the top edge of a 600 pt frame; row 79 is 120 pt.
        let laidOut = (80...95).map { Placed(id: "m\($0)", index: $0, top: CGFloat($0 - 82) * 50, bottom: CGFloat($0 - 81) * 50, dayHeader: nil) }
        func landing(_ delta: CGFloat, rowCount: Int = 200) -> Policy.Landing? {
            Policy.landing(laidOut, by: delta, frameHeight: 600, rowCount: rowCount, lead: 12, tail: 12) { $0 == 79 ? 120 : 50 }
        }
        // Up: row 24 was 2,970 pt above the top edge (row 79 is 70 pt taller than the rest), so 3,000 pt bring it to 30.
        XCTAssertEqual(landing(3000), .row(index: 24, top: 30))
        // As far as the oldest row, inside the content's lead, and past it.
        XCTAssertEqual(landing(4175), .row(index: 0, top: 5))
        XCTAssertEqual(landing(10_000), .start)
        // Down: row 142 was 3,000 pt below the top edge.
        XCTAssertEqual(landing(-3000), .row(index: 142, top: 0))
        // With 150 rows, eight rows and the tail cannot fill the frame below it; with 140, the move passes the newest.
        XCTAssertEqual(landing(-3000, rowCount: 150), .end)
        XCTAssertEqual(landing(-3000, rowCount: 140), .end)
        // A laid-out row lands at the top edge: a step through it is exact.
        XCTAssertNil(landing(100))
        XCTAssertNil(landing(-300))
    }

    /// A message taller than the frame can cover it with no row starting on screen: the move lands inside that message,
    /// at the offset the distance gives it, rather than on the row below it, which a scroll could only bring to the edge.
    func testAMoveIntoATallMessageLandsInsideIt() {
        // Rows 90 to 105 laid out, 50 pt each, row 90 at −100; rows 79 and 120 are 3,000 pt.
        let laidOut = (90...105).map { Placed(id: "m\($0)", index: $0, top: CGFloat($0 - 92) * 50, bottom: CGFloat($0 - 91) * 50, dayHeader: nil) }
        func landing(_ delta: CGFloat) -> Policy.Landing? {
            Policy.landing(laidOut, by: delta, frameHeight: 600, rowCount: 200, lead: 12, tail: 12) { $0 == 79 || $0 == 120 ? 3000 : 50 }
        }
        // Up: row 79's top was 3,600 pt above the top edge; it reaches 2,400 pt below it.
        XCTAssertEqual(landing(3000), .row(index: 79, top: -600))
        // Down: row 120's top was 1,400 pt below the top edge.
        XCTAssertEqual(landing(-3000), .row(index: 120, top: -1600))
        // A laid-out message still covering the frame after the move: a step through it is exact.
        let tall = [Placed(id: "a", index: 0, top: 0, bottom: 50, dayHeader: nil), Placed(id: "b", index: 1, top: 50, bottom: 3050, dayHeader: nil)]
        XCTAssertNil(Policy.landing(tall, by: -1000, frameHeight: 600, rowCount: 10, lead: 12, tail: 12) { _ in 50 })
    }

    func testARowNotMeasuredIsWhereTheStackEstimatesIt() {
        // 100 rows; the newest ten measured at 50 pt, the other 90 sharing 6,312 − 24 − 500 = 5,788 pt.
        let heights: [CGFloat?] = Array(repeating: nil, count: 90) + Array(repeating: 50, count: 10)
        func top(_ index: Int) -> CGFloat { Policy.contentTop(of: index, heights: heights, contentHeight: 6_312, lead: 12, tail: 12) }
        XCTAssertEqual(top(0), 12)
        XCTAssertEqual(top(45), 12 + 45 * 5_788 / 90, accuracy: 0.001)
        XCTAssertEqual(top(95), 12 + 5_788 + 250, accuracy: 0.001)
        // Every row measured: their own heights.
        XCTAssertEqual(Policy.contentTop(of: 3, heights: [40, 60, 80, 20], contentHeight: 999, lead: 12, tail: 12), 192)
    }

    func testTheDayChipShowsTheDayAboveTheScreenAndIsPushedByTheNext() throws {
        let headers: [Int: String] = [0: "Monday", 40: "Tuesday"]
        func chip(_ rows: [Placed]) -> Policy.DayChip? {
            Policy.dayChip(rows: rows, dayHeader: { headers[$0] }, line: 8, headerTop: 12, chipHeight: 24)
        }
        // The top of history: the first header has not passed the line yet.
        XCTAssertNil(chip([Placed(id: "m0", index: 0, top: 0, bottom: 90, dayHeader: "Monday")]))
        // Its header passed the line: the chip takes over the day.
        XCTAssertEqual(chip([Placed(id: "m0", index: 0, top: -20, bottom: 70, dayHeader: "Monday")])?.text, "Monday")
        // A day that started above the screen.
        let resting = try XCTUnwrap(chip([Placed(id: "m30", index: 30, top: -10, bottom: 40, dayHeader: nil),
                                          Placed(id: "m31", index: 31, top: 40, bottom: 90, dayHeader: nil)]))
        XCTAssertEqual(resting, Policy.DayChip(text: "Monday", top: 8, opacity: 1))
        // The next day's header arriving pushes the chip up and fades it.
        let pushed = try XCTUnwrap(chip([Placed(id: "m39", index: 39, top: -40, bottom: 20, dayHeader: nil),
                                         Placed(id: "m40", index: 40, top: 20, bottom: 110, dayHeader: "Tuesday")]))
        XCTAssertEqual(pushed.text, "Monday")
        XCTAssertEqual(pushed.top, 20 + 12 - 6 - 24)
        XCTAssertEqual(pushed.opacity, 1 - 6.0 / 24, accuracy: 0.001)
        // That header still below the line shows Tuesday itself; the chip keeps Monday.
        XCTAssertEqual(chip([Placed(id: "m40", index: 40, top: 30, bottom: 120, dayHeader: "Tuesday")])?.text, "Monday")
    }
}
