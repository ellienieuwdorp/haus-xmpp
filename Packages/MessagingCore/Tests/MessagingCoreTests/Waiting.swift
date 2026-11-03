import Foundation
@testable import MessagingCore

// At most `TestClock.failsafe` of real time, even when `operation` ignores cancellation: a hang fails with postTimedOut.
func bounded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    // swiftlint:disable:next no_wall_clock_in_tests - only a hung test reaches this limit
    try await withTimeout(TestClock.failsafe, clock: ContinuousClock(), operation)
}

// For state with no event to await: polls between yields, failing after `TestClock.failsafe` of real time.
func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async throws {
    // swiftlint:disable:next no_wall_clock_in_tests - only a hung test reaches this limit
    let clock = ContinuousClock(), giveUp = clock.now + TestClock.failsafe
    while await !condition() {
        guard clock.now < giveUp else { throw TestClock.Stalled(waitingFor: what) }
        await Task.yield()
    }
}

func untilCancelled() async {
    let waiter = CancellationWaiter()
    await withTaskCancellationHandler { await waiter.wait() } onCancel: { waiter.cancel() }
}

func ignoringCancellation(for duration: Duration, on clock: TestClock) async {
    // Like a completion-handler bridge: the unstructured task does not inherit the caller's cancellation, so it never throws.
    _ = try? await Task { try await clock.sleep(for: duration) }.value
}

// `lock` guards both vars.
private final class CancellationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if cancelled { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func cancel() {
        let waiting = lock.withLock {
            cancelled = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}
