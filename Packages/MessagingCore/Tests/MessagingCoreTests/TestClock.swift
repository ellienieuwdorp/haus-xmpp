import Foundation

// Moves only when the test moves it: drive work that does nothing else while it sleeps with `run`, the rest with
// `sleepers(_:)` or `sleeper(until:)` and `advance(by:)`. A cancelled sleeper throws at once; `date` is the wall clock on
// the same timeline. Every wait fails after `failsafe` of real time instead of hanging. `lock` guards all state.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        static func + (lhs: Instant, rhs: Duration) -> Instant { lhs.advanced(by: rhs) }
        static func - (lhs: Instant, rhs: Duration) -> Instant { lhs.advanced(by: .zero - rhs) }
    }

    struct Stalled: Error, CustomStringConvertible {
        let waitingFor: String
        var description: String { "TestClock waited \(TestClock.failsafe) of real time for \(waitingFor)" }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Watcher {
        let continuation: CheckedContinuation<Void, any Error>
        var failsafe: Task<Void, Never>?
    }

    static let failsafe: Duration = .seconds(30)

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleeping: [UUID: Sleeper] = [:]
    private var cancelledEarly: Set<UUID> = []
    private var watchers: [UUID: Watcher] = [:]
    private let origin: Date

    init(date origin: Date = Date(timeIntervalSince1970: 1_000_000_000)) { self.origin = origin }

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var elapsed: Duration { now.offset }
    var date: Date { date(at: now) }
    func date(at instant: Instant) -> Date { origin.addingTimeInterval(Self.seconds(instant.offset)) }
    var sleeperCount: Int { lock.withLock { sleeping.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early: Result<Void, any Error>? = lock.withLock {
                    if cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleeping[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let early { continuation.resume(with: early) } else { changed() }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let sleeper = sleeping.removeValue(forKey: id) else { cancelledEarly.insert(id); return nil }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
            if sleeper != nil { changed() }
        }
    }

    // Resumes every sleeper whose deadline it passes, earliest first.
    func advance(by duration: Duration) {
        precondition(duration >= .zero, "a clock never goes back")
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let due = sleeping.filter { $0.value.deadline <= current }
            due.keys.forEach { sleeping.removeValue(forKey: $0) }
            return due.values.sorted { $0.deadline < $1.deadline }
        }
        due.forEach { $0.continuation.resume() }
        if !due.isEmpty { changed() }
    }

    // Returns once at least `count` tasks sleep on this clock.
    func sleepers(_ count: Int) async throws {
        _ = try await until("\(count) sleepers") { sleeping.count >= count ? true : nil }
    }

    // Returns once a task sleeps until `offset` after the clock's start.
    func sleeper(until offset: Duration) async throws {
        _ = try await until("a sleeper until \(offset)") { sleeping.values.contains { $0.deadline.offset == offset } ? true : nil }
    }

    // Runs `operation` to its end, moving the clock to the earliest deadline whenever something sleeps. Only for work
    // that does nothing else while it sleeps: the clock would jump while another task is busy. Drive the rest with
    // `sleepers(_:)` or `sleeper(until:)` and `advance(by:)`.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let finished = Finished()
        let task = Task {
            defer { finished.set(); changed() }
            return try await operation()
        }
        while true {
            let next: Instant? = try await until("the work to sleep or return") {
                finished.value ? .some(nil) : sleeping.values.map(\.deadline).min().map { .some($0) }
            }
            guard let next else { return try await task.value }
            advance(by: now.duration(to: next))
        }
    }

    // Waits for `ready`, evaluated under the lock, to return a value; rechecked after every sleep, wake and finish.
    private func until<R>(_ what: String, _ ready: () -> R?) async throws -> R {
        while true {
            let id = UUID()
            var found: R?
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                found = lock.withLock {
                    if let value = ready() { return value }
                    watchers[id] = Watcher(continuation: continuation)
                    return nil
                }
                if found != nil { continuation.resume() } else { startFailsafe(id, what) }
            }
            if let found { return found }
        }
    }

    private func changed() {
        let woken = lock.withLock { () -> [Watcher] in
            defer { watchers = [:] }
            return Array(watchers.values)
        }
        for watcher in woken {
            watcher.failsafe?.cancel()
            watcher.continuation.resume()
        }
    }

    private func startFailsafe(_ id: UUID, _ what: String) {
        let failsafe = Task { [weak self] in
            // swiftlint:disable:next no_wall_clock_in_tests - only a hung test reaches this; a wake cancels it first
            guard (try? await ContinuousClock().sleep(for: Self.failsafe)) != nil, let self else { return }
            let watcher = lock.withLock { watchers.removeValue(forKey: id) }
            watcher?.continuation.resume(throwing: Stalled(waitingFor: what))
        }
        let stale = lock.withLock {
            guard watchers[id] != nil else { return true }
            watchers[id]?.failsafe = failsafe
            return false
        }
        if stale { failsafe.cancel() }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

// `lock` guards `done`.
private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}
