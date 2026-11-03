#if DEBUG
import AppKit
import ObjectiveC
import SwiftUI

// Debug-only performance tour steps and counters, idle until a tour asks. Passes are main-thread occupancy of an
// off-screen window that nothing composites (no render server, GPU or display-link time); compare only Debug builds
// optimised as Release, running the same tours, and repeat runs, which vary by about 10%.
@MainActor enum MacPerfProbe {
    private static var active = false
    private static var counts: [String: Int] = [:]
    private static var times: [String: (total: Double, worst: Double)] = [:]

    static func count(_ key: String) {
        guard active else { return }
        counts[key, default: 0] += 1
    }

    // Zero, with no clock read, when no measurement runs.
    static func clock() -> CFTimeInterval { active ? CACurrentMediaTime() : 0 }

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
        case "split":
            if let window { logSplit(window, argument) }
        case "split-watch":
            if let window { watchSplit(window, seconds: Double(argument) ?? 1) }
        default: break
        }
    }

    private static var observers: [CFRunLoopObserver] = []
    private static var wokeAt: CFTimeInterval = 0
    private static var passes: [Double] = []
    private static var wokeCPU: CFTimeInterval = 0
    private static var cpuPasses: [Double] = []
    private static var startedAt: CFTimeInterval = 0
    private static var gapTimer: Timer?
    private static var gaps: [Double] = []
    private static var lastTick: CFTimeInterval = 0

    private static func start() {
        counts = [:]
        times = [:]
        passes = []
        cpuPasses = []
        gaps = []
        update = nil
        displayed = []
        sampled = [:]
        active = true
        startedAt = CACurrentMediaTime()
        // The rest of this pass counts, none of what ran before the step in it.
        wokeAt = startedAt
        wokeCPU = cpuTime()
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
            MainActor.assumeIsolated { wokeAt = CACurrentMediaTime(); wokeCPU = cpuTime() }
        }
        // After every other observer, Core Animation's commit (order 2,000,000) among them.
        let sleep = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                displayed.removeAll(keepingCapacity: true)
                guard active, wokeAt > 0 else { return }
                passes.append(CACurrentMediaTime() - wokeAt)
                cpuPasses.append(cpuTime() - wokeCPU)
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
        let stoppedAt = CACurrentMediaTime()
        if wokeAt > 0 { passes.append(stoppedAt - wokeAt); cpuPasses.append(cpuTime() - wokeCPU) }
        active = false
        gapTimer?.invalidate()
        gapTimer = nil
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers = []
        removeHooks()
        let seconds = stoppedAt - startedAt
        let busy = passes.sorted()
        let total = busy.reduce(0, +)
        MacDebugHooks.log("perf \(label): \(String(format: "%.2f", seconds)) s, main thread busy \(ms(total)) ms (\(String(format: "%.0f", 100 * total / max(seconds, 0.001)))%), "
            + "\(busy.count) passes, \(busy.filter { $0 > 0.0005 }.count) over 0.5 ms; pass p50 \(ms(quantile(busy, 0.5))) p90 \(ms(quantile(busy, 0.9))) "
            + "p99 \(ms(quantile(busy, 0.99))) max \(ms(busy.last ?? 0)) ms; over 8.3 ms \(busy.filter { $0 > 1 / 120.0 }.count), "
            + "over 16.7 ms \(busy.filter { $0 > 1 / 60.0 }.count), over 33 ms \(busy.filter { $0 > 1 / 30.0 }.count)")
        let cpu = cpuPasses.sorted()
        MacDebugHooks.log("perf \(label) cpu: busy \(ms(cpu.reduce(0, +))) ms; pass p90 \(ms(quantile(cpu, 0.9))) max \(ms(cpu.last ?? 0)) ms")
        let sortedGaps = gaps.sorted()
        MacDebugHooks.log("perf \(label) timer gaps: \(sortedGaps.count) ticks, over 16.7 ms \(sortedGaps.filter { $0 > 1 / 60.0 }.count), "
            + "over 33 ms \(sortedGaps.filter { $0 > 1 / 30.0 }.count), p95 \(ms(quantile(sortedGaps, 0.95))) ms, max \(ms(sortedGaps.last ?? 0)) ms")
        let counted = counts.sorted { $0.key < $1.key }.map { key, count in
            times[key].map { "\(key)=\(count) (\(ms($0.total)) ms, max \(ms($0.worst)))" } ?? "\(key)=\(count)"
        }
        MacDebugHooks.log("perf \(label) counters: \(counted.joined(separator: ", "))")
    }

    // Unlike the wall clock, it leaves out the time the thread waited for a core.
    static func cpuTime() -> CFTimeInterval { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    private static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1_000) }

    private static var update: (from: Int, to: Int, started: CFTimeInterval, phases: [(name: String, at: CFTimeInterval, cells: Int, extras: Int)])?

    static func beginUpdate(from: Int, to: Int) {
        guard active else { return }
        let now = CACurrentMediaTime()
        update = (from, to, now, [("", now, counts["cell.configure", default: 0], counts["extras.measure", default: 0])])
    }

    static func mark(_ phase: String) {
        guard active, update != nil else { return }
        update?.phases.append((phase, CACurrentMediaTime(), counts["cell.configure", default: 0], counts["extras.measure", default: 0]))
    }

    static func endUpdate() {
        mark("place")
        guard active, let update else { return }
        self.update = nil
        let phases = zip(update.phases.dropFirst(), update.phases).map { phase, previous in
            "\(phase.name) \(ms(phase.at - previous.at)) ms (\(phase.cells - previous.cells) cells, \(phase.extras - previous.extras) extras measured)"
        }
        MacDebugHooks.log("perf update \(update.from) → \(update.to) rows: \(ms(CACurrentMediaTime() - update.started)) ms; \(phases.joined(separator: ", "))")
    }

    private static func forceNoop(_ count: Int) async {
        guard let view = MacTimelineController.current?.table.view else { return MacDebugHooks.log("perf force-noop: no open timeline") }
        var samples: [Double] = []
        for _ in 0..<max(1, count) {
            let started = CACurrentMediaTime()
            view.layoutSubtreeIfNeeded()
            samples.append(CACurrentMediaTime() - started)
            try? await Task.sleep(for: .milliseconds(20))
        }
        samples.sort()
        MacDebugHooks.log("perf force-noop \(samples.count): median \(String(format: "%.2f", quantile(samples, 0.5) * 1_000)) ms, max \(String(format: "%.2f", (samples.last ?? 0) * 1_000)) ms")
    }

    // Two of these logs around a change show what it rebuilt.
    private static func logSplit(_ window: NSWindow, _ label: String) {
        for split in splitViews(in: window.contentView?.superview) {
            let controller = split.delegate as? NSSplitViewController
            let items = controller?.splitViewItems.map { item in
                "\(NSStringFromClass(type(of: item.viewController))) \(address(item.viewController.view)) w \(Int(item.viewController.view.frame.width))"
                    + "\(item.isCollapsed ? " collapsed" : "")\(item.viewController.view.isHidden ? " hidden" : "") behavior \(item.behavior.rawValue)"
            } ?? split.arrangedSubviews.map { "\(NSStringFromClass(type(of: $0))) w \(Int($0.frame.width))" }
            MacDebugHooks.log("split \(label): \(address(split)) \(Int(split.frame.width)) [\(items.joined(separator: "; "))]")
        }
        var chain: [String] = []
        var view = MacTimelineController.current?.table.view as NSView?
        while let current = view {
            let name = NSStringFromClass(type(of: current))
            if name.contains("Hosting") || current is NSScrollView || current is NSSplitView || name.contains("Split") { chain.append("\(name.prefix(60)) \(address(current))") }
            view = current.superview
        }
        let size = MacTimelineController.current?.table.view.frame.size ?? .zero
        MacDebugHooks.log("split \(label) window \(Int(window.frame.width)) content min \(Int(window.contentMinSize.width)), timeline \(Int(size.width))x\(Int(size.height)), chain: \(chain.joined(separator: " < "))")
    }

    private static func watchSplit(_ window: NSWindow, seconds: Double) {
        let splits = splitViews(in: window.contentView?.superview)
        let end = CACurrentMediaTime() + seconds
        var last = "", woke: CFTimeInterval = 0
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, Int.max - 1) { observer, activity in
            MainActor.assumeIsolated {
                if activity == .afterWaiting { woke = CACurrentMediaTime(); return }
                let widths = splits.map { $0.arrangedSubviews.map { "\(Int($0.frame.width))\($0.isHidden ? " hidden" : "")" }.joined(separator: "/") }
                let timeline = MacTimelineController.current?.table.view.frame.width ?? 0
                let state = "window \(Int(window.frame.width)), min \(Int(window.contentMinSize.width)), splits \(widths.joined(separator: " | ")), timeline \(Int(timeline))"
                let pass = woke > 0 ? CACurrentMediaTime() - woke : 0
                if state != last || pass > 0.008 { MacDebugHooks.log("split-watch \(ms(pass)) ms: \(state)") }
                last = state
                if CACurrentMediaTime() > end, let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            }
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    private static func splitViews(in view: NSView?) -> [NSSplitView] {
        guard let view else { return [] }
        return ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews(in:))
    }

    private static func address(_ object: AnyObject) -> String { String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16) }

    private static var hooks: [String: (method: Method, original: IMP)] = [:]
    // A layer counts once per pass however many overrides of `display` it runs through.
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
            hook(NSStringFromClass(cls), cls, #selector(CALayer.display), with: displayCounting)
        }
        if MacDebugHooks.has("-haus-perf-stacks") { installInvalidationStacks() }
        MacDebugHooks.log("perf display-count: counting display on \(hooks.keys.sorted())")
    }

    private static func hook(_ name: String, _ cls: AnyClass, _ selector: Selector, with wrap: (IMP) -> IMP) {
        guard hooks[name] == nil, let method = class_getInstanceMethod(cls, selector) else { return }
        let original = method_getImplementation(method)
        method_setImplementation(method, wrap(original))
        hooks[name] = (method, original)
    }

    // The wrapping blocks stay alive: Core Animation may still be inside one on another thread.
    private static func removeHooks() {
        for hook in hooks.values { method_setImplementation(hook.method, hook.original) }
        hooks = [:]
    }

    // Implemented by `cls` itself, not inherited, so each call is hooked once.
    private static func ownImplementation(_ cls: AnyClass, _ selector: Selector) -> Bool {
        guard let method = class_getInstanceMethod(cls, selector) else { return false }
        guard let superclass = class_getSuperclass(cls), let inherited = class_getInstanceMethod(superclass, selector) else { return true }
        return method_getImplementation(inherited) != method_getImplementation(method)
    }

    // Core Animation may display a layer off the main thread; those go uncounted.
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

    private static var sampled: [String: Int] = [:]

    // Symbolicating a stack stalls the main thread for milliseconds: never time a run with `-haus-perf-stacks`.
    private static func installInvalidationStacks() {
        let classes = [CALayer.self, NSClassFromString("NSViewBackingLayer"), NSClassFromString("ContentLayer"), NSClassFromString("_NSTextViewBackingLayer")].compactMap { $0 }
        for cls in classes {
            for (selector, name) in [(#selector(CALayer.setNeedsDisplay as (CALayer) -> () -> Void), "setNeedsDisplay"), (#selector(CALayer.setNeedsDisplay(_:)), "setNeedsDisplayInRect")] {
                guard cls == CALayer.self || ownImplementation(cls, selector) else { continue }
                hook("\(cls).\(name)", cls, selector) { marking($0, selector: selector, name: name) }
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
        // From the first frame outside this probe and its hook.
        let frames = Thread.callStackSymbols.drop { $0.contains("MacPerfProbe") || $0.contains("assumeIsolated") }.prefix(24).map { line -> String in
            // "3   AppKit   0x… symbol + 12": keep the module and the symbol.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count > 3 ? "\(parts[1]):\(parts[3...].joined(separator: " "))" : line
        }
        MacDebugHooks.log("perf stack \(key) #\(n): " + frames.joined(separator: " <- "))
    }

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

    private static func sidebarSplit(_ window: NSWindow) -> (NSSplitView, NSSplitViewController, NSSplitViewItem)? {
        for split in splitViews(in: window.contentView?.superview) {
            if let controller = split.delegate as? NSSplitViewController, let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) {
                return (split, controller, item)
            }
        }
        return nil
    }

    private static func toggleSidebar(_ window: NSWindow) async {
        guard let (split, controller, item) = sidebarSplit(window) else { return MacDebugHooks.log("perf sidebar: no split view with a sidebar") }
        func sample() -> (sidebar: Double, timeline: Double) {
            (split.arrangedSubviews.first.map { Double($0.frame.width) } ?? -1, Double(MacTimelineController.current?.table.view.frame.width ?? -1))
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
        var synchronous: [Double] = [], whole: [Double] = [], cpu: [Double] = []
        for step in 0...(2 * steps) {
            let started = CACurrentMediaTime(), startedCPU = cpuTime()
            split.setPosition(width * abs(1 - Double(step) / Double(steps)), ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            synchronous.append(CACurrentMediaTime() - started)
            cpu.append(cpuTime() - startedCPU)
            try? await Task.sleep(for: .milliseconds(8))
            whole.append(CACurrentMediaTime() - started)
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return "median \(ms(quantile(sorted, 0.5))) ms, p90 \(ms(quantile(sorted, 0.9))) ms, worst \(ms(sorted.last ?? 0)) ms, total \(ms(sorted.reduce(0, +))) ms"
        }
        MacDebugHooks.log("perf sidebar-sweep \(steps) steps from \(Int(width)) pt: step \(summary(synchronous)); with the next turns \(summary(whole)); step CPU \(summary(cpu))")
    }
}
#endif
