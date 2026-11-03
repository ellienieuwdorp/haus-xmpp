import Foundation

enum TimelineItems {
    // The NUL keeps these apart from stored message IDs, which never contain one.
    static let typingID = "typing\u{0}"
    static let loadingEarlierID = "loading-earlier\u{0}"

    // The store supplies unique IDs; dropping repeats keeps a caller from crashing a diffable apply.
    static func rows(for messages: [TimelineMessage]) -> [TimelineRow] {
        var seen = Set<String>()
        return TimelineRow.rows(for: messages.filter { seen.insert($0.id).inserted })
    }

    static func identifiers(rows: [TimelineRow], loadingEarlier: Bool, typing: Bool) -> [String] {
        (loadingEarlier ? [loadingEarlierID] : []) + rows.map(\.message.id) + (typing ? [typingID] : [])
    }

    static func reconfigured(rows: [TimelineRow], previous: [String: TimelineRow], accentChanged: Bool,
                             typingChangedInPlace: Bool) -> [String] {
        var changed = rows.compactMap { row -> String? in
            guard let old = previous[row.message.id], old != row || accentChanged else { return nil }
            return row.message.id
        }
        if typingChangedInPlace { changed.append(typingID) }
        return changed
    }
}
