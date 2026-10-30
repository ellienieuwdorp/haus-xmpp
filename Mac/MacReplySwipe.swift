import AppKit

/// The first points of a two-finger gesture over a message decide, once and for the gesture's whole life, whether it is
/// a reply swipe or a scroll: a swipe when the fingers moved right and mostly sideways, as the iPhone's reply pan begins,
/// a scroll otherwise. Distances are in the fingers' direction, whatever the scroll-direction setting.
struct MacReplySwipeLock {
    enum Decision: Equatable { case undecided, swipe, scroll }

    /// How far the fingers move before the gesture is told apart; a trackpad's first events are a point or two.
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

/// Swipe right with two fingers on a message to reply, as in Messages on the Mac and as the iPhone's rightward pan does.
///
/// The timeline's scroll events pass through `handle` before the scroll view sees them (the table's local event
/// monitor; the table keeps no `scrollWheel` override, which responsive scrolling needs). A gesture that starts over a
/// message that can be replied to is held back for its first few points (`MacReplySwipeLock`): a scroll gets them back,
/// in order, and the rest of its events and momentum pass untouched; a swipe keeps every event of the gesture and its
/// momentum, so the timeline does not move. A mouse's notched wheel and gestures with no phases never swipe.
///
/// The bubble follows the fingers right, up to `cap`; from `threshold` the reply arrow is whole, a haptic marks the
/// crossing, and lifting the fingers there replies through the cell's own Reply, as its toolbar and menu do. The swipe
/// belongs to the message it started on: if its row is given another message or leaves the table, or the app or the
/// view goes away, it ends without replying.
@MainActor final class MacReplySwipe {
    /// The finger distance at which a release replies, as on the iPhone.
    static let threshold: CGFloat = 56
    /// The farthest the bubble travels.
    static let cap: CGFloat = 80

    /// How far the bubble has travelled after the fingers moved `distance` right.
    static func offset(for distance: CGFloat) -> CGFloat { min(cap, max(0, distance)) }

    /// The message cell under a point in the table's coordinates, if a swipe there replies to it.
    var cellAt: (NSPoint) -> MacTimelineMessageCell? = { _ in nil }
    /// Whether a gesture beginning now may be a swipe: not while the timeline is still moving from a scroll or its
    /// momentum, nor with a mouse button down.
    var mayStart: () -> Bool = { false }
    /// A swipe ended, replying or not: the pointer's row may show its toolbar again.
    var ended: () -> Void = {}

    private enum State {
        case idle
        /// Not a swipe: the gesture and its momentum go to the scroll view.
        case scrolling
        /// Over a message that can be replied to, the first events held back until they say which it is.
        case deciding(Pending)
        case swiping(Swipe)
        /// A swipe has ended, or was given up: the rest of its gesture and its momentum are kept from the scroll view.
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
        /// Past the threshold since the last crossing: the haptic plays again only after falling back under it.
        var armed: Bool
    }

    private var state = State.idle
    private var lastPhase: NSEvent.Phase = []
    /// Held events going back to the scroll view, which may come through the monitor again: they pass.
    private var releasing = false

    #if DEBUG
    /// What the last gesture did, for the tour's swipe steps.
    struct DebugRecord {
        var claimed = false
        var maxOffset: CGFloat = 0
        var replied = false
        var haptics = 0
        var consumed = 0
        var passed = 0
        /// Ended by a cancelled gesture, or given up (`cancel`).
        var cancelled = false
    }

    private(set) var debugRecord = DebugRecord()
    /// Held events the tour's swipe was handed back.
    var debugReleased = 0
    var debugIsSwiping: Bool { if case .swiping = state { true } else { false } }
    #endif

    /// One scroll event at `point` in the table's coordinates. True when the swipe keeps it; `pass` hands held events
    /// on to the scroll view, in order, when they turn out to be a scroll's.
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
        // Fingers on the trackpad: a new gesture, unless it is the one whose `mayBegin` came just before. A swipe whose
        // end never came ends here.
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

    /// A gesture's first event: held back if it starts over a message that can be replied to, otherwise a scroll.
    private func start(_ event: NSEvent, at point: NSPoint) -> State {
        #if DEBUG
        debugRecord = DebugRecord()
        #endif
        guard event.hasPreciseScrollingDeltas, mayStart(), let cell = cellAt(point), let id = cell.message?.id else { return .scrolling }
        return .deciding(Pending(cell: cell, id: id))
    }

    /// The events held back go to the scroll view as they came; the gesture is a scroll from here on.
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

    /// Ends a swipe or a gesture still being told apart without replying, its bubble back in place at once; the rest of
    /// its gesture is kept from the scroll view, which never saw its start.
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

    /// The cell still shows the message the gesture started on, in the table.
    private func isCurrent(_ cell: MacTimelineMessageCell, _ id: String) -> Bool {
        cell.window != nil && cell.message?.id == id
    }

    /// The horizontal distance the fingers moved, positive to the right. Natural scrolling reports deltas that follow
    /// the fingers; with it off they are the other way round.
    static func fingerX(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    }
}
