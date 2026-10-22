#if DEBUG
import AppKit
import SwiftUI

/// The timeline's tour steps and measurements (`-haus-tour`, `-haus-timeline-trace`; see `MacDebugHooks`). Debug
/// builds only.
///
/// Drift is how far the reader's row moved from where it was before an update, sampled on each of the next 30
/// refreshes. Scroll events cannot be staged here (the window is off-screen, so AppKit gives them no window): `drag`
/// moves the clip view as a gesture would, and marks the move as the reader's.
@MainActor enum MacTimelineDebug {
    static func step(_ name: String, _ argument: String, window: NSWindow?) async {
        // The window's own cost too, with no chat open.
        if name == "resize-sweep" { return await resizeSweep(argument, window: window) }
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
            if let points = argument.split(separator: " ").last.flatMap({ Double($0) }), argument.hasPrefix("by ") {
                timeline.debugScroll(by: points)
                return report(timeline, "after scroll \(argument)")
            }
            guard let key else { return MacDebugHooks.log("tour scroll \(argument): unknown") }
            timeline.scroll(key)
            report(timeline, "after scroll \(argument)")
        case "scroll-to":
            timeline.scrollTo(messageID: argument)
        case "quote":
            timeline.scrollTo(quotedMessage: argument)
        case "resize":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            guard size.count == 2, let window else { return }
            let reader = timeline.table.readerRow()
            window.setContentSize(NSSize(width: size[0], height: size[1]))
            // Two refreshes for SwiftUI to lay the new width out.
            try? await Task.sleep(for: .milliseconds(50))
            let after = reader.flatMap { timeline.table.debugTop(of: $0.id) }
            MacDebugHooks.log("timeline resize to \(argument): reader \(reader?.id ?? "none") drift \(format(after.map { $0 - (reader?.top ?? 0) }))")
        case "timeline":
            report(timeline, "state")
        case "drag":
            drag(argument, timeline: timeline, window: window)
        case "bind-reader":
            // The table keeps the reader's rows itself; there is no scroll position to bind.
            MacDebugHooks.log("timeline bound nothing: the table keeps the reader's rows itself")
        case "mismatch":
            MacDebugHooks.log("timeline mismatch: \(timeline.table.debugMismatch())")
        case "older":
            await timeline.debugLoadOlder()
        case "arrive":
            // A received message added below the others through the table's update path, as an arrival is; the model
            // never has it, so the next change of the model's rows takes it away again.
            var content = timeline.content
            let message = TimelineMessage(id: "debug-arrival-\(content.rows.count)", body: argument.isEmpty ? "A message arriving while the reader is elsewhere." : argument,
                                          isOutgoing: false, isStarred: false, sentAt: .now)
            content.rows.append(TimelineRow(message: message, dateHeader: nil, startsRun: true, endsRun: true))
            let reader = timeline.table.readerRow()
            timeline.table.update(content)
            try? await Task.sleep(for: .milliseconds(100))
            let after = reader.flatMap { timeline.table.debugTop(of: $0.id) }
            MacDebugHooks.log("timeline arrive: reader \(reader?.id ?? "none") drift \(format(after.map { $0 - (reader?.top ?? 0) })), \(timeline.table.debugReport)")
            MacDebugHooks.log("timeline arrive heights: \(timeline.table.debugHeights(of: message.id))")
        case "settle":
            timeline.update()
        case "show-row":
            // The typing bubble or the loading row, through the update path; `settle` takes it away.
            var content = timeline.content
            switch argument {
            case "typing": content.typing = TimelineTyping(author: nil, colorKey: "alex@preview.local", accessibilityLabel: "Typing")
            case "group-typing": content.typing = TimelineTyping(author: "Alex", colorKey: "alex@preview.local", accessibilityLabel: "Alex is typing")
            case "loading": content.loadingEarlier = true
            default: return MacDebugHooks.log("tour show-row \(argument): typing, group-typing or loading")
            }
            timeline.table.update(content)
            report(timeline, "show-row \(argument)")
        default: break
        }
    }

    /// `resize-sweep <width>x<height> <width>x<height> <steps>`: resizes the main window from the first size to the
    /// second in even steps, one a frame, as a live resize would, and logs how long each step held the main thread: the
    /// resize with its layout and display, and what ran in the turns after it before the next frame was due; and the
    /// resize's CPU time, which leaves out waiting for a core on a busy machine.
    private static func resizeSweep(_ argument: String, window: NSWindow?) async {
        let parts = argument.split(separator: " ")
        let sizes = parts.prefix(2).map { $0.split(separator: "x").compactMap { Double($0) } }
        guard let window, sizes.count == 2, sizes.allSatisfy({ $0.count == 2 }), let steps = parts.dropFirst(2).first.flatMap({ Int($0) }), steps > 0 else {
            return MacDebugHooks.log("tour resize-sweep \(argument): needs <width>x<height> <width>x<height> <steps>")
        }
        var synchronous: [Double] = [], whole: [Double] = [], phases: [[Double]] = [[], [], []], cpu: [Double] = []
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let size = NSSize(width: sizes[0][0] + (sizes[1][0] - sizes[0][0]) * progress, height: sizes[0][1] + (sizes[1][1] - sizes[0][1]) * progress)
            let started = CACurrentMediaTime(), startedCPU = MacPerfProbe.cpuTime()
            window.setContentSize(size)
            let sized = CACurrentMediaTime()
            window.contentView?.layoutSubtreeIfNeeded()
            let laidOut = CACurrentMediaTime()
            window.displayIfNeeded()
            synchronous.append(CACurrentMediaTime() - started)
            cpu.append(MacPerfProbe.cpuTime() - startedCPU)
            phases[0].append(sized - started); phases[1].append(laidOut - sized); phases[2].append(CACurrentMediaTime() - laidOut)
            // A frame later, after whatever the resize scheduled for the next turns.
            try? await Task.sleep(for: .milliseconds(16))
            whole.append(CACurrentMediaTime() - started)
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.1f ms, worst %.1f ms, total %.0f ms", sorted[sorted.count / 2] * 1_000, (sorted.last ?? 0) * 1_000, sorted.reduce(0, +) * 1_000)
        }
        MacDebugHooks.log("timeline resize-sweep \(argument): \(steps + 1) steps; resize and layout \(summary(synchronous)); step with the next frame \(summary(whole)); setContentSize \(summary(phases[0])), layout \(summary(phases[1])), display \(summary(phases[2])); resize and layout CPU \(summary(cpu))")
    }

    /// `drag <points> <seconds> [phaseless]`: moves the timeline's clip view by `points` (positive towards older messages)
    /// over `seconds` on a 120 Hz timer, as the reader's scroll: a gesture's phases around it, or none with `phaseless`,
    /// as a wheel or the scroller may report. It runs while the next steps play, so a resize can land mid-scroll, and
    /// logs the reader's row when it starts and when it ends.
    private static func drag(_ argument: String, timeline: MacTimelineController, window: NSWindow?) {
        let parts = argument.split(separator: " ")
        func scrollViews(in view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:)) }
        guard parts.count >= 2, let points = Double(parts[0]), let seconds = Double(parts[1]), seconds > 0, let root = window?.contentView,
              let scrollView = scrollViews(in: root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else {
            return MacDebugHooks.log("tour drag \(argument): needs <points> <seconds> [phaseless] and an open timeline")
        }
        Drag(scrollView: scrollView, timeline: timeline, points: points, seconds: seconds, phases: parts.dropFirst(2).first != "phaseless",
             label: String(argument)).start()
    }

    @MainActor private final class Drag {
        let scrollView: NSScrollView, timeline: MacTimelineController, points: Double, seconds: Double, phases: Bool, label: String
        private var started: CFTimeInterval = 0
        private var moved: CGFloat = 0
        private var timer: Timer?

        init(scrollView: NSScrollView, timeline: MacTimelineController, points: Double, seconds: Double, phases: Bool, label: String) {
            (self.scrollView, self.timeline, self.points, self.seconds, self.phases, self.label) = (scrollView, timeline, points, seconds, phases, label)
        }

        /// Keeps itself alive through its timer until the drag ends.
        func start() {
            report(timeline, "drag \(label) start")
            if phases { timeline.debugReaderScrolling(true) }
            started = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1 / 120.0, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            let progress = min(1, (CACurrentMediaTime() - started) / seconds)
            let step = CGFloat(points * progress) - moved
            moved += step
            let clip = scrollView.contentView
            let range = MacDebugHooks.ScrollProbe.range(of: scrollView)
            let flipped = scrollView.documentView?.isFlipped ?? true
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(range.upperBound, max(range.lowerBound, clip.bounds.minY + (flipped ? -step : step)))))
            scrollView.reflectScrolledClipView(clip)
            guard progress >= 1 else { return }
            timer?.invalidate()
            timer = nil
            if phases { timeline.debugReaderScrolling(false) }
            report(timeline, "drag \(label) end")
        }
    }

    private static func report(_ timeline: MacTimelineController, _ what: String) {
        let reader = timeline.table.readerRow()
        let newest = timeline.rows.last.flatMap { timeline.table.debugTop(of: $0.message.id) }
        MacDebugHooks.log("timeline \(what): \(timeline.rows.count) rows from \(timeline.rows.first?.message.id ?? "none"), reader \(reader?.id ?? "none") at "
            + "\(format(reader?.top)), \(timeline.table.debugReport), newest row top \(format(newest)), "
            + "jump button \(timeline.showsJumpToNewest), day chip \(timeline.dayChip?.text ?? "none")")
    }

    /// After an update that kept the reader's rows: the reader's row's drift right after the update and over the next
    /// 30 refreshes.
    static func held(_ reader: TimelineScrollPolicy.PlacedRow, by table: MacTimelineTableController) {
        guard MacDebugHooks.has("-haus-timeline-trace") else { return }
        let immediate = table.debugTop(of: reader.id).map { $0 - reader.top }
        Task {
            let clock = ContinuousClock(), start = clock.now
            var worst = abs(immediate ?? 0), missing = 0, changes: [String] = []
            var last = immediate ?? 0
            for sample in 0..<90 {
                try? await Task.sleep(for: .milliseconds(16))
                guard let top = table.debugTop(of: reader.id) else { missing += 1; continue }
                let drift = top - reader.top
                if sample < 30 { worst = max(worst, abs(drift)) }
                if abs(drift - last) > 0.5 {
                    changes.append("\(format(drift)) at \((clock.now - start) / .milliseconds(1)) ms")
                    last = drift
                }
            }
            MacDebugHooks.log("timeline held \(reader.id): \(table.timeline?.rows.count ?? 0) rows, "
                + "drift \(format(immediate)) pt after the update, worst \(format(worst)) pt over 30 refreshes, later moves \(changes)"
                + "\(missing > 0 ? ", gone in \(missing) samples" : "")")
        }
    }

    /// `stalls [label]`: logs the main thread's stalls since the last `stalls` step (the first one starts the probe), each
    /// a gap of over 50 ms between the ticks of a 120 Hz timer on the main run loop, which runs in every run loop mode,
    /// event tracking and live resize included.
    @MainActor final class StallProbe {
        static let shared = StallProbe()
        private var last: CFTimeInterval = 0
        private var stalls: [(at: Date, seconds: Double)] = []
        private var timer: Timer?

        func report(_ label: String) {
            guard timer != nil else {
                last = CACurrentMediaTime()
                let timer = Timer(timeInterval: 1 / 120.0, repeats: true) { _ in MainActor.assumeIsolated { StallProbe.shared.tick() } }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                return MacDebugHooks.log("stalls: probe started")
            }
            tick()
            let total = stalls.reduce(0) { $0 + $1.seconds }
            MacDebugHooks.log(String(format: "stalls %@: %d over 50 ms, worst %.0f ms, total %.0f ms", label, stalls.count, (stalls.map(\.seconds).max() ?? 0) * 1_000, total * 1_000)
                + (stalls.isEmpty ? "" : "; " + stalls.prefix(12).map { String(format: "%.0f ms ending %@", $0.seconds * 1_000, Self.stamp.string(from: $0.at)) }.joined(separator: ", ")))
            stalls = []
        }

        private func tick() {
            let now = CACurrentMediaTime()
            if now - last > 0.05 { stalls.append((Date(), now - last)) }
            last = now
        }

        private static let stamp: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()
    }

    private static func format(_ value: CGFloat?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "-"
    }
}
#endif
