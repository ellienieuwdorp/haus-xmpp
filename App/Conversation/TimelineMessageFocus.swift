import CoreGraphics

enum TimelineMessageFocus {
    // Without an on-screen focused message, Up starts from the newest message on screen and Down from the oldest.
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

    // The caller clamps the result with `TimelineScrollPolicy.reachableTop`.
    static func revealTop(top: CGFloat, bottom: CGFloat, frameHeight: CGFloat, margin: CGFloat) -> CGFloat? {
        let height = bottom - top
        if height + 2 * margin > frameHeight {
            return abs(top - margin) <= 0.5 ? nil : margin
        }
        if top >= -0.5 && bottom <= frameHeight + 0.5 { return nil }
        return top < 0 ? margin : frameHeight - margin - height
    }
}
