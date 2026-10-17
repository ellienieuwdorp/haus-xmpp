#if DEBUG
import AppKit
import ObjectiveC
import SwiftUI

/// Performance tour steps (`-haus-tour`; see `MacDebugHooks`) and the counters the timeline's views and controller bump.
/// Debug builds only; nothing here ships, and nothing here runs or costs anything until a tour asks for it.
///
/// Steps:
/// - `perf start` / `perf stop <label>`: between the two, every pass of the main run loop is timed from waking to going
///   back to sleep (after Core Animation's commit), in the common modes, and a 120 Hz common-mode timer logs how late its
///   ticks ran. `stop` logs the busy time and share, the pass p50/p90/p99/max, the passes over 8.3, 16.7 and 33 ms, the
///   timer's gaps over 16.7 and 33 ms with p95 and max, and the counters, which `start` resets. Counters are only bumped
///   between the two: `row.body` (message row bodies), `text.make`, `text.update` and `text.size` (bubble text views made,
///   updated and asked for a size, with their time), `text.miss` (sizes not in the measurement cache), `ctl.resized`,
///   `ctl.scrolled` and `ctl.force` (the timeline controller's size and geometry callbacks and its forced layouts).
/// - `perf update` lines, logged on their own between `perf start` and `perf stop`: each timeline update that keeps
///   the reader's place, split into phases (the forced layout before it, applying the rows, the forced layout after it,
///   and the hold or scroll that follows), with the time, rows built and text views made in each.
/// - `display-count`: from then on, `perf stop` also counts the layers that redraw their contents (`-[CALayer display]`
///   and every override of it in the window's layer classes) as `display <layer class>/<delegate class>`, a layer with no
///   delegate under the nearest ancestor's delegate in brackets; each layer counts once per run-loop pass. With
///   `-haus-perf-stacks` it also logs sampled call stacks that mark a bubble text view's layers as needing display.
///   Symbolicating a stack stalls the main thread for milliseconds, so never time a run that passes that flag.
/// - `layers`: the main window's views and layers by class, the bubble text views (all and visible), and the layers the
///   render server draws offscreen or samples behind them (filters, background filters, masks, unbounded shadows).
/// - `sidebar`: toggles the sidebar as View › Hide Sidebar does (`NSSplitViewController.toggleSidebar`), and logs each
///   distinct sidebar and timeline width with its time until the animation settles.
/// - `sidebar-sweep <steps>`: moves the sidebar's divider from its width to zero and back in even steps, one every
///   8 ms, each laid out, displayed and committed at once, and logs the step times.
/// - `force-noop <count>`: times the timeline's forced layout with nothing pending, the fixed cost of each correction.
/// The timeline's own steps (`MacTimelineDebug`, `MacDebugHooks.ScrollProbe`) drive the scenarios: `scroll <seconds>
/// [paging]`, `scroll by <points>`, `drag <points> <seconds>`, `resize-sweep`.
///
/// Performance runs:
/// - Build the Debug configuration optimised as Release is, so the tour steps exist but the code is what ships: an
///   xcconfig file with `SWIFT_OPTIMIZATION_LEVEL = -O`, `SWIFT_COMPILATION_MODE = wholemodule` and
///   `GCC_OPTIMIZATION_LEVEL = s`, named by `XCODE_XCCONFIG_FILE` in the environment of the `HausXMPPMac` build. Plain
///   Debug numbers are several times slower and not comparable.
/// - Run with `-haus-unobtrusive -demo -demo-long -haus-window-size 1200x800` on a fresh test store, one tour per run,
///   in this order, so that each run's numbers compare with earlier runs':
///   1. Scrolling: `select history@preview.local; wait 3; force-noop 20; perf start; scroll 8; perf stop cold;
///      perf start; scroll 10 paging; perf stop paging; timeline; wait 1; perf start; scroll 8; perf stop warm-a;
///      perf start; scroll 8; perf stop warm-b` (the first sweep builds 100 rows; paging loads all 250 and logs its
///      `perf update` lines; the warm sweeps run over 250).
///   2. Width changes and switching: `wait 3; perf start; sidebar-sweep 30; perf stop sweep-none; perf start;
///      resize-sweep 1200x800 900x800 60; perf stop resize-none; size 1200x800; select history@preview.local; wait 3;
///      perf start; sidebar-sweep 30; perf stop sweep-history; perf start; resize-sweep 1200x800 900x800 60;
///      perf stop resize-history; size 1200x800; wait 1; perf start; sidebar; perf stop hide; wait 0.5; perf start;
///      sidebar; perf stop show; wait 0.5; perf start; select alex@preview.local; wait 1; perf stop switch-alex;
///      perf start; select history@preview.local; wait 1; perf stop switch-history; wait 1; perf start; inspector;
///      wait 1; perf stop inspector-open; perf start; inspector off; wait 1; perf stop inspector-close`.
///   3. Narrow inspector and a jump: `size 1000x720; select history@preview.local; wait 3; perf start; inspector;
///      wait 1; perf stop narrow-open; perf start; inspector off; wait 1; perf stop narrow-close; perf start;
///      scroll by 3000; wait 0.5; perf stop jump-3000`.
///   4. Layer displays, apart from any timing (the counter's hooks cost time): `select history@preview.local; wait 3;
///      display-count; layers; perf start; scroll 6; perf stop display`.
/// - What the numbers are not: the window is off-screen, transparent and never key, so nothing composites it. There is
///   no render server, GPU or display-link time in any of this, and animations run on a fallback driver, not at the
///   display's refresh rate. Pass times are main-thread occupancy, not presented frames; a pass over 8.3 ms is not a
///   dropped frame, and a run-loop pass is not a frame. Timer gaps say how late the main thread ran, not how busy it
///   was. `display-count` counts display calls, not changed backing stores or texture uploads. The sweeps move the clip
///   view directly, with none of a trackpad's momentum or phases. Single runs on a shared machine vary by about 10%;
///   note the load average and repeat a run before trusting a smaller difference.
@MainActor enum MacPerfProbe {
    private static var active = false
    private static var counts: [String: Int] = [:]
    private static var times: [String: (total: Double, worst: Double)] = [:]

    static func count(_ key: String) {
        guard active else { return }
        counts[key, default: 0] += 1
    }

    /// The start of a timed call, for `add(_:since:)`; zero, and no clock read, when no measurement runs.
    static func clock() -> CFTimeInterval { active ? CACurrentMediaTime() : 0 }

    /// Counts `key` and adds the time since `start` to it.
    static func add(_ key: String, since start: CFTimeInterval) {
        guard active, start > 0 else { return }
        let elapsed = CACurrentMediaTime() - start
        counts[key, default: 0] += 1
        let time = times[key] ?? (0, 0)
        times[key] = (time.total + elapsed, max(time.worst, elapsed))
    }

    static func step(_ name: String, _ argument: String, window: NSWindow?) async {
        switch name {
        case "perf":
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            if words.first == "start" { start() } else { stop(words.count > 1 ? words[1] : "") }
        case "display-count":
            if let window { installDisplayCounter(window) }
        case "layers":
            if let window { logLayers(window) }
        case "sidebar":
            if let window { await toggleSidebar(window) }
        case "sidebar-sweep":
            if let window { await sidebarSweep(window, steps: Int(argument) ?? 30) }
        case "force-noop":
            await forceNoop(Int(argument) ?? 20)
        default: break
        }
    }

    // MARK: Run-loop passes

    private static var observers: [CFRunLoopObserver] = []
    private static var wokeAt: CFTimeInterval = 0
    private static var passes: [Double] = []
    private static var startedAt: CFTimeInterval = 0
    private static var gapTimer: Timer?
    private static var gaps: [Double] = []
    private static var lastTick: CFTimeInterval = 0

    private static func start() {
        counts = [:]
        times = [:]
        passes = []
        gaps = []
        update = nil
        displayed = []
        sampled = [:]
        active = true
        startedAt = CACurrentMediaTime()
        lastTick = startedAt
        gapTimer?.invalidate()
        let timer = Timer(timeInterval: 1 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                gaps.append(now - lastTick)
                lastTick = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        gapTimer = timer
        guard observers.isEmpty else { return }
        let wake = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated { wokeAt = CACurrentMediaTime() }
        }
        // After every other observer, Core Animation's commit (order 2,000,000) among them.
        let sleep = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                displayed.removeAll(keepingCapacity: true)
                guard active, wokeAt > 0 else { return }
                passes.append(CACurrentMediaTime() - wokeAt)
                wokeAt = 0
            }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    private static func stop(_ label: String) {
        guard active else { return MacDebugHooks.log("perf stop \(label): no perf start") }
        active = false
        gapTimer?.invalidate()
        gapTimer = nil
        let seconds = CACurrentMediaTime() - startedAt
        let busy = passes.sorted()
        let total = busy.reduce(0, +)
        MacDebugHooks.log("perf \(label): \(String(format: "%.2f", seconds)) s, main thread busy \(ms(total)) ms (\(String(format: "%.0f", 100 * total / max(seconds, 0.001)))%), "
            + "\(busy.count) passes, \(busy.filter { $0 > 0.0005 }.count) over 0.5 ms; pass p50 \(ms(quantile(busy, 0.5))) p90 \(ms(quantile(busy, 0.9))) "
            + "p99 \(ms(quantile(busy, 0.99))) max \(ms(busy.last ?? 0)) ms; over 8.3 ms \(busy.filter { $0 > 1 / 120.0 }.count), "
            + "over 16.7 ms \(busy.filter { $0 > 1 / 60.0 }.count), over 33 ms \(busy.filter { $0 > 1 / 30.0 }.count)")
        let sortedGaps = gaps.sorted()
        MacDebugHooks.log("perf \(label) timer gaps: \(sortedGaps.count) ticks, over 16.7 ms \(sortedGaps.filter { $0 > 1 / 60.0 }.count), "
            + "over 33 ms \(sortedGaps.filter { $0 > 1 / 30.0 }.count), p95 \(ms(quantile(sortedGaps, 0.95))) ms, max \(ms(sortedGaps.last ?? 0)) ms")
        let counted = counts.sorted { $0.key < $1.key }.map { key, count in
            times[key].map { "\(key)=\(count) (\(ms($0.total)) ms, max \(ms($0.worst)))" } ?? "\(key)=\(count)"
        }
        MacDebugHooks.log("perf \(label) counters: \(counted.joined(separator: ", "))")
    }

    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    private static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1_000) }

    // MARK: Timeline updates

    private static var update: (from: Int, to: Int, started: CFTimeInterval, forces: Int, phases: [(name: String, at: CFTimeInterval, rows: Int, made: Int)])?

    /// The start of a timeline update from `from` rows to `to`; `mark` ends each phase, `endUpdate` the last one.
    static func beginUpdate(from: Int, to: Int) {
        guard active else { return }
        let now = CACurrentMediaTime()
        update = (from, to, now, counts["ctl.force", default: 0], [("", now, counts["row.body", default: 0], counts["text.make", default: 0])])
    }

    static func mark(_ phase: String) {
        guard active, update != nil else { return }
        update?.phases.append((phase, CACurrentMediaTime(), counts["row.body", default: 0], counts["text.make", default: 0]))
    }

    static func endUpdate() {
        mark("hold")
        guard active, let update else { return }
        self.update = nil
        let phases = zip(update.phases.dropFirst(), update.phases).map { phase, previous in
            "\(phase.name) \(ms(phase.at - previous.at)) ms (\(phase.rows - previous.rows) rows, \(phase.made - previous.made) text views)"
        }
        MacDebugHooks.log("perf update \(update.from) → \(update.to) rows: \(ms(CACurrentMediaTime() - update.started)) ms, "
            + "\(counts["ctl.force", default: 0] - update.forces) forced layouts; \(phases.joined(separator: ", "))")
    }

    private static func forceNoop(_ count: Int) async {
        guard let layout = MacTimelineController.current?.layout else { return MacDebugHooks.log("perf force-noop: no open timeline") }
        var samples: [Double] = []
        for _ in 0..<max(1, count) {
            let started = CACurrentMediaTime()
            layout.forceLayout()
            samples.append(CACurrentMediaTime() - started)
            try? await Task.sleep(for: .milliseconds(20))
        }
        samples.sort()
        MacDebugHooks.log("perf force-noop \(samples.count): median \(String(format: "%.2f", quantile(samples, 0.5) * 1_000)) ms, max \(String(format: "%.2f", (samples.last ?? 0) * 1_000)) ms")
    }

    // MARK: Layer displays

    private static var swizzled: Set<String> = []
    /// The layers that displayed in this run-loop pass, so a layer counts once per pass however many overrides of
    /// `display` it runs through.
    private static var displayed: Set<ObjectIdentifier> = []

    private static func installDisplayCounter(_ window: NSWindow) {
        guard let root = window.contentView?.superview?.layer else { return }
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(CALayer.self)]
        var classes: [AnyClass] = [CALayer.self]
        func walk(_ layer: CALayer) {
            var cls: AnyClass? = type(of: layer)
            while let current = cls, current != CALayer.self {
                if seen.insert(ObjectIdentifier(current)).inserted { classes.append(current) }
                cls = class_getSuperclass(current)
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        for cls in classes where ownImplementation(cls, #selector(CALayer.display)) {
            let name = NSStringFromClass(cls)
            guard swizzled.insert(name).inserted, let method = class_getInstanceMethod(cls, #selector(CALayer.display)) else { continue }
            method_setImplementation(method, displayCounting(method_getImplementation(method)))
        }
        if MacDebugHooks.has("-haus-perf-stacks") { installInvalidationStacks() }
        MacDebugHooks.log("perf display-count: counting display on \(swizzled.sorted())")
    }

    /// Whether `cls` implements `selector` itself rather than inheriting it, so each call is hooked once.
    private static func ownImplementation(_ cls: AnyClass, _ selector: Selector) -> Bool {
        guard let method = class_getInstanceMethod(cls, selector) else { return false }
        guard let superclass = class_getSuperclass(cls), let inherited = class_getInstanceMethod(superclass, selector) else { return true }
        return method_getImplementation(inherited) != method_getImplementation(method)
    }

    /// Core Animation may display a layer off the main thread; those go uncounted.
    private nonisolated static func displayCounting(_ implementation: IMP) -> IMP {
        typealias Display = @convention(c) (CALayer, Selector) -> Void
        let original = unsafeBitCast(implementation, to: Display.self)
        let block: @convention(block) (CALayer) -> Void = { layer in
            // Only read on the main thread, which is where this call runs when it is counted.
            nonisolated(unsafe) let counted = layer
            if Thread.isMainThread { MainActor.assumeIsolated { noteDisplay(counted) } }
            original(layer, #selector(CALayer.display))
        }
        return imp_implementationWithBlock(block)
    }

    private static func noteDisplay(_ layer: CALayer) {
        guard active, displayed.insert(ObjectIdentifier(layer)).inserted else { return }
        let owner: String
        if let delegate = layer.delegate {
            owner = String(describing: type(of: delegate))
        } else {
            var ancestor = layer.superlayer
            while let current = ancestor, current.delegate == nil { ancestor = current.superlayer }
            owner = "(\(ancestor?.delegate.map { String(describing: type(of: $0)) } ?? "-"))"
        }
        count("display \(String(describing: type(of: layer)))/\(owner.prefix(60))")
    }

    // MARK: Invalidation stacks

    private static var sampled: [String: Int] = [:]

    /// Hooks `-[CALayer setNeedsDisplay]` and `-[CALayer setNeedsDisplayInRect:]` on the layer classes a bubble text view
    /// uses, to count the marks on its layers and log the stacks of the first three of each kind and every 500th.
    private static func installInvalidationStacks() {
        let classes = [CALayer.self, NSClassFromString("NSViewBackingLayer"), NSClassFromString("ContentLayer"), NSClassFromString("_NSTextViewBackingLayer")].compactMap { $0 }
        for cls in classes {
            for (selector, name) in [(#selector(CALayer.setNeedsDisplay as (CALayer) -> () -> Void), "setNeedsDisplay"), (#selector(CALayer.setNeedsDisplay(_:)), "setNeedsDisplayInRect")] {
                guard cls == CALayer.self || ownImplementation(cls, selector), swizzled.insert("\(cls).\(name)").inserted,
                      let method = class_getInstanceMethod(cls, selector) else { continue }
                method_setImplementation(method, marking(method_getImplementation(method), selector: selector, name: name))
            }
        }
    }

    private nonisolated static func marking(_ implementation: IMP, selector: Selector, name: String) -> IMP {
        if name == "setNeedsDisplay" {
            typealias Mark = @convention(c) (CALayer, Selector) -> Void
            let original = unsafeBitCast(implementation, to: Mark.self)
            let block: @convention(block) (CALayer) -> Void = { layer in
                nonisolated(unsafe) let marked = layer
                if Thread.isMainThread { MainActor.assumeIsolated { noteMark(marked, name) } }
                original(layer, selector)
            }
            return imp_implementationWithBlock(block)
        }
        typealias Mark = @convention(c) (CALayer, Selector, CGRect) -> Void
        let original = unsafeBitCast(implementation, to: Mark.self)
        let block: @convention(block) (CALayer, CGRect) -> Void = { layer, rect in
            nonisolated(unsafe) let marked = layer
            if Thread.isMainThread { MainActor.assumeIsolated { noteMark(marked, name) } }
            original(layer, selector, rect)
        }
        return imp_implementationWithBlock(block)
    }

    private static func noteMark(_ layer: CALayer, _ name: String) {
        guard active else { return }
        var owner: CALayer? = layer
        for _ in 0..<3 where !(owner?.delegate is BubbleTextView) { owner = owner?.superlayer }
        guard owner?.delegate is BubbleTextView else { return }
        let key = "mark \(String(describing: type(of: layer))).\(name)"
        count(key)
        let n = sampled[key, default: 0]
        sampled[key] = n + 1
        guard n < 3 || n.isMultiple(of: 500) else { return }
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(28).map { line -> String in
            // "3   AppKit   0x… symbol + 12": keep the module and the symbol.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count > 3 ? "\(parts[1]):\(parts[3...].joined(separator: " "))" : line
        }
        MacDebugHooks.log("perf stack \(key) #\(n): " + frames.joined(separator: " <- "))
    }

    // MARK: Layers

    private static func logLayers(_ window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        var views: [String: Int] = [:]
        var viewCount = 0, hiddenViews = 0, texts = 0, visibleTexts = 0
        func walkViews(_ view: NSView) {
            viewCount += 1
            if view.isHidden { hiddenViews += 1 }
            if view is BubbleTextView {
                texts += 1
                if !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty { visibleTexts += 1 }
            }
            views[String(describing: type(of: view)), default: 0] += 1
            view.subviews.forEach(walkViews)
        }
        walkViews(frameView)
        var layers: [String: Int] = [:], notable: [String: Int] = [:]
        var layerCount = 0, hiddenLayers = 0, filters = 0, backgroundFilters = 0, masks = 0, shadows = 0, backed = 0, backingPixels = 0.0
        func walkLayers(_ layer: CALayer) {
            layerCount += 1
            if layer.isHidden { hiddenLayers += 1 }
            let name = String(describing: type(of: layer))
            layers[name, default: 0] += 1
            if !(layer.filters ?? []).isEmpty { filters += 1; notable["filters " + name, default: 0] += 1 }
            if !(layer.backgroundFilters ?? []).isEmpty { backgroundFilters += 1; notable["backgroundFilters " + name, default: 0] += 1 }
            if layer.mask != nil { masks += 1; notable["mask on " + name, default: 0] += 1 }
            if layer.shadowOpacity > 0, layer.shadowPath == nil { shadows += 1; notable["shadow " + name, default: 0] += 1 }
            if layer.contents != nil {
                backed += 1
                backingPixels += layer.bounds.width * layer.bounds.height * layer.contentsScale * layer.contentsScale
            }
            layer.sublayers?.forEach(walkLayers)
        }
        if let root = frameView.layer { walkLayers(root) }
        func top(_ counts: [String: Int], _ n: Int) -> String { counts.sorted { $0.value > $1.value }.prefix(n).map { "\($0.key)×\($0.value)" }.joined(separator: ", ") }
        MacDebugHooks.log("perf layers: \(viewCount) views (\(hiddenViews) hidden), \(texts) bubble text views (\(visibleTexts) visible): \(top(views, 18))")
        MacDebugHooks.log("perf layers: \(layerCount) layers (\(hiddenLayers) hidden), \(backed) with contents (\(String(format: "%.1f", backingPixels / 1_000_000)) Mpx): \(top(layers, 14))")
        MacDebugHooks.log("perf layers: filters \(filters), background filters \(backgroundFilters), masks \(masks), unbounded shadows \(shadows); \(top(notable, 20))")
    }

    // MARK: Sidebar

    /// The split view whose controller has a sidebar item: the `NavigationSplitView`'s.
    private static func sidebarSplit(_ window: NSWindow) -> (NSSplitView, NSSplitViewController, NSSplitViewItem)? {
        func splitViews(in view: NSView) -> [NSSplitView] { ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews(in:)) }
        for split in splitViews(in: window.contentView?.superview ?? NSView()) {
            if let controller = split.delegate as? NSSplitViewController, let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) {
                return (split, controller, item)
            }
        }
        return nil
    }

    private static func toggleSidebar(_ window: NSWindow) async {
        guard let (split, controller, item) = sidebarSplit(window) else { return MacDebugHooks.log("perf sidebar: no split view with a sidebar") }
        func sample() -> (sidebar: Double, timeline: Double) {
            (split.arrangedSubviews.first.map { Double($0.frame.width) } ?? -1, Double(MacTimelineController.current?.layout.size.width ?? -1))
        }
        var changes: [(t: Double, sidebar: Double, timeline: Double)] = []
        let started = CACurrentMediaTime()
        let wasCollapsed = item.isCollapsed
        controller.toggleSidebar(nil)
        var last = sample()
        var lastChange = started
        while CACurrentMediaTime() - started < 3 {
            try? await Task.sleep(for: .milliseconds(2))
            let now = sample()
            if now != last {
                changes.append(((CACurrentMediaTime() - started) * 1_000, now.sidebar, now.timeline))
                last = now
                lastChange = CACurrentMediaTime()
            } else if CACurrentMediaTime() - lastChange > 0.6, item.isCollapsed != wasCollapsed {
                break
            }
        }
        let gaps = zip(changes.dropFirst(), changes).map { $0.t - $1.t }
        MacDebugHooks.log(String(format: "perf sidebar: %@ in %.0f ms, %d distinct widths, first after %.0f ms, largest gap %.0f ms: ", wasCollapsed ? "shown" : "hidden",
                                 (lastChange - started) * 1_000, changes.count, changes.first?.t ?? 0, gaps.max() ?? 0)
            + changes.map { String(format: "%.0fms:%.0f/%.0f", $0.t, $0.sidebar, $0.timeline) }.joined(separator: " "))
    }

    private static func sidebarSweep(_ window: NSWindow, steps: Int) async {
        guard steps > 0, let (split, _, _) = sidebarSplit(window), let first = split.arrangedSubviews.first else {
            return MacDebugHooks.log("perf sidebar-sweep: needs <steps> and a split view with a sidebar")
        }
        let width = first.frame.width
        var synchronous: [Double] = [], whole: [Double] = []
        for step in 0...(2 * steps) {
            let started = CACurrentMediaTime()
            split.setPosition(width * abs(1 - Double(step) / Double(steps)), ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            synchronous.append(CACurrentMediaTime() - started)
            try? await Task.sleep(for: .milliseconds(8))
            whole.append(CACurrentMediaTime() - started)
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return "median \(ms(quantile(sorted, 0.5))) ms, p90 \(ms(quantile(sorted, 0.9))) ms, worst \(ms(sorted.last ?? 0)) ms, total \(ms(sorted.reduce(0, +))) ms"
        }
        MacDebugHooks.log("perf sidebar-sweep \(steps) steps from \(Int(width)) pt: step \(summary(synchronous)); with the next turns \(summary(whole))")
    }
}
#endif
