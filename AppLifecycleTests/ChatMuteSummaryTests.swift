import XCTest
import MessageStore
@testable import HausXMPP

final class ChatMuteSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()
    // 2026-09-28 10:00 in Amsterdam.
    private let now = Date(timeIntervalSince1970: 1_790_582_400)

    func testDurationsEndAtTheOfferedInstants() {
        XCTAssertEqual(MuteDuration.oneHour.until(from: now), now + 3_600)
        XCTAssertEqual(MuteDuration.eightHours.until(from: now), now + 8 * 3_600)
        XCTAssertEqual(MuteDuration.oneDay.until(from: now), now + 86_400)
        XCTAssertEqual(MuteDuration.oneWeek.until(from: now), now + 7 * 86_400)
        XCTAssertEqual(MuteDuration.always.until(from: now), ChatNotificationSetting.always)
        XCTAssertEqual(MuteDuration.allCases.map(\.dialogTitle), ["For 1 hour", "For 8 hours", "For 1 day", "For 1 week", "Always"])
    }

    func testAChosenEndOpensOnEightTomorrowAndMustLieAhead() {
        let tomorrowAtEight = Date(timeIntervalSince1970: 1_790_661_600)
        XCTAssertEqual(MuteEnd.suggested(now: now, calendar: calendar), tomorrowAtEight)
        XCTAssertEqual(MuteEnd.suggested(now: now - 4 * 3_600, calendar: calendar), tomorrowAtEight)
        XCTAssertEqual(MuteEnd.suggested(now: now + 13.5 * 3_600, calendar: calendar), tomorrowAtEight)
        XCTAssertTrue(MuteEnd.accepts(now + 60, now: now))
        XCTAssertFalse(MuteEnd.accepts(now, now: now))
        XCTAssertFalse(MuteEnd.accepts(now - 60, now: now))
        let chosen = ChatNotificationSetting(mutedUntil: tomorrowAtEight)
        XCTAssertTrue(chosen.isMuted(at: now))
        XCTAssertFalse(chosen.isMutedAlways)
        XCTAssertFalse(chosen.isMuted(at: tomorrowAtEight))
        XCTAssertEqual(chosen.summary(isGroup: false, now: tomorrowAtEight, calendar: calendar), "All messages")
    }

    func testSummaryNamesTheLevelOrTheMute() {
        XCTAssertEqual(ChatNotificationSetting().summary(isGroup: false, now: now, calendar: calendar), "All messages")
        XCTAssertEqual(ChatNotificationSetting(level: .mentions).summary(isGroup: true, now: now, calendar: calendar), "Mentions only")
        // A 1:1 chat never shows the group-only level.
        XCTAssertEqual(ChatNotificationSetting(level: .mentions).summary(isGroup: false, now: now, calendar: calendar), "All messages")
        XCTAssertEqual(ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always).summary(isGroup: false, now: now, calendar: calendar), "Muted")
        XCTAssertTrue(ChatNotificationSetting(mutedUntil: now + 3_600).summary(isGroup: false, now: now, calendar: calendar).hasPrefix("Muted until "))
        XCTAssertTrue(ChatNotificationSetting(mutedUntil: now + 86_400).summary(isGroup: false, now: now, calendar: calendar).hasPrefix("Muted until tomorrow, "))
        XCTAssertTrue(ChatNotificationSetting(mutedUntil: now + 120 * 86_400).summary(isGroup: false, now: now, calendar: calendar).contains("2027"))
        XCTAssertFalse(ChatNotificationSetting(mutedUntil: now + 30 * 86_400).summary(isGroup: false, now: now, calendar: calendar).contains("2026"))
        let inThreeDays = ChatNotificationSetting(mutedUntil: now + 3 * 86_400)
        XCTAssertGreaterThan(inThreeDays.summary(isGroup: false, now: now, calendar: calendar, spoken: true).count,
                             inThreeDays.summary(isGroup: false, now: now, calendar: calendar).count, "VoiceOver hears the weekday in full")
        // An expired mute reads as the level again.
        XCTAssertEqual(ChatNotificationSetting(level: .mentions, mutedUntil: now - 1).summary(isGroup: true, now: now, calendar: calendar), "Mentions only")
    }
}
