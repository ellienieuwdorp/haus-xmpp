import Foundation

/// What the chat header says about a 1:1 contact's activity. In memory only; nil means unknown and leaves the header
/// showing just the name.
enum LastSeen: Equatable {
    case online
    case lastSeen(Date)

    /// The header subtitle, relative to `now` in `calendar` (its locale and time zone format the time and day).
    static func label(_ state: LastSeen, now: Date, calendar: Calendar) -> String {
        guard case .lastSeen(let date) = state else { return "Online" }
        if now.timeIntervalSince(date) < 60 { return "Last seen just now" }
        let locale = calendar.locale ?? .current
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
        switch days {
        case 0: return "Last seen today at \(time)"
        case 1: return "Last seen yesterday at \(time)"
        case 2...6: return "Last seen \(date.formatted(style.weekday(.wide))) at \(time)"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let day = style.day().month(.abbreviated)
            return "Last seen \(date.formatted(sameYear ? day : day.year()))"
        }
    }
}
