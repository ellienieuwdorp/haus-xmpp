import XCTest
@testable import HausXMPP

/// The desktop timeline's arrow keys: which message they focus, and how far the timeline scrolls to show it.
final class TimelineMessageFocusTests: XCTestCase {
    private let ids = ["a", "b", "c", "d", "e"]

    /// Rows laid out in a 300 pt frame: `a` above it, `b` cut by its top edge, `c` and `d` whole, `e` cut by its bottom.
    private var placed: [TimelineScrollPolicy.PlacedRow] {
        [("a", -200, -100), ("b", -40, 60), ("c", 60, 160), ("d", 160, 260), ("e", 260, 360)].enumerated().map { index, row in
            TimelineScrollPolicy.PlacedRow(id: row.0, index: index, top: row.1, bottom: row.2, dayHeader: nil)
        }
    }

    private func step(from current: String?, forward: Bool) -> String? {
        TimelineMessageFocus.step(from: current, forward: forward, ids: ids, placed: placed, frameHeight: 300)
    }

    func testTheFirstPressStartsWhereTheReaderLooks() {
        XCTAssertEqual(step(from: nil, forward: false), "d", "Up: the newest message wholly on screen")
        XCTAssertEqual(step(from: nil, forward: true), "c", "Down: the oldest message wholly on screen")
        XCTAssertEqual(step(from: "a", forward: false), "d", "a focused message scrolled out of view starts over")
        XCTAssertEqual(TimelineMessageFocus.step(from: nil, forward: false, ids: ids, placed: [], frameHeight: 300), "e",
                       "nothing laid out: the newest message")
    }

    func testFocusMovesOneMessageAndStopsAtTheEnds() {
        XCTAssertEqual(step(from: "b", forward: false), "a", "a partly visible message moves on to one off screen")
        XCTAssertEqual(step(from: "e", forward: true), "e", "the newest message stays focused")
        let oldest = TimelineScrollPolicy.PlacedRow(id: "a", index: 0, top: 10, bottom: 110, dayHeader: nil)
        XCTAssertEqual(TimelineMessageFocus.step(from: "a", forward: false, ids: ids, placed: [oldest], frameHeight: 300), "a",
                       "the oldest loaded message stays focused")
    }

    func testRevealScrollsOnlyAsFarAsNeeded() {
        XCTAssertNil(TimelineMessageFocus.revealTop(top: 60, bottom: 160, frameHeight: 300, margin: 12), "already whole")
        XCTAssertEqual(TimelineMessageFocus.revealTop(top: -40, bottom: 60, frameHeight: 300, margin: 12), 12, "above: to the top")
        XCTAssertEqual(TimelineMessageFocus.revealTop(top: 260, bottom: 360, frameHeight: 300, margin: 12), 188, "below: to the bottom")
        XCTAssertEqual(TimelineMessageFocus.revealTop(top: -500, bottom: 400, frameHeight: 300, margin: 12), 12, "too tall: its start")
        XCTAssertNil(TimelineMessageFocus.revealTop(top: 12, bottom: 900, frameHeight: 300, margin: 12), "too tall, its start in place")
    }
}
