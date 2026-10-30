#if DEBUG
import AppKit
import SwiftUI

/// The timeline's tour steps and measurements (`-haus-tour`, `-haus-timeline-trace`; see `MacDebugHooks`). Debug
/// builds only.
///
/// Drift is how far the reader's row moved from where it was before an update, sampled on each of the next 30
/// refreshes. Scroll events cannot be staged here (the window is off-screen, so AppKit gives them no window): `drag`
/// moves the clip view as a gesture would, inside the table's live scroll, as a gesture's phases start and end it.
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
        case "knob":
            knob(Double(argument) ?? 0, timeline: timeline)
        case "swipe":
            await swipe(argument, timeline: timeline)
        case "swipe-end":
            await swipeEnd(argument, timeline: timeline)
        case "bind-reader":
            // The table keeps the reader's rows itself; there is no scroll position to bind.
            MacDebugHooks.log("timeline bound nothing: the table keeps the reader's rows itself")
        case "mismatch":
            MacDebugHooks.log("timeline mismatch: \(timeline.table.debugMismatch())")
        case "older":
            await timeline.debugLoadOlder()
        case "arrive":
            await arrive(argument.isEmpty ? "A message arriving while the reader is elsewhere." : argument, timeline: timeline)
        case "arrive-long":
            await arrive(longText(Int(argument) ?? 16_384), timeline: timeline)
        case "arrive-extras":
            await arriveExtras(argument, timeline: timeline)
        case "hit-reaction":
            func reactions() -> String {
                (timeline.rows.first { $0.message.id == argument }?.message.reactions ?? []).map { "\($0.emoji)\($0.count)\($0.isSelected ? " yours" : "")" }.joined(separator: " ")
            }
            let before = reactions()
            MacDebugHooks.log("timeline hit-reaction \(argument): \(timeline.table.debugHitReaction(argument))")
            try? await Task.sleep(for: .milliseconds(500))
            MacDebugHooks.log("timeline hit-reaction \(argument): reactions [\(before)] then [\(reactions())]")
        case "reuse-media":
            MacDebugHooks.log("timeline reuse-media: \(await timeline.table.debugReuseMedia())")
        case "extras-cache":
            MacDebugHooks.log("timeline extras-cache: \(timeline.table.debugExtrasCache())")
        case "update-race":
            // Two updates measured on the queue with a reload between them, as a new accent makes one: the second applies
            // its own rows, and the first's records, landing after the reload, nothing.
            var first = timeline.content
            first.rows.append(arrival("debug-race-first", longText(2_000)))
            timeline.table.update(first)
            timeline.table.debugReload()
            var second = timeline.content
            second.rows.append(arrival("debug-race-second", longText(2_000)))
            timeline.table.update(second)
            try? await Task.sleep(for: .milliseconds(400))
            MacDebugHooks.log("timeline update-race: second listed \(timeline.table.debugTop(of: "debug-race-second") != nil), "
                + "first listed \(timeline.table.debugTop(of: "debug-race-first") != nil), applying \(timeline.table.isApplying), \(timeline.rows.count) rows")
        case "gesture-update":
            // An update measured on the queue whose records land once a gesture has begun: held, the offset untouched,
            // until the gesture ends.
            let reader = timeline.table.readerRow()
            let start = timeline.table.debugClipY
            var content = timeline.content
            content.rows.append(arrival("debug-gesture-arrival", longText(2_000)))
            timeline.table.update(content)
            timeline.debugLiveScroll(true)
            try? await Task.sleep(for: .milliseconds(400))
            let listed = timeline.table.debugTop(of: "debug-gesture-arrival") != nil, moved = timeline.table.debugClipY - start, held = timeline.table.isApplying
            timeline.debugLiveScroll(false)
            try? await Task.sleep(for: .milliseconds(100))
            let after = reader.flatMap { timeline.table.debugTop(of: $0.id) }
            MacDebugHooks.log("timeline gesture-update: during the gesture listed \(listed), clip moved \(format(moved)) pt, held \(held); "
                + "after it listed \(timeline.table.debugTop(of: "debug-gesture-arrival") != nil), reader \(reader?.id ?? "none") drift \(format(after.map { $0 - (reader?.top ?? 0) }))")
        case "resize-drag":
            await resizeDrag(argument.isEmpty ? "760x800 4500 2" : argument, timeline: timeline, window: window)
        case "edit-race":
            await editRace(timeline: timeline, window: window)
        case "overlay-resize":
            await overlayResize(argument.isEmpty ? "760x800" : argument, timeline: timeline, window: window)
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

    /// `resize-sweep <width>x<height> <width>x<height> <steps> [live]`: resizes the main window from the first size to the
    /// second in even steps, one a frame, as a live resize would, and logs how long each step held the main thread: the
    /// resize with its layout and display, and what ran in the turns after it before the next frame was due; and the
    /// resize's CPU time, which leaves out waiting for a core on a busy machine. With `live` after the steps the window
    /// is in a live resize throughout, as under the pointer (`inLiveResize` is true, and what waits for its end waits).
    private static func resizeSweep(_ argument: String, window: NSWindow?) async {
        let parts = argument.split(separator: " ")
        let sizes = parts.prefix(2).map { $0.split(separator: "x").compactMap { Double($0) } }
        guard let window, sizes.count == 2, sizes.allSatisfy({ $0.count == 2 }), let steps = parts.dropFirst(2).first.flatMap({ Int($0) }), steps > 0 else {
            return MacDebugHooks.log("tour resize-sweep \(argument): needs <width>x<height> <width>x<height> <steps> [live]")
        }
        let live = parts.dropFirst(3).first == "live"
        let start = Selector(("_startLiveResize")), end = Selector(("_endLiveResize"))
        if live, window.responds(to: start), window.responds(to: end) { window.perform(start) }
        let inLiveResize = window.inLiveResize
        defer { if inLiveResize { window.perform(end) } }
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
        MacDebugHooks.log("timeline resize-sweep \(argument): \(steps + 1) steps\(inLiveResize ? " in a live resize" : ""); resize and layout \(summary(synchronous)); step with the next frame \(summary(whole)); setContentSize \(summary(phases[0])), layout \(summary(phases[1])), display \(summary(phases[2])); resize and layout CPU \(summary(cpu))")
    }

    /// `knob [<seconds>]`: the timeline's scroller against the scroll view and its insets, and its knob, now and then on
    /// each refresh for `seconds` while the next steps play.
    private static func knob(_ seconds: Double, timeline: MacTimelineController) {
        let scrollView = timeline.table.scrollView
        func sample(_ label: String) {
            guard let scroller = scrollView.verticalScroller else { return MacDebugHooks.log("timeline knob: no scroller") }
            let frame = scroller.frame, knob = scroller.rect(for: .knob), insets = scrollView.contentInsets
            MacDebugHooks.log("timeline knob \(label): scroller \(format(frame.minY))-\(format(frame.maxY)) of \(format(scrollView.bounds.height)) "
                + "(insets \(format(insets.top)), \(format(insets.bottom))) \(scroller.scrollerStyle == .overlay ? "overlay" : "legacy") "
                + "(system \(NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy")), "
                + "knob \(format(knob.minY)) + \(format(knob.height)), value \(String(format: "%.3f", scroller.doubleValue)) "
                + "proportion \(String(format: "%.3f", scroller.knobProportion))")
        }
        sample("now")
        guard seconds > 0 else { return }
        Task {
            let clock = ContinuousClock(), start = clock.now
            while clock.now - start < .seconds(seconds) {
                try? await Task.sleep(for: .milliseconds(16))
                let elapsed = (clock.now - start).components
                sample(String(format: "%.3f s", Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
            }
        }
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
            if phases { timeline.debugLiveScroll(true) }
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
            if phases { timeline.debugLiveScroll(false) }
            report(timeline, "drag \(label) end")
        }
    }

    // MARK: Reply swipe

    /// The message and the point of a swipe `swipe … hold` left open, for `swipe-end`.
    private static var heldSwipe: (id: String, point: NSPoint, fingerX: CGFloat)?

    /// `swipe <message id> <points> [<vertical points>] [hold|wheel]`: a two-finger gesture over the message's bubble,
    /// handed straight to the table's reply swipe as the window's event monitor would hand it on (no event goes through
    /// the window server): `mayBegin`, then the fingers moving `points` right (negative: left) and the vertical points
    /// down in whole-point steps of about 4 pt, 8 ms apart, then `ended` and a short momentum. With `hold` it stops before
    /// `ended`, so a `capture` can show the swipe under way, and `swipe-end [cancel]` finishes it. `wheel` sends one
    /// notched mouse wheel event instead. What the swipe does not keep is counted, not sent on: an off-screen window's
    /// scroll view cannot track a gesture (its responsive scrolling needs a screen). Logs whether the swipe took the
    /// gesture, how far the bubble went, whether it replied and the composer's reply.
    private static func swipe(_ argument: String, timeline: MacTimelineController) async {
        let words = argument.split(separator: " ").map(String.init)
        let numbers = words.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
        guard let id = words.first, let x = numbers.first, let point = timeline.table.debugSwipePoint(of: id) else {
            return MacDebugHooks.log("tour swipe \(argument): needs a message in the open chat and <points> [<vertical points>] [hold|wheel]")
        }
        let y = numbers.dropFirst().first ?? 0
        timeline.table.replySwipe.debugReleased = 0
        if words.contains("wheel") {
            send(scrollEvent(x: x, y: y, phase: nil, momentum: .none, continuous: false), at: point, timeline: timeline)
            return await logSwipe(id, argument, timeline: timeline)
        }
        send(scrollEvent(x: 0, y: 0, phase: .mayBegin, momentum: .none), at: point, timeline: timeline)
        let steps = max(1, Int((max(abs(x), abs(y)) / 4).rounded(.up)))
        // Whole points, as a trackpad's events carry them, adding up to the distance.
        func part(_ total: CGFloat, _ step: Int) -> CGFloat {
            (total * CGFloat(step + 1) / CGFloat(steps)).rounded() - (total * CGFloat(step) / CGFloat(steps)).rounded()
        }
        for step in 0..<steps {
            try? await Task.sleep(for: .milliseconds(8))
            send(scrollEvent(x: part(x, step), y: part(y, step), phase: step == 0 ? .began : .changed, momentum: .none), at: point, timeline: timeline)
        }
        if words.contains("hold") {
            heldSwipe = (id, point, (x / CGFloat(steps)).rounded())
            try? await Task.sleep(for: .milliseconds(50))
            return MacDebugHooks.log("timeline swipe \(argument) held: \(timeline.table.debugSwipeState(of: id))")
        }
        await endGesture((x / CGFloat(steps)).rounded(), cancel: false, at: point, timeline: timeline)
        await logSwipe(id, argument, timeline: timeline)
    }

    private static func swipeEnd(_ argument: String, timeline: MacTimelineController) async {
        guard let held = heldSwipe else { return MacDebugHooks.log("tour swipe-end: no swipe held") }
        heldSwipe = nil
        timeline.table.replySwipe.debugReleased = 0
        await endGesture(held.fingerX, cancel: argument == "cancel", at: held.point, timeline: timeline)
        await logSwipe(held.id, "end \(argument)", timeline: timeline)
    }

    /// The fingers lift (or the gesture is cancelled), and the momentum that follows a quick lift runs out.
    private static func endGesture(_ x: CGFloat, cancel: Bool, at point: NSPoint, timeline: MacTimelineController) async {
        try? await Task.sleep(for: .milliseconds(8))
        send(scrollEvent(x: 0, y: 0, phase: cancel ? .cancelled : .ended, momentum: .none), at: point, timeline: timeline)
        guard !cancel else { return }
        for (index, momentum) in [CGMomentumScrollPhase.begin, .continuous, .continuous, .end].enumerated() {
            try? await Task.sleep(for: .milliseconds(8))
            send(scrollEvent(x: momentum == .end ? 0 : (x / CGFloat(index + 1)).rounded(), y: 0, phase: nil, momentum: momentum), at: point, timeline: timeline)
        }
    }

    private static func logSwipe(_ id: String, _ argument: String, timeline: MacTimelineController) async {
        // The reply reaches the composer through SwiftUI's next update, and the bubble settles in 0.3 s.
        try? await Task.sleep(for: .milliseconds(400))
        let record = timeline.table.replySwipe.debugRecord
        MacDebugHooks.log("timeline swipe \(argument): claimed \(record.claimed), max offset \(format(record.maxOffset)), replied \(record.replied), "
            + "haptics \(record.haptics), cancelled \(record.cancelled), events kept \(record.consumed) passed \(record.passed), "
            + "held back then handed on \(timeline.table.replySwipe.debugReleased), "
            + "after it \(timeline.table.debugSwipeState(of: id)); "
            + "composer replying to \(MacComposerTour.intent?.replyingTo?.id ?? "none")")
    }

    /// One event through the table's reply swipe; held events it hands back are counted.
    private static func send(_ event: NSEvent?, at point: NSPoint, timeline: MacTimelineController) {
        guard let event else { return MacDebugHooks.log("tour swipe: no scroll event") }
        if event.phase == .began || event.phase.isEmpty && event.momentumPhase.isEmpty {
            MacDebugHooks.log(String(format: "timeline swipe event: phase %lu, x %.1f, y %.1f, precise %d, inverted %d", event.phase.rawValue,
                                     event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0, event.isDirectionInvertedFromDevice ? 1 : 0))
        }
        _ = timeline.table.handleScroll(event, at: point) { _ in timeline.table.replySwipe.debugReleased += 1 }
    }

    /// A trackpad's scroll event (a wheel's, with `continuous` false) for the fingers moving `x` right and `y` down,
    /// whatever this Mac's scroll-direction setting.
    private static func scrollEvent(x: CGFloat, y: CGFloat, phase: CGScrollPhase?, momentum: CGMomentumScrollPhase, continuous: Bool = true) -> NSEvent? {
        func make(_ sign: CGFloat) -> NSEvent? {
            let dx = x * sign, dy = y * sign
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line, wheelCount: 2,
                                      wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            if continuous {
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded()))
            }
            return NSEvent(cgEvent: event)
        }
        // Natural scrolling reports deltas that follow the fingers; with it off they are the other way round.
        guard let event = make(1) else { return nil }
        return event.isDirectionInvertedFromDevice || !continuous ? event : make(-1)
    }

    /// A received message added below the others through the table's update path, as an arrival is; the model never
    /// has it, so the next change of the model's rows takes it away again.
    private static func arrive(_ text: String, timeline: MacTimelineController) async {
        var content = timeline.content
        let row = arrival("debug-arrival-\(content.rows.count)", text)
        content.rows.append(row)
        let reader = timeline.table.readerRow()
        timeline.table.update(content)
        try? await Task.sleep(for: .milliseconds(100))
        let after = reader.flatMap { timeline.table.debugTop(of: $0.id) }
        MacDebugHooks.log("timeline arrive: reader \(reader?.id ?? "none") drift \(format(after.map { $0 - (reader?.top ?? 0) })), \(timeline.table.debugReport)")
        MacDebugHooks.log("timeline arrive heights: \(timeline.table.debugHeights(of: row.message.id))")
    }

    /// `arrive-extras <count> [older]`: messages with a quote and a large link card, which the queue can only guess the
    /// height of, added below the others, or above the oldest as an older page. Like `arrive`, the model never has them.
    private static func arriveExtras(_ argument: String, timeline: MacTimelineController) async {
        let words = argument.split(separator: " ")
        let count = words.first.flatMap { Int($0) } ?? 8, older = words.contains("older")
        var content = timeline.content
        let rows = (0..<count).map { index in
            let url = URL(string: "https://example.com/card-\(index)")!
            let preview = TimelineLinkPreview(url: url, host: "example.com", title: "A card with a large picture, number \(index)",
                                              summary: "Its summary runs to a second line, so the card is taller than a guess at it.", variant: .large, imageAspectRatio: 1.2)
            let message = TimelineMessage(id: "debug-extras-\(older ? "older" : "newer")-\(index)", body: "A card and a quote: \(url.absoluteString)",
                                          // Received below the reader, which a sent message would bring to the newest.
                                          isOutgoing: older && index.isMultiple(of: 2), isStarred: false, linkPreview: preview, sentAt: .now,
                                          reply: TimelineReply(author: "Alex", body: "The quoted message, long enough to take both of the quote's lines and then some more."))
            return TimelineRow(message: message, dateHeader: nil, startsRun: true, endsRun: true)
        }
        if older { content.rows.insert(contentsOf: rows, at: 0) } else { content.rows.append(contentsOf: rows) }
        timeline.table.update(content)
        try? await Task.sleep(for: .milliseconds(300))
        report(timeline, "arrive-extras \(argument)")
    }

    /// `resize-drag [<width>x<height> <points> <seconds>]` (760x800 4500 2 without them): a resize, then at once a
    /// gesture, so the records of the resize's end pass land while it scrolls. Every 50 ms through the gesture and
    /// half a second after it, the cells and the rows against the records they show and have their heights from.
    private static func resizeDrag(_ argument: String, timeline: MacTimelineController, window: NSWindow?) async {
        let parts = argument.split(separator: " ").map(String.init)
        guard parts.count == 3, let seconds = Double(parts[2]) else {
            return MacDebugHooks.log("tour resize-drag \(argument): needs <width>x<height> <points> <seconds>")
        }
        await step("resize", parts[0], window: window)
        drag("\(parts[1]) \(parts[2])", timeline: timeline, window: window)
        var samples = 0, cellsOff = 0, rowsOff = 0, standingIn = 0, staged = 0, examples: [String] = []
        let end = CACurrentMediaTime() + seconds + 0.5
        while CACurrentMediaTime() < end {
            try? await Task.sleep(for: .milliseconds(50))
            let geometry = timeline.table.debugGeometry()
            samples += 1
            cellsOff = max(cellsOff, geometry.cellsOff.count)
            rowsOff = max(rowsOff, geometry.rowsOff.count)
            standingIn = max(standingIn, geometry.shownStandIns.count)
            staged = max(staged, geometry.staged)
            if examples.count < 4 { examples += geometry.cellsOff + geometry.rowsOff }
        }
        let after = timeline.table.debugGeometry()
        MacDebugHooks.log("timeline resize-drag \(argument): \(samples) samples, worst \(cellsOff) cells and \(rowsOff) rows off their records \(examples.prefix(4)), "
            + "up to \(standingIn) cells standing in, up to \(staged) records staged; after it \(after.cellsOff.count) cells and \(after.rowsOff.count) rows off, "
            + "\(after.shownStandIns.count) standing in, \(after.staged) staged")
    }

    /// `edit-race`: the reader's row edited to a text long enough to be measured on the queue, its cell made again for
    /// the row as it was before the edit lands, a gesture holding the edit, then the window narrowed to 760 pt, which
    /// lays the row out again from its input at a narrower bubble, and widened back. The edit must not show before it applies, and once applied must
    /// stay in the record, the input and the cell's text.
    private static func editRace(timeline: MacTimelineController, window: NSWindow?) async {
        guard let window, let reader = timeline.table.readerRow(), let index = timeline.content.rows.firstIndex(where: { $0.message.id == reader.id }) else {
            return MacDebugHooks.log("tour edit-race: needs an open timeline with a reader's row")
        }
        var content = timeline.content
        let old = content.rows[index]
        let edited = longText(2_000)
        let message = TimelineMessage(id: old.message.id, body: edited, isOutgoing: old.message.isOutgoing, isStarred: false, sentAt: old.message.sentAt)
        content.rows[index] = TimelineRow(message: message, dateHeader: old.dateHeader, startsRun: old.startsRun, endsRun: old.endsRun)
        timeline.table.update(content)
        // Before the edit lands: the row's cell made again, as scrolling it back into sight would.
        timeline.table.debugRemake(reader.id)
        timeline.debugLiveScroll(true)
        try? await Task.sleep(for: .milliseconds(400))
        timeline.table.debugRemake(reader.id)
        let during = timeline.table.debugText(of: reader.id, edited: edited)
        timeline.debugLiveScroll(false)
        try? await Task.sleep(for: .milliseconds(100))
        let applied = timeline.table.debugText(of: reader.id, edited: edited)
        let size = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(NSSize(width: 760, height: size.height))
        // Laid out again in sight, then past the end of the width's pass.
        try? await Task.sleep(for: .milliseconds(60))
        let narrowing = timeline.table.debugText(of: reader.id, edited: edited)
        try? await Task.sleep(for: .milliseconds(500))
        let narrowed = timeline.table.debugText(of: reader.id, edited: edited)
        window.setContentSize(size)
        try? await Task.sleep(for: .milliseconds(500))
        MacDebugHooks.log("timeline edit-race \(reader.id): during the gesture \(during); applied \(applied); narrowed \(narrowing), after its end pass \(narrowed); "
            + "widened again \(timeline.table.debugText(of: reader.id, edited: edited))")
    }

    /// `overlay-resize [<width>x<height>]`: in one turn, the reader's scroll to the newest message and 2,000 pt up from it,
    /// which brings in the day chip and the jump button, and the window resized; then the window's width every 100 ms.
    /// Their animation once covered the window's whole layout: the split view's columns kept the old width, and SwiftUI
    /// widened the window by the resize again every frame until AppKit aborted.
    private static func overlayResize(_ argument: String, timeline: MacTimelineController, window: NSWindow?) async {
        let size = argument.split(separator: "x").compactMap { Double($0) }
        guard size.count == 2, let window else {
            return MacDebugHooks.log("tour overlay-resize \(argument): needs <width>x<height> and the main window")
        }
        let before = Int(window.contentRect(forFrameRect: window.frame).width)
        timeline.scroll(.bottom)
        timeline.debugScroll(by: 2000)
        let jump = timeline.showsJumpToNewest, chip = timeline.dayChip != nil
        window.setContentSize(NSSize(width: size[0], height: size[1]))
        var widths: [Int] = []
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(100))
            widths.append(Int(window.contentRect(forFrameRect: window.frame).width))
        }
        MacDebugHooks.log("timeline overlay-resize \(argument): \(before) wide, asked \(Int(size[0])), then \(widths); "
            + "jump button \(jump), day chip \(chip) as it resized")
    }

    private static func arrival(_ id: String, _ text: String) -> TimelineRow {
        TimelineRow(message: TimelineMessage(id: id, body: text, isOutgoing: false, isStarred: false, sentAt: .now), dateHeader: nil, startsRun: true, endsRun: true)
    }

    /// A text of about `count` characters that wraps.
    private static func longText(_ count: Int) -> String {
        String(String(repeating: "A long message with wrapping text. ", count: count / 35 + 1).prefix(count))
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
