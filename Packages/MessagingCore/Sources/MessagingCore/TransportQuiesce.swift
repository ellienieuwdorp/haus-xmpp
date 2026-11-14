import Foundation

/// A monotonic clock read as the time since the clock was made, so the engine's deadlines can run on an injected clock.
public struct EngineClock: Sendable {
    public let now: @Sendable () -> Duration
    public let sleep: @Sendable (_ until: Duration) async throws -> Void

    public init<C: Clock<Duration>>(_ clock: C) {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: nil) }
    }

    public static let continuous = EngineClock(ContinuousClock())
}

/// Closed, it refuses new transport, crypto and setup work. It also counts work begun outside the engine's own tasks
/// (UI crypto mutations, trust and repair, a lease acquisition in flight), so a quiesce can wait for that to end.
@MainActor public final class TransportGate {
    public var closed = false
    public var operations = 0 { didSet { wakeIfIdle() } }
    /// Covers the store call in flight, whose kernel lock may already be held before the main actor hears of it.
    public var acquiring = false { didSet { wakeIfIdle() } }
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isIdle: Bool { operations == 0 && !acquiring }

    /// False, and nothing counted, while the gate is closed.
    public func beginOperation() -> Bool {
        guard !closed else { return false }
        operations += 1
        return true
    }

    public func endOperation() { operations -= 1 }

    // What still runs, for a fault log; names only.
    var busy: [String] {
        var names: [String] = []
        if operations > 0 { names.append("\(operations) crypto operation(s)") }
        if acquiring { names.append("lease acquisition") }
        return names
    }

    func untilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func wakeIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}

// A point on an `EngineClock` that waits can race. `fire` brings it forward to now, as an expiring background task does.
@MainActor final class QuiesceDeadline {
    private(set) var passed = false
    private var waiters: [UUID: @MainActor () -> Void] = [:]
    private var timer: Task<Void, Never>?

    // nil never passes on its own.
    init(at offset: Duration?, clock: EngineClock) {
        guard let offset else { return }
        if offset <= clock.now() { passed = true; return }
        timer = Task { [weak self] in
            guard (try? await clock.sleep(offset)) != nil else { return }
            self?.fire()
        }
    }

    func fire() {
        guard !passed else { return }
        passed = true
        timer?.cancel()
        let due = waiters
        waiters = [:]
        due.values.forEach { $0() }
    }

    func cancel() { timer?.cancel() }

    // True when `task` ended first; false once the deadline passed. Awaiting a task's value ignores cancellation, so
    // the losing side is left to finish on its own.
    func race(_ task: Task<Void, Never>) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.continuation = continuation
            let id = UUID()
            Task { @MainActor [weak self] in
                await task.value
                self?.waiters[id] = nil
                once.resume(true)
            }
            // Queued behind the watcher, so a task that already ended still wins a deadline that already passed.
            if passed { Task { @MainActor in await Task.yield(); once.resume(false) }; return }
            waiters[id] = { once.resume(false) }
        }
    }

    // Returns when `wakeup` is signalled or the deadline passes, whichever is first.
    func wait(for wakeup: Wakeup) async {
        guard !passed, !wakeup.consume() else { return }
        let once = Once()
        let id = UUID()
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.continuation = continuation
            waiters[id] = { once.resume(false) }
            wakeup.waiter = { once.resume(true) }
        }
        waiters[id] = nil
        wakeup.waiter = nil
    }

    @MainActor private final class Once {
        var continuation: CheckedContinuation<Bool, Never>?
        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

// A signal that is not lost when it comes before the wait.
@MainActor final class Wakeup {
    private var pending = false
    var waiter: (@MainActor () -> Void)?

    func signal() {
        if let waiter { self.waiter = nil; waiter() } else { pending = true }
    }

    func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

/// The ordered stop every lease holder runs before it gives the lease up: with new work refused by the closed gate, a
/// join of each task in order (the graceful disconnect first), then of the outside work the gate counts, and only then
/// the release. At the deadline it hard-closes the transport (which also ends a write the socket held) and joins again for
/// at most `abortJoin`. Work still running then is reported as stuck and nothing is released: unlocking under live
/// work would let another process own the transport while this one still writes.
@MainActor public struct TransportQuiesce {
    public struct Work {
        public let name: String
        public let task: Task<Void, Never>?
        public init(_ name: String, _ task: Task<Void, Never>?) { self.name = name; self.task = task }
    }

    public struct Outcome: Sendable, Equatable {
        public var hardClosed = false
        /// Names of what still ran after the hard close; non-empty means nothing was released.
        public var stuck: [String] = []
        public var released = false
        public init(hardClosed: Bool = false, stuck: [String] = [], released: Bool = false) {
            self.hardClosed = hardClosed; self.stuck = stuck; self.released = released
        }
    }

    let gate: TransportGate
    let abort: @MainActor () -> Void
    let work: [Work]
    let release: (@MainActor () async -> Bool)?
    let clock: EngineClock
    let deadline: QuiesceDeadline
    let abortJoin: Duration

    /// `deadline` is a point on `clock`; nil waits as long as the work takes. `abort` hard-closes the transport and
    /// cancels what it can. `release` nil only stops the work.
    public init(gate: TransportGate, work: [Work], abort: @escaping @MainActor () -> Void, release: (@MainActor () async -> Bool)?,
                clock: EngineClock, deadline: Duration?, abortJoin: Duration = .seconds(1)) {
        self.init(gate: gate, work: work, abort: abort, release: release, clock: clock,
                  deadline: QuiesceDeadline(at: deadline, clock: clock), abortJoin: abortJoin)
    }

    init(gate: TransportGate, work: [Work], abort: @escaping @MainActor () -> Void, release: (@MainActor () async -> Bool)?,
         clock: EngineClock, deadline: QuiesceDeadline, abortJoin: Duration) {
        self.gate = gate; self.abort = abort; self.work = work; self.release = release
        self.clock = clock; self.deadline = deadline; self.abortJoin = abortJoin
    }

    public func run() async -> Outcome {
        gate.closed = true
        var outcome = Outcome()
        var current = deadline
        let gate = gate
        let joins = work + [Work("outside work", Task { await gate.untilIdle() })]
        for item in joins {
            guard let task = item.task else { continue }
            if await current.race(task) { continue }
            if !outcome.hardClosed {
                outcome.hardClosed = true
                abort()
                current = QuiesceDeadline(at: clock.now() + abortJoin, clock: clock)
                if await current.race(task) { continue }
            }
            outcome.stuck.append(item.name == "outside work" ? gate.busy.joined(separator: ", ") : item.name)
        }
        current.cancel()
        deadline.cancel()
        guard outcome.stuck.isEmpty, let release else { return outcome }
        outcome.released = await release()
        return outcome
    }
}
