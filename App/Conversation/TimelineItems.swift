import Foundation

/// The timeline's items, top to bottom, as identifiers a diffable data source can hold: the loading-earlier cell while
/// older history is fetched, one row per message, and the typing bubble while someone types.
enum TimelineItems {
    /// The typing bubble is the last item when someone types; no stored message ID contains a NUL.
    static let typingID = "typing\u{0}"
    /// The loading-earlier cell is the first item while the model backfills this chat's archive.
    static let loadingEarlierID = "loading-earlier\u{0}"

    /// Rows for the messages, keeping the first of any repeated ID. The durable store supplies unique IDs; this keeps
    /// a caller that repeats one from crashing a diffable apply.
    static func rows(for messages: [TimelineMessage]) -> [TimelineRow] {
        var seen = Set<String>()
        return TimelineRow.rows(for: messages.filter { seen.insert($0.id).inserted })
    }

    /// Above the oldest message the loading cell; below the newest the typing bubble.
    static func identifiers(rows: [TimelineRow], loadingEarlier: Bool, typing: Bool) -> [String] {
        (loadingEarlier ? [loadingEarlierID] : []) + rows.map(\.message.id) + (typing ? [typingID] : [])
    }

    /// The items whose cells must be configured again in place: rows that changed, every row when the accent changed,
    /// and the typing bubble when who is typing changed while it stayed on screen.
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
