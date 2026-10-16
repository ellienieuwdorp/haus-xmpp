import Foundation

/// Where the timeline's list is scrolled, in the scroll view's own terms: the offset of the content at the top edge,
/// and the insets the bars, banners and composer add (iOS's adjusted content insets).
struct TimelineViewport: Equatable {
    var offset: CGFloat
    var height: CGFloat
    var contentHeight: CGFloat
    var insetTop: CGFloat
    var insetBottom: CGFloat

    /// The offset at which the oldest loaded item sits under the top inset.
    var minimumOffset: CGFloat { -insetTop }
    /// The offset at which the newest item sits on the bottom inset, or the top when everything fits.
    var maximumOffset: CGFloat { max(minimumOffset, contentHeight - height + insetBottom) }
    var distanceFromTop: CGFloat { offset + insetTop }
    var isNearBottom: Bool { contentHeight + insetBottom - offset - height < TimelineScrollPolicy.nearBottomDistance }

    func clamped(_ value: CGFloat) -> CGFloat { min(maximumOffset, max(minimumOffset, value)) }
}

/// The timeline's scrolling decisions, measured on the iPhone: a chat
/// opens at the newest message, the list follows the bottom while the reader is there, an own send returns to it from
/// anywhere, and everything else keeps the message the reader is looking at where it is.
enum TimelineScrollPolicy {
    /// Within this distance of the end the reader counts as at the bottom, and new messages follow.
    static let nearBottomDistance: CGFloat = 80
    /// Older history is asked for this far above the oldest loaded message: a few screens early, so older messages
    /// are usually in place before the reader arrives.
    static let olderHistoryLead: CGFloat = 1200

    /// Whether the list has come close enough to the oldest loaded message to ask for older history. Ask only while
    /// the reader's own scroll moves it (dragging or coasting): opening at the newest message, an inset change or any
    /// other programmatic move to the top never pages.
    static func requestsOlderHistory(in viewport: TimelineViewport) -> Bool {
        viewport.distanceFromTop < olderHistoryLead
    }

    /// The item the reader's position is kept on across an update: never the loading-earlier cell, whose removal
    /// would otherwise drop the reader by its height.
    static func canAnchor(on id: String?) -> Bool { id != TimelineItems.loadingEarlierID }

    /// The offset that puts the anchored item back at the distance from the top edge it had before the update.
    static func offsetKeepingAnchor(itemTop: CGFloat, distanceFromTop: CGFloat, in viewport: TimelineViewport) -> CGFloat {
        viewport.clamped(itemTop - distanceFromTop)
    }

    /// While the reader is in history and the composer or keyboard changes the bottom inset, the same messages stay
    /// above it instead of being covered or uncovered. `bottomEdge` is the content position that was at the visible
    /// bottom edge.
    static func offsetKeepingBottomEdge(_ bottomEdge: CGFloat, bottomInset: CGFloat, in viewport: TimelineViewport) -> CGFloat {
        viewport.clamped(bottomEdge - viewport.height + bottomInset)
    }

    /// What one content update does to the scroll position. Decided before the update is applied, from the rows it
    /// brings and where the reader was.
    struct Update: Equatable {
        enum Placement: Equatable {
            /// Nothing was shown yet: land on the newest message at once, without animation.
            case newestAtOnce
            /// A message or the typing bubble came or went at the tail while the reader was there: slide to the new end.
            case slideToNewest
            /// Jump to the newest message: the reader was at the bottom (and nothing may animate) or sent a message.
            case followNewest
            /// Keep the first visible message at the same distance from the top edge.
            case keepAnchor
        }

        let placement: Placement
        /// Whether this update follows the bottom; afterwards the list follows it while this holds or it ends near it.
        let follows: Bool
        /// The slide plays back from where the list was before the apply, not from where the apply left it: the typing
        /// bubble left without a message taking its place, and the shrinking content clamped the offset meanwhile.
        let slidesFromPreviousOffset: Bool

        /// - Parameters:
        ///   - previousTailID: the newest message shown before this update; nil when nothing was.
        ///   - rows: the rows this update shows.
        ///   - wasNearBottom: the reader was at the bottom before the update.
        ///   - typingChanged: the typing bubble came, went or changed who it shows.
        ///   - typingLeft: the typing bubble went.
        ///   - canAnimate: the timeline is on screen and Reduce Motion is off.
        init(previousTailID: String?, rows: [TimelineRow], wasNearBottom: Bool, typingChanged: Bool, typingLeft: Bool, canAnimate: Bool) {
            // Judged from the tail alone: the loaded window is the newest N, so its head moves as messages arrive.
            let ids = rows.map(\.message.id)
            let tailStart = previousTailID.flatMap { ids.lastIndex(of: $0) }.map { $0 + 1 } ?? ids.count
            let appended = tailStart < ids.count
            // Sending always returns to the newest message, wherever the reader was.
            let sentOwn = rows[tailStart...].contains { $0.message.isOutgoing }
            let firstContent = previousTailID == nil
            follows = firstContent || wasNearBottom || sentOwn
            slidesFromPreviousOffset = typingLeft && !appended
            // Only a message arriving at the tail moves, and only when the reader is at the tail; nothing else animates.
            // From far up in history a send jumps; a slide would cross cells that were never drawn.
            // The typing bubble coming or going at the tail moves the same way as a message arriving.
            let slides = !firstContent && (appended || typingChanged) && wasNearBottom && canAnimate
            placement = firstContent ? .newestAtOnce : slides ? .slideToNewest : follows ? .followNewest : .keepAnchor
        }

        /// Whether the list goes on following the bottom once this update has settled.
        func followsAfterwards(isNearBottom: Bool) -> Bool { follows || isNearBottom }
    }
}

/// The desktop timeline's decisions (the Mac's SwiftUI scroll view applies them). Positions are in the coordinates of
/// the scroll view's frame, which sits below the toolbar: 0 is its top edge, and content scrolled under the toolbar has
/// negative positions.
extension TimelineScrollPolicy {
    /// How far above the oldest loaded message older history is asked for in a viewport this tall: two screens, and
    /// never less than the iPhone's lead. A tall desktop window crosses a fixed 1,200 pt in a flick or two.
    static func olderHistoryLead(viewportHeight: CGFloat) -> CGFloat { max(olderHistoryLead, 2 * viewportHeight) }

    /// When to ask for older history: once each time the reader's own scroll (or a key that scrolls) enters the lead,
    /// and once more each time a page lands while it is still inside. A request that brings nothing leaves the oldest
    /// message as it was, so an exhausted history is not asked again until the reader leaves the lead and comes back.
    /// One request is in flight at a time; a burst of them would mean a page landed without the reader's row being held.
    struct OlderHistoryRequests: Equatable {
        /// The oldest loaded message when older history was last asked for.
        private(set) var askedAtOldest: String?

        init() {}

        /// Whether to ask now. `byReader` is false for programmatic moves (opening the chat, a jump to the newest
        /// message), which never page.
        mutating func shouldRequest(oldestID: String?, distanceFromTop: CGFloat, viewportHeight: CGFloat, byReader: Bool) -> Bool {
            guard distanceFromTop < TimelineScrollPolicy.olderHistoryLead(viewportHeight: viewportHeight) else {
                askedAtOldest = nil
                return false
            }
            guard byReader, let oldestID, oldestID != askedAtOldest else { return false }
            askedAtOldest = oldestID
            return true
        }
    }

    /// The jump-to-newest button shows once the reader is more than half a screen above the newest message, so it
    /// does not blink in and out while reading the last few messages.
    static func showsJumpToNewest(distanceFromBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        distanceFromBottom > max(nearBottomDistance, viewportHeight / 2)
    }

    /// A row on screen, top to bottom, as the scroll view laid it out.
    struct PlacedRow: Equatable {
        let id: String
        /// Its position in the timeline's rows, for the walk back to the start of its day.
        let index: Int
        let top: CGFloat
        let bottom: CGFloat
        /// The day header the row opens with, if it starts a day.
        let dayHeader: String?
    }

    /// The reader's row: the first message whose top edge is inside the visible area, or, when none starts there (a
    /// message taller than the area), the one reaching into it from above. Its distance from the top edge, negative in
    /// that case, is what an update or a resize keeps. Never the loading-earlier row.
    static func readerRow(_ rows: [PlacedRow], visibleTop: CGFloat, visibleBottom: CGFloat) -> PlacedRow? {
        let anchorable = rows.filter { canAnchor(on: $0.id) }
        return anchorable.first { $0.top >= visibleTop - 0.5 && $0.top < visibleBottom }
            ?? anchorable.first { $0.top < visibleBottom && $0.bottom > visibleTop }
    }

    /// The `UnitPoint.y` for a scroll-to-row that should leave the row's top edge at `top`. Scrolling to a row with an
    /// anchor lines up that unit point of the row and of the scroll view's frame: the row's top lands at
    /// `y × (frameHeight − rowHeight)`. SwiftUI clamps `y` to 0…1, so only tops from
    /// `reachableTop` can be asked for. Nil when the row is as tall as the frame, where every anchor lands alike.
    static func anchorY(placingTopAt top: CGFloat, rowHeight: CGFloat, frameHeight: CGFloat) -> CGFloat? {
        let travel = frameHeight - rowHeight
        guard abs(travel) > 1 else { return nil }
        return top / travel
    }

    /// The nearest top edge to `top` that a scroll to the row can put it at: one that keeps the row inside the frame
    /// (or, for a row taller than the frame, the frame inside the row).
    static func reachableTop(_ top: CGFloat, rowHeight: CGFloat, frameHeight: CGFloat) -> CGFloat {
        let travel = frameHeight - rowHeight
        return min(max(top, min(0, travel)), max(0, travel))
    }

    /// The floating day chip: which day it shows, where its capsule sits and how visible it is.
    struct DayChip: Equatable {
        let text: String
        /// The capsule's top edge, in the scroll view's coordinates.
        let top: CGFloat
        /// Fades out as the next day's header pushes it up under the bars.
        let opacity: CGFloat
    }

    /// The day of the message at the top of the screen, once its own header has scrolled past `line` (where the chip's
    /// capsule rests). The next day's header pushes the chip up and away as it arrives, and a header coming back down
    /// to the line takes its date back, so the chip and the inline header never show the same day twice.
    /// - Parameters:
    ///   - rows: the rows on screen, top to bottom.
    ///   - dayHeader: the header of the row at an index, for a day that started above the screen.
    ///   - headerTop: from a row's top edge to its header capsule's top edge.
    ///   - chipHeight: the capsule's height.
    static func dayChip(rows: [PlacedRow], dayHeader: (Int) -> String?, line: CGFloat, headerTop: CGFloat, chipHeight: CGFloat) -> DayChip? {
        // The first row reaching below the line is the one the chip sits over.
        guard let current = rows.first(where: { $0.bottom > line }) else { return nil }
        var text: String?
        var nextHeader: CGFloat?
        if let header = current.dayHeader {
            // Its own header is still below the line: that header shows the day, and the chip the day before it.
            if current.top + headerTop >= line {
                nextHeader = current.top + headerTop
            } else {
                text = header
            }
        }
        if text == nil {
            // The loaded rows always start with a header, so this walk ends within one day of messages.
            var index = current.index - 1
            while index >= 0, text == nil {
                text = dayHeader(index)
                index -= 1
            }
        }
        guard let text else { return nil }
        if nextHeader == nil, let next = rows.first(where: { $0.index > current.index && $0.dayHeader != nil }) {
            nextHeader = next.top + headerTop
        }
        let gap: CGFloat = 6
        let top = min(line, (nextHeader ?? .infinity) - gap - chipHeight)
        let push = line - top
        return DayChip(text: text, top: top, opacity: max(0, min(1, 1 - push / max(1, chipHeight))))
    }
}
