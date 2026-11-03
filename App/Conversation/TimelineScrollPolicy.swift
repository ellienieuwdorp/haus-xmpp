import Foundation

struct TimelineViewport: Equatable {
    var offset: CGFloat
    var height: CGFloat
    var contentHeight: CGFloat
    var insetTop: CGFloat
    var insetBottom: CGFloat

    var minimumOffset: CGFloat { -insetTop }
    var maximumOffset: CGFloat { max(minimumOffset, contentHeight - height + insetBottom) }
    var distanceFromTop: CGFloat { offset + insetTop }
    var isNearBottom: Bool { contentHeight + insetBottom - offset - height < TimelineScrollPolicy.nearBottomDistance }

    func clamped(_ value: CGFloat) -> CGFloat { min(maximumOffset, max(minimumOffset, value)) }
}

enum TimelineScrollPolicy {
    static let nearBottomDistance: CGFloat = 80
    static let olderHistoryLead: CGFloat = 1200

    // Only the reader's own scroll (dragging or coasting) pages; opening the chat, an inset change or any other
    // programmatic move to the top never does.
    static func requestsOlderHistory(in viewport: TimelineViewport) -> Bool {
        viewport.distanceFromTop < olderHistoryLead
    }

    // Never the loading-earlier cell, whose removal would drop the reader by its height.
    static func canAnchor(on id: String?) -> Bool { id != TimelineItems.loadingEarlierID }

    static func offsetKeepingAnchor(itemTop: CGFloat, distanceFromTop: CGFloat, in viewport: TimelineViewport) -> CGFloat {
        viewport.clamped(itemTop - distanceFromTop)
    }

    static func offsetKeepingBottomEdge(_ bottomEdge: CGFloat, bottomInset: CGFloat, in viewport: TimelineViewport) -> CGFloat {
        viewport.clamped(bottomEdge - viewport.height + bottomInset)
    }

    struct Update: Equatable {
        enum Placement: Equatable {
            case newestAtOnce
            case slideToNewest
            case followNewest
            case keepAnchor
        }

        let placement: Placement
        let follows: Bool
        // The typing bubble left without a message taking its place and the shrinking content clamped the offset, so
        // the slide plays back from the offset before the apply.
        let slidesFromPreviousOffset: Bool

        init(previousTailID: String?, rows: [TimelineRow], wasNearBottom: Bool, typingChanged: Bool, typingLeft: Bool, canAnimate: Bool) {
            // Judged from the tail alone: the loaded window is the newest N, so its head moves as messages arrive.
            let ids = rows.map(\.message.id)
            let tailStart = previousTailID.flatMap { ids.lastIndex(of: $0) }.map { $0 + 1 } ?? ids.count
            let appended = tailStart < ids.count
            let sentOwn = rows[tailStart...].contains { $0.message.isOutgoing }
            let firstContent = previousTailID == nil
            follows = firstContent || wasNearBottom || sentOwn
            slidesFromPreviousOffset = typingLeft && !appended
            // From far up in history a send jumps: a slide would cross cells that were never drawn.
            let slides = !firstContent && (appended || typingChanged) && wasNearBottom && canAnimate
            placement = firstContent ? .newestAtOnce : slides ? .slideToNewest : follows ? .followNewest : .keepAnchor
        }

        func followsAfterwards(isNearBottom: Bool) -> Bool { follows || isNearBottom }
    }
}

// Positions are in the Mac scroll view's frame coordinates: 0 is its top edge below the toolbar, and content scrolled
// under the toolbar is negative.
extension TimelineScrollPolicy {
    // A tall desktop window crosses a fixed 1,200 pt in a flick or two.
    static func olderHistoryLead(viewportHeight: CGFloat) -> CGFloat { max(olderHistoryLead, 2 * viewportHeight) }

    // A request that finds nothing more to ask for is not repeated from the same oldest message until the reader leaves
    // the lead and comes back, or older messages arrive some other way.
    struct OlderHistoryRequests: Equatable {
        private(set) var inFlight = false
        private var exhaustedAt: String?
        private var repeating = false

        init() {}

        mutating func shouldRequest(oldestID: String?, distanceFromTop: CGFloat, viewportHeight: CGFloat, byReader: Bool) -> Bool {
            guard distanceFromTop < TimelineScrollPolicy.olderHistoryLead(viewportHeight: viewportHeight) else {
                exhaustedAt = nil
                return false
            }
            guard byReader, !inFlight, let oldestID, oldestID != exhaustedAt else { return false }
            inFlight = true
            return true
        }

        // Raising the window over a store that holds no older messages brings nothing, and only the next request asks
        // the archive behind it, so ask once more at once.
        mutating func finished(oldestID: String?, broughtOlder: Bool, mayBringMore: Bool) -> Bool {
            guard mayBringMore else {
                exhaustedAt = oldestID
                inFlight = false
                repeating = false
                return false
            }
            repeating = !broughtOlder && !repeating
            inFlight = repeating
            return repeating
        }
    }

    static func showsJumpToNewest(distanceFromBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        distanceFromBottom > max(nearBottomDistance, viewportHeight / 2)
    }

    struct PlacedRow: Equatable {
        let id: String
        let index: Int
        let top: CGFloat
        let bottom: CGFloat
        let dayHeader: String?
    }

    static func readerRow(_ rows: [PlacedRow], visibleTop: CGFloat, visibleBottom: CGFloat) -> PlacedRow? {
        let anchorable = rows.filter { canAnchor(on: $0.id) }
        return anchorable.first { $0.top >= visibleTop - 0.5 && $0.top < visibleBottom }
            ?? anchorable.first { $0.top < visibleBottom && $0.bottom > visibleTop }
    }

    // A scroll to a row with anchor y puts its top at y × (frameHeight − rowHeight); SwiftUI clamps y to 0…1, so only
    // tops from `reachableTop` can be asked for.
    static func anchorY(placingTopAt top: CGFloat, rowHeight: CGFloat, frameHeight: CGFloat) -> CGFloat? {
        let travel = frameHeight - rowHeight
        guard abs(travel) > 1 else { return nil }
        return top / travel
    }

    static func reachableTop(_ top: CGFloat, rowHeight: CGFloat, frameHeight: CGFloat) -> CGFloat {
        let travel = frameHeight - rowHeight
        return min(max(top, min(0, travel)), max(0, travel))
    }

    static func scrollStep(_ rows: [PlacedRow], by delta: CGFloat, frameHeight: CGFloat) -> (row: PlacedRow, top: CGFloat)? {
        let steps = rows.compactMap { row -> (row: PlacedRow, top: CGFloat)? in
            let top = reachableTop(row.top + delta, rowHeight: row.bottom - row.top, frameHeight: frameHeight)
            let move = top - row.top
            guard move * delta > 0, abs(move) > 0.5, abs(move) <= abs(delta) + 0.5 else { return nil }
            return (row, top)
        }
        return steps.max { abs($0.top - $0.row.top) < abs($1.top - $1.row.top) }
    }

    enum Landing: Equatable {
        case row(index: Int, top: CGFloat)
        case start
        case end
    }

    // Stepping through laid-out rows builds every screen on the way; scrolling to where the stack places the landing
    // row builds only the rows it lands among.
    static func landing(_ rows: [PlacedRow], by delta: CGFloat, frameHeight: CGFloat, rowCount: Int, lead: CGFloat, tail: CGFloat,
                        height: (Int) -> CGFloat) -> Landing? {
        guard let first = rows.first, let last = rows.last else { return nil }
        if delta > 0 {
            var top = first.top + delta
            guard top >= 0 else { return nil }
            var index = first.index
            while index > 0 {
                let above = top - height(index - 1)
                if above < 0 { break }
                index -= 1
                top = above
            }
            if index == 0, top > lead { return .start }
            if top >= frameHeight, index > 0 {
                index -= 1
                top -= height(index)
            }
            return index == first.index ? nil : .row(index: index, top: top)
        }
        guard delta < 0, last.top + delta < 0 else { return nil }
        var top = last.bottom + delta
        var index = last.index + 1
        while index < rowCount, top < 0 {
            top += height(index)
            index += 1
        }
        if top >= frameHeight {
            guard index - 1 > last.index else { return nil }
            index -= 1
            top -= height(index)
        }
        guard index < rowCount else { return .end }
        let below = (index..<rowCount).reduce(tail) { $0 + height($1) }
        return top + below < frameHeight ? .end : .row(index: index, top: top)
    }

    struct DayChip: Equatable {
        let text: String
        let top: CGFloat
        let opacity: CGFloat
    }

    // A header coming back down to `line` takes its date back, so the chip and the inline header never show one day twice.
    static func dayChip(rows: [PlacedRow], dayHeader: (Int) -> String?, line: CGFloat, headerTop: CGFloat, chipHeight: CGFloat) -> DayChip? {
        guard let current = rows.first(where: { $0.bottom > line }) else { return nil }
        var text: String?
        var nextHeader: CGFloat?
        if let header = current.dayHeader {
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
