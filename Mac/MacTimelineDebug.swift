#if DEBUG
import AppKit
import SwiftUI

/// The timeline's tour steps and measurements (`-haus-tour`, `-haus-timeline-trace`; see `MacDebugHooks`). Debug
/// builds only.
///
/// Drift is how far the reader's row moved from where it was before an update, sampled on each of the next 30
/// refreshes. Scroll events cannot be staged here (the window is off-screen, so AppKit gives them no window), so a page
/// landing mid-gesture is stood in for by `-haus-timeline-unbound`: without the bound position SwiftUI keeps the
/// absolute offset through a prepend, as it does during a gesture, and the controller's correction does all the work.
@MainActor enum MacTimelineDebug {
    static func step(_ name: String, _ argument: String, window: NSWindow?) async {
        guard let timeline = MacTimelineController.current else {
            MacDebugHooks.log("tour \(name): no open timeline")
            return
        }
        switch name {
        case "scroll":
            let key: MacTimelineController.KeyScroll? = switch argument {
            case "top": .top
            case "bottom": .bottom
            case "page-up": .pageUp
            case "page-down": .pageDown
            default: nil
            }
            guard let key else { return MacDebugHooks.log("tour scroll \(argument): unknown") }
            timeline.scroll(key)
            report(timeline, "after scroll \(argument)")
        case "scroll-to":
            timeline.scrollTo(messageID: argument)
        case "resize":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            guard size.count == 2, let window else { return }
            let reader = timeline.readerRow()
            window.setContentSize(NSSize(width: size[0], height: size[1]))
            // Two refreshes for SwiftUI to lay the new width out.
            try? await Task.sleep(for: .milliseconds(50))
            let after = reader.flatMap { timeline.layout.frame(of: $0.id) }
            MacDebugHooks.log("timeline resize to \(argument): reader \(reader?.id ?? "none") drift \(format(after.map { $0.minY - (reader?.top ?? 0) }))")
        case "timeline":
            report(timeline, "state")
        default: break
        }
    }

    private static func report(_ timeline: MacTimelineController, _ what: String) {
        let reader = timeline.readerRow()
        MacDebugHooks.log("timeline \(what): \(timeline.rows.count) rows from \(timeline.rows.first?.message.id ?? "none"), reader \(reader?.id ?? "none") at "
            + "\(format(reader?.top)), from bottom \(format(timeline.layout.distanceFromBottom)), height \(format(timeline.layout.height)), "
            + "top inset \(format(timeline.layout.geometry?.contentInsets.top)), jump button \(timeline.showsJumpToNewest), day chip \(timeline.dayChip?.text ?? "none")")
    }

    /// After an update that held the reader's row: how far the update moved it before the correction, and its drift
    /// right after the correction and over the next 30 refreshes.
    static func held(_ reader: TimelineScrollPolicy.PlacedRow, movedByUpdate moved: CGFloat?, by timeline: MacTimelineController) {
        guard MacDebugHooks.has("-haus-timeline-trace") else { return }
        let immediate = timeline.layout.frame(of: reader.id).map { $0.minY - reader.top }
        Task {
            let clock = ContinuousClock(), start = clock.now
            var worst: CGFloat = 0, missing = 0, changes: [String] = []
            var last = immediate ?? 0
            for sample in 0..<90 {
                try? await Task.sleep(for: .milliseconds(16))
                guard let frame = timeline.layout.frame(of: reader.id) else { missing += 1; continue }
                let drift = frame.minY - reader.top
                if sample < 30 { worst = max(worst, abs(drift)) }
                if abs(drift - last) > 0.5 {
                    changes.append("\(format(drift)) at \((clock.now - start) / .milliseconds(1)) ms")
                    last = drift
                }
            }
            MacDebugHooks.log("timeline held \(reader.id): \(timeline.rows.count) rows, the update moved it \(moved.map(format) ?? "off screen") pt, "
                + "drift \(format(immediate)) pt after the hold, worst \(format(worst)) pt over 30 refreshes, later moves \(changes)"
                + "\(missing > 0 ? ", gone in \(missing) samples" : "")")
        }
    }

    private static func format(_ value: CGFloat?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "-"
    }
}
#endif
