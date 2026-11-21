import Foundation

/// Names when a late message was sent, since the system dates a notification by its delivery. Past `delay` the body
/// starts with the time, or the date and time when not today, in the locale's 12- or 24-hour form.
public struct NotificationSentTime: Sendable {
    public static let delay: TimeInterval = 5 * 60
    public let now: Date
    public let locale: Locale
    public let timeZone: TimeZone

    public init(now: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        self.now = now; self.locale = locale; self.timeZone = timeZone
    }

    func at(_ now: Date) -> NotificationSentTime { NotificationSentTime(now: now, locale: locale, timeZone: timeZone) }

    func prefix(sentAt: Date) -> String {
        guard now.timeIntervalSince(sentAt) > Self.delay else { return "" }
        var calendar = locale.calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        // `j` is the locale's hour, so it follows the 12- or 24-hour setting.
        let template = calendar.isDate(sentAt, inSameDayAs: now) ? "jmm"
            : calendar.isDate(sentAt, equalTo: now, toGranularity: .year) ? "MMMdjmm" : "yMMMdjmm"
        formatter.setLocalizedDateFormatFromTemplate(template)
        return "Sent " + formatter.string(from: sentAt) + " · "
    }
}
