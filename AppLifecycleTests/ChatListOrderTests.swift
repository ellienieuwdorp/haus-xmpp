import XCTest
@testable import HausXMPP

// The iPhone list, the Mac sidebar and the Mac's Go to Chat (⌘1 to ⌘9) share this order.
final class ChatListOrderTests: XCTestCase {
    private func chat(_ id: String, pinned: Bool = false, at minutes: Double?) -> ChatSummary {
        ChatSummary(id: id, title: id, preview: "", isPinned: pinned, lastMessageAt: minutes.map { Date(timeIntervalSince1970: $0 * 60) })
    }

    func testPinnedFirstThenNewestWithTiesInStoreOrder() {
        let chats = [chat("old", at: 1), chat("quiet", at: nil), chat("pinnedOld", pinned: true, at: 2), chat("new", at: 9),
                     chat("tieA", at: 5), chat("pinnedNew", pinned: true, at: 8), chat("tieB", at: 5)]
        XCTAssertEqual(ChatListOrder.sorted(chats).map(\.id), ["pinnedNew", "pinnedOld", "new", "tieA", "tieB", "old", "quiet"])
    }

    func testNeighbourWrapsAroundAndStartsAtAnEnd() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(ChatListOrder.neighbour(of: "a", in: ids, forward: true), "b")
        XCTAssertEqual(ChatListOrder.neighbour(of: "c", in: ids, forward: true), "a")
        XCTAssertEqual(ChatListOrder.neighbour(of: "a", in: ids, forward: false), "c")
        XCTAssertEqual(ChatListOrder.neighbour(of: "b", in: ids, forward: false), "a")
        // Nothing selected, or a chat no longer listed: the first going forward, the last going back.
        XCTAssertEqual(ChatListOrder.neighbour(of: nil, in: ids, forward: true), "a")
        XCTAssertEqual(ChatListOrder.neighbour(of: "gone", in: ids, forward: false), "c")
        XCTAssertEqual(ChatListOrder.neighbour(of: "a", in: ["a"], forward: true), "a")
        XCTAssertNil(ChatListOrder.neighbour(of: nil, in: [], forward: true))
    }

    func testRowTimesAreShortOnScreenAndLongForVoiceOver() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        let locale = Locale(identifier: "en_GB"), now = Date(timeIntervalSince1970: 1_790_582_400) // Monday 28 September 2026, 10:00
        let cases: [(seconds: TimeInterval, visible: String, spoken: String, line: UInt)] = [
            (1_790_577_000, "08:30", "08:30", #line),
            (1_790_510_700, "Yesterday", "Yesterday at 14:05", #line),
            (1_790_330_400, "Fri", "Friday", #line),
            (1_789_984_800, "21/09", "21 September", #line),
            (1_763_722_800, "21/11", "21 November 2025", #line),
        ]
        for c in cases {
            let date = Date(timeIntervalSince1970: c.seconds)
            XCTAssertEqual(ChatRow.timeLabel(date, now: now, calendar: calendar, locale: locale), c.visible, line: c.line)
            XCTAssertEqual(ChatRow.timeLabel(date, now: now, calendar: calendar, locale: locale, spoken: true), c.spoken, line: c.line)
        }
    }
}
