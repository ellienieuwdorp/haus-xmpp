import Foundation
import MessageStore
import Testing
@testable import MessagingCore

// A run whose steps the test releases one at a time.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private actor Counter {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}

// The progress of the run a coordinator started last.
final class LastRun: @unchecked Sendable {
    // `lock` guards `last`.
    private let lock = NSLock()
    private var last: NotificationRunProgress?
    var progress: NotificationRunProgress? { lock.withLock { last } }
    func started(_ progress: NotificationRunProgress) { lock.withLock { last = progress } }
}

struct NotificationRunCoordinatorTests {
    @Test func pushesDuringTheNetworkPhaseJoinOneRunAndShareItsOutcome() async throws {
        let gate = Gate(), runs = Counter(), run = LastRun()
        let coordinator = NotificationRunCoordinator { progress in
            _ = await runs.increment()
            progress.enter(.syncing)
            run.started(progress)
            await gate.wait()
            progress.enter(.committed)
            return .settled(progress.report)
        }
        let first = Task { await coordinator.deliver(ticket: UUID()) }
        try await eventually("the first run to sync") { run.progress != nil }
        let second = Task { await coordinator.deliver(ticket: UUID()) }
        let third = Task { await coordinator.deliver(ticket: UUID()) }
        try await eventually("both pushes to join") { run.progress?.joined == 3 }
        await gate.release()
        let outcomes = try await bounded { [await first.value, await second.value, await third.value] }
        #expect(outcomes.allSatisfy { $0.suppressesRemoteAlert })
        #expect(await runs.value == 1)
        #expect(coordinator.activeRuns == 0)
    }

    @Test func aPushAfterTheNetworkPhaseGetsTheNextRunNotThisOne() async throws {
        let presenting = Gate(), finish = Gate(), runs = Counter()
        let coordinator = NotificationRunCoordinator { progress in
            let number = await runs.increment()
            if number == 1 {
                progress.enter(.presenting)
                await presenting.release()
                await finish.wait()
            }
            progress.enter(.committed)
            return .settled(progress.report)
        }
        let first = Task { await coordinator.deliver(ticket: UUID()) }
        try await bounded { await presenting.wait() }
        let second = Task { await coordinator.deliver(ticket: UUID()) }
        try await eventually("the second run to queue") { coordinator.activeRuns == 2 }
        // The second run waits for the first: one lease owner at a time.
        #expect(await runs.value == 1)
        await finish.release()
        let outcomes = try await bounded { [await first.value, await second.value] }
        #expect(outcomes.allSatisfy { $0.suppressesRemoteAlert })
        #expect(await runs.value == 2)
    }

    @Test func expiryBeforeCommitFallsBackAndCancelsAnAbandonedRun() async throws {
        let started = Gate(), cancelled = Gate()
        let coordinator = NotificationRunCoordinator { progress in
            progress.enter(.syncing)
            await started.release()
            await untilCancelled()
            await cancelled.release()
            return .fallback(.cancelled)
        }
        let ticket = UUID()
        let delivery = Task { await coordinator.deliver(ticket: ticket) }
        try await bounded { await started.wait() }
        #expect(coordinator.expire(ticket: ticket) == .fallback(.expired))
        try await bounded { await cancelled.wait() }
        #expect(try await bounded { await delivery.value } == .fallback(.cancelled))
        // Expiring an unknown or already finished request still answers, and never suppresses.
        #expect(coordinator.expire(ticket: UUID()) == .fallback(.expired))
    }

    @Test func expiryAfterCommitSuppressesAndOtherWaitersKeepTheRun() async throws {
        let committed = Gate(), finish = Gate(), run = LastRun()
        let coordinator = NotificationRunCoordinator { progress in
            progress.enter(.syncing)
            run.started(progress)
            await committed.wait()
            progress.update { $0.posted = 3 }
            progress.enter(.committed)
            await finish.wait()
            return .settled(progress.report)
        }
        let early = UUID(), late = UUID()
        let first = Task { await coordinator.deliver(ticket: early) }
        try await eventually("the run to sync") { run.progress != nil }
        let second = Task { await coordinator.deliver(ticket: late) }
        try await eventually("the second push to join") { run.progress?.joined == 2 }
        // Unknown outcome: fall back, but the joined request keeps the run alive.
        #expect(coordinator.expire(ticket: early) == .fallback(.expired))
        await committed.release()
        try await eventually("the run to commit") { run.progress?.isCommitted == true }
        guard case let .settled(report) = coordinator.expire(ticket: late) else { Issue.record("Committed run must suppress"); return }
        #expect(report.posted == 3)
        await finish.release()
        _ = try await bounded { (await first.value, await second.value) }
    }
}

struct NotificationTimeoutTests {
    @Test func cancellingTheCallerReturnsWithoutWaitingForTheOperation() async throws {
        let clock = TestClock()
        let task = Task { try await withTimeout(.seconds(30), clock: clock) { await ignoringCancellation(for: .seconds(20), on: clock); return 1 } }
        // The timeout and the operation.
        try await clock.sleepers(2)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await bounded { try await task.value } }
        // Neither was waited for: the clock never moved, and the operation, which ignores cancellation, still sleeps.
        #expect(clock.elapsed == .zero && clock.sleeperCount == 1)
    }

    @Test func theLimitEndsAnOperationThatIgnoresCancellation() async throws {
        let clock = TestClock()
        let task = Task { try await withTimeout(.seconds(4), clock: clock) { await ignoringCancellation(for: .seconds(20), on: clock); return 1 } }
        try await clock.sleepers(2)
        clock.advance(by: .seconds(4))
        await #expect(throws: NotificationRunError.postTimedOut) { try await bounded { try await task.value } }
        #expect(clock.sleeperCount == 1)
        // An operation that finishes first returns its value and stops the timer.
        #expect(try await withTimeout(.seconds(4), clock: clock) { 2 } == 2)
        #expect(clock.sleeperCount == 1)
    }
}

struct NotificationLeaseAndLogTests {
    @Test func leaseWaitIsBoundedCancellableAndSucceedsWhenReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lease-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let holder = try MessageStore(url: url), waiter = try MessageStore(url: url)
        try await holder.acquireTransportOwnership()
        let clock = TestClock()
        await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
            _ = try await clock.run { try await acquireTransportOwnership(waiter, waitingUpTo: .milliseconds(120), interval: .milliseconds(20), clock: clock) }
        }
        // The last round that fits the limit sleeps until it ends.
        #expect(clock.elapsed == .milliseconds(120))
        let cancelled = Task { try await acquireTransportOwnership(waiter, waitingUpTo: .seconds(5), interval: .milliseconds(20), clock: clock) }
        try await clock.sleepers(1)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await bounded { try await cancelled.value } }
        let released = Task { try await acquireTransportOwnership(waiter, waitingUpTo: .seconds(5), interval: .milliseconds(20), clock: clock) }
        // Five busy rounds, then the holder lets go during the fifth wait.
        for _ in 0..<4 {
            try await clock.sleepers(1)
            clock.advance(by: .milliseconds(20))
        }
        try await clock.sleepers(1)
        try await holder.releaseTransportOwnership()
        clock.advance(by: .milliseconds(20))
        #expect(try await bounded { try await released.value } == .milliseconds(100))
        try await waiter.close(); try await holder.close()
    }

    @Test func fallbackReasonsCoverEveryFailureClass() {
        #expect(NotificationFallbackReason(MessageStoreError.transportOwnedElsewhere) == .leaseBusy)
        #expect(NotificationFallbackReason(BackgroundSynchronizationError.deadlineExceeded) == .deadline)
        #expect(NotificationFallbackReason(BackgroundSynchronizationError.connectionEnded) == .network)
        #expect(NotificationFallbackReason(BackgroundSynchronizationError.identityUnavailable) == .identityUnavailable)
        #expect(NotificationFallbackReason(NotificationRunError.noAccount) == .noAccount)
        #expect(NotificationFallbackReason(NotificationRunError.protectedDataUnavailable) == .protectedData)
        #expect(NotificationFallbackReason(CancellationError()) == .cancelled)
        #expect(NotificationFallbackReason(URLError(.notConnectedToInternet)) == .network)
        #expect(NotificationFallbackReason(MessageStoreError.invalidValue) == .failed)
    }

    @Test func outcomeRingIsBoundedAndCarriesCountsOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try NotificationOutcomeLog.read(directory: directory).isEmpty)
        for index in 0..<40 {
            let progress = NotificationRunProgress()
            progress.enter(.committed)
            progress.update { $0.posted = index }
            try NotificationOutcomeLog.append(NotificationOutcomeRecord(progress: progress, outcome: index.isMultiple(of: 2) ? .settled(progress.report) : .fallback(.leaseBusy)),
                                              directory: directory)
        }
        let records = try NotificationOutcomeLog.read(directory: directory)
        #expect(records.count == NotificationOutcomeLog.capacity)
        #expect(records.first?.report.posted == 8 && records.last?.report.posted == 39)
        #expect(records.last?.outcome == "fallback" && records.last?.reason == .leaseBusy && records.last?.phase == .committed)
        let text = try String(contentsOf: directory.appending(path: NotificationOutcomeLog.fileName), encoding: .utf8)
        #expect(!text.contains("@"))
    }
}
