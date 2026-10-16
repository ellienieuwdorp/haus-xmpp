import CoreGraphics

/// Keyboard focus among a desktop timeline's messages: the arrow keys move it from message to message, and the
/// timeline scrolls just far enough to keep the focused one in view.
enum TimelineMessageFocus {
    /// The message an arrow key focuses. From a focused message that is on screen, the one before it (`forward` false)
    /// or after it, staying put at either end. Otherwise the press starts where the reader is looking: Up from the
    /// newest message on screen, Down from the oldest, preferring messages wholly in view; with nothing laid out, the
    /// newest message. `placed` are the rows laid out now, top to bottom, in the frame's coordinates.
    static func step(from current: String?, forward: Bool, ids: [String], placed: [TimelineScrollPolicy.PlacedRow], frameHeight: CGFloat) -> String? {
        let onScreen = placed.filter { $0.bottom > 0.5 && $0.top < frameHeight - 0.5 }
        if let current, onScreen.contains(where: { $0.id == current }), let index = ids.firstIndex(of: current) {
            let next = forward ? index + 1 : index - 1
            return ids.indices.contains(next) ? ids[next] : current
        }
        let whole = onScreen.filter { $0.top >= -0.5 && $0.bottom <= frameHeight + 0.5 }
        let candidates = whole.isEmpty ? onScreen : whole
        return (forward ? candidates.first : candidates.last)?.id ?? ids.last
    }

    /// Where to put a row's top edge so that it shows, `margin` clear of the frame's edges where it fits; nil when it
    /// already shows whole. A row too tall for that shows from its top. The caller keeps the result reachable
    /// (`TimelineScrollPolicy.reachableTop`).
    static func revealTop(top: CGFloat, bottom: CGFloat, frameHeight: CGFloat, margin: CGFloat) -> CGFloat? {
        let height = bottom - top
        if height + 2 * margin > frameHeight {
            return abs(top - margin) <= 0.5 ? nil : margin
        }
        if top >= -0.5 && bottom <= frameHeight + 0.5 { return nil }
        return top < 0 ? margin : frameHeight - margin - height
    }
}
