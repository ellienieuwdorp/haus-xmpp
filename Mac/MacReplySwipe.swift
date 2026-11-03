import AppKit

// A two-finger gesture's first points decide once whether it is a reply swipe (moved right and mostly sideways, as the
// iPhone's reply pan begins) or a scroll. Distances follow the fingers, whatever the scroll-direction setting.
struct MacReplySwipeLock {
    enum Decision: Equatable { case undecided, swipe, scroll }

    // A trackpad's first events are a point or two.
    static let slop: CGFloat = 5

    private(set) var x: CGFloat = 0
    private(set) var y: CGFloat = 0

    mutating func add(x: CGFloat, y: CGFloat) -> Decision {
        self.x += x
        self.y += y
        guard hypot(self.x, self.y) >= Self.slop else { return .undecided }
        return self.x > 0 && self.x > 1.5 * abs(self.y) ? .swipe : .scroll
    }
}

// Scroll events reach `handle` through the table's local event monitor before the scroll view (no `scrollWheel`
// override, which responsive scrolling needs). A gesture over a repliable message is held back until decided: a scroll
// gets its events back in order; a swipe keeps the gesture and its momentum. Phaseless wheel events never swipe.
@MainActor final class MacReplySwipe {
    static let threshold: CGFloat = 56
    static let cap: CGFloat = 80

    static func offset(for distance: CGFloat) -> CGFloat { min(cap, max(0, distance)) }

    var cellAt: (NSPoint) -> MacTimelineMessageCell? = { _ in nil }
    // Not while the timeline still moves from a scroll or its momentum, nor with a mouse button down.
    var mayStart: () -> Bool = { false }
    var ended: () -> Void = {}

    private enum State {
        case idle
        case scrolling
        case deciding(Pending)
        case swiping(Swipe)
        case finished
    }

    private struct Pending {
        let cell: MacTimelineMessageCell
        let id: String
        var lock = MacReplySwipeLock()
        var held: [NSEvent] = []
    }

    private struct Swipe {
        let cell: MacTimelineMessageCell
        let id: String
        var distance: CGFloat
        // The haptic plays again only after falling back under the threshold.
        var armed: Bool
    }

    private var state = State.idle
    private var lastPhase: NSEvent.Phase = []
    // Held events handed back may come through the monitor again: they pass.
    private var releasing = false

    #if DEBUG
    struct DebugRecord {
        var claimed = false
        var maxOffset: CGFloat = 0
        var replied = false
        var haptics = 0
        var consumed = 0
        var passed = 0
        var cancelled = false
    }

    private(set) var debugRecord = DebugRecord()
    var debugReleased = 0
    var debugIsSwiping: Bool { if case .swiping = state { true } else { false } }
    #endif

    // True when the swipe keeps the event; `pass` hands held events back to the scroll view in order.
    func handle(_ event: NSEvent, at point: NSPoint, pass: (NSEvent) -> Void) -> Bool {
        guard !releasing else { return false }
        let consumed = route(event, at: point, pass: pass)
        #if DEBUG
        if consumed { debugRecord.consumed += 1 } else { debugRecord.passed += 1 }
        #endif
        return consumed
    }

    private func route(_ event: NSEvent, at point: NSPoint, pass: (NSEvent) -> Void) -> Bool {
        let phase = event.phase, momentum = event.momentumPhase
        defer { if !phase.isEmpty { lastPhase = phase } }
        // A wheel or an old-style event, with no phases: never a swipe, and no part of one.
        if phase.isEmpty, momentum.isEmpty {
            if case .swiping = state { cancel() }
            #if DEBUG
            debugRecord = DebugRecord()
            #endif
            state = .idle
            return false
        }
        // A new gesture, unless it is the one whose `mayBegin` came just before; a swipe whose end never came ends
        // here.
        if phase == .mayBegin || phase == .began && lastPhase != .mayBegin {
            cancel()
            state = start(event, at: point)
        }
        switch state {
        case .idle, .scrolling:
            return false
        case .finished:
            if momentum == .ended || momentum == .cancelled { state = .idle }
            return true
        case .deciding(var pending):
            guard momentum.isEmpty, phase != .ended, phase != .cancelled, isCurrent(pending.cell, pending.id) else {
                // Lifted, or the row changed, before the gesture said which it was: a scroll's after all.
                release(pending, pass: pass)
                return false
            }
            pending.held.append(event)
            switch pending.lock.add(x: Self.fingerX(event), y: event.scrollingDeltaY) {
            case .undecided:
                state = .deciding(pending)
                return true
            case .scroll:
                pending.held.removeLast()
                release(pending, pass: pass)
                return false
            case .swipe:
                var swipe = Swipe(cell: pending.cell, id: pending.id, distance: 0, armed: false)
                pending.cell.beginSwipe()
                #if DEBUG
                debugRecord.claimed = true
                #endif
                move(&swipe, by: pending.lock.x)
                state = .swiping(swipe)
                return true
            }
        case .swiping(var swipe):
            guard isCurrent(swipe.cell, swipe.id) else {
                cancel()
                return true
            }
            switch phase {
            case .ended:
                // Unsent while the fingers were down: no reply after all.
                let replies = Self.offset(for: swipe.distance) >= Self.threshold && swipe.cell.takesReplySwipe
                finish(swipe.cell, replied: replies)
                if replies { swipe.cell.perform(.reply, link: nil) }
            case .cancelled:
                #if DEBUG
                debugRecord.cancelled = true
                #endif
                finish(swipe.cell, replied: false)
            case .changed:
                move(&swipe, by: Self.fingerX(event))
                state = .swiping(swipe)
            default:
                break
            }
            return true
        }
    }

    private func start(_ event: NSEvent, at point: NSPoint) -> State {
        #if DEBUG
        debugRecord = DebugRecord()
        #endif
        guard event.hasPreciseScrollingDeltas, mayStart(), let cell = cellAt(point), let id = cell.message?.id else { return .scrolling }
        return .deciding(Pending(cell: cell, id: id))
    }

    private func release(_ pending: Pending, pass: (NSEvent) -> Void) {
        state = .scrolling
        releasing = true
        pending.held.forEach(pass)
        releasing = false
    }

    private func move(_ swipe: inout Swipe, by x: CGFloat) {
        swipe.distance += x
        let offset = Self.offset(for: swipe.distance)
        swipe.cell.swipeOffset = offset
        #if DEBUG
        debugRecord.maxOffset = max(debugRecord.maxOffset, offset)
        #endif
        if offset >= Self.threshold, !swipe.armed {
            swipe.armed = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            #if DEBUG
            debugRecord.haptics += 1
            #endif
        } else if offset < Self.threshold {
            swipe.armed = false
        }
    }

    private func finish(_ cell: MacTimelineMessageCell, replied: Bool) {
        state = .finished
        cell.endSwipe(animated: true)
        #if DEBUG
        debugRecord.replied = replied
        #endif
        ended()
    }

    // The bubble snaps back; the rest of the gesture is kept from the scroll view, which never saw its start.
    func cancel() {
        switch state {
        case .swiping(let swipe):
            swipe.cell.endSwipe(animated: false)
            #if DEBUG
            debugRecord.cancelled = true
            if MacUnobtrusive.isOn { MacDebugHooks.log("reply swipe on \(swipe.id) given up, offset \(swipe.cell.swipeOffset)") }
            #endif
            state = .finished
            ended()
        case .deciding:
            state = .finished
        case .idle, .scrolling, .finished:
            break
        }
    }

    // A swipe belongs to its message: a reused row, or one leaving the table, ends it without replying.
    private func isCurrent(_ cell: MacTimelineMessageCell, _ id: String) -> Bool {
        cell.window != nil && cell.message?.id == id
    }

    // Natural scrolling reports deltas that follow the fingers; with it off they are the other way round.
    static func fingerX(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    }
}
