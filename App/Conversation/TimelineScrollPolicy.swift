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

/// The timeline's scrolling decisions, measured on the iPhone (docs/development/timeline-responsiveness.md): a chat
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
