import XCTest
@testable import HausXMPP

final class LastSeenTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()

    /// Friday 25 September 2026, 14:00 in Amsterdam.
    private var now: Date { date(2026, 9, 25, 14, 0) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private func label(_ state: LastSeen) -> String { LastSeen.label(state, now: now, calendar: calendar) }

    func testUnderAMinuteIsJustNow() {
        XCTAssertEqual(label(.lastSeen(date(2026, 9, 25, 13, 59, 1))), "Last seen just now")
        XCTAssertEqual(label(.lastSeen(now)), "Last seen just now")
        XCTAssertEqual(label(.lastSeen(now.addingTimeInterval(30))), "Last seen just now", "a clock ahead of ours is not the future")
        XCTAssertEqual(label(.lastSeen(date(2026, 9, 25, 13, 59, 0))), "Last seen today at 13:59")
    }

    func testOlderShowsTheDate() {
        XCTAssertEqual(label(.lastSeen(date(2026, 9, 18, 23, 0))), "Last seen 18 Sep")
        XCTAssertEqual(label(.lastSeen(date(2026, 9, 12, 10, 31))), "Last seen 12 Sep")
        XCTAssertEqual(label(.lastSeen(date(2025, 12, 30, 10, 31))), "Last seen 30 Dec 2025")
    }

    /// Days are counted in the calendar's time zone: 23:30 UTC on the 24th is already the 25th in Amsterdam.
    func testDaysFollowTheCalendarTimeZone() {
        var components = DateComponents(year: 2026, month: 9, day: 24, hour: 23, minute: 30)
        components.timeZone = TimeZone(identifier: "UTC")!
        let seen = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(label(.lastSeen(seen)), "Last seen today at 01:30")
    }
}
