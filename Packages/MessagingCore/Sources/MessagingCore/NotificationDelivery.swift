import Foundation
import MessageStore

/// Why a run could not settle. Every one of them shows the generic fallback (plan D2): unknown is never suppressed.
public enum NotificationFallbackReason: String, Sendable, Equatable, Codable {
    case leaseBusy, network, deadline, expired, protectedData, noAccount, identityUnavailable, postFailed, cancelled, failed

    public init(_ error: any Error) {
        switch error {
        case MessageStoreError.transportOwnedElsewhere: self = .leaseBusy
        case BackgroundSynchronizationError.deadlineExceeded: self = .deadline
        case BackgroundSynchronizationError.identityUnavailable: self = .identityUnavailable
        case BackgroundSynchronizationError.connectionEnded: self = .network
        case let failure as NotificationRunError:
            switch failure {
            case .noAccount: self = .noAccount
            case .protectedDataUnavailable: self = .protectedData
            case .postTimedOut: self = .postFailed
            }
        case is CancellationError: self = .cancelled
        case is URLError, is POSIXError: self = .network
        default: self = .failed
        }
    }
}

/// Failures the extension and the presenter raise themselves.
public enum NotificationRunError: Error, Sendable, Equatable {
    case noAccount, protectedDataUnavailable, postTimedOut
}

/// Counts only: no identifiers, addresses or content. Feeds the DEBUG outcome ring.
public struct NotificationRunReport: Sendable, Equatable, Codable {
    public var posted = 0
    public var claimed = 0
    public var deferred = 0
    public var removedFallbacks = 0
    public var removedStale = 0
    public var leaseWaitMilliseconds = 0
    public init() {}
}

/// A settled run suppresses the remote alert; anything else shows the fallback (plan D1, D2).
public enum NotificationRunOutcome: Sendable, Equatable {
    case settled(NotificationRunReport)
    case fallback(NotificationFallbackReason)

    public var suppressesRemoteAlert: Bool { if case .settled = self { true } else { false } }
}

/// Where a run is. A push that arrives while its run is still before `presenting` joins it: the run's network work
/// has not finished, so the new message is still fetched. Later pushes start (or join) the next run.
public enum NotificationRunPhase: String, Sendable, Equatable, Codable, Comparable {
    case queued, leaseWait, syncing, presenting, committed, finished
    private var order: Int { [.queued, .leaseWait, .syncing, .presenting, .committed, .finished].firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// Shared, lock-protected run state: read by the coordinator (joining, expiry) and written by the run.
public final class NotificationRunProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var currentPhase = NotificationRunPhase.queued
    private var currentReport = NotificationRunReport()
    private var abandoned = false
    private var joinedCount = 0
    private var expiredCount = 0
    public let started = Date()

    public init() {}

    public var phase: NotificationRunPhase { lock.withLock { currentPhase } }
    public var report: NotificationRunReport { lock.withLock { currentReport } }
    /// True once every post completed and the claimed rows were deleted: suppressing the remote alert is safe.
    public var isCommitted: Bool { lock.withLock { committed } }
    private var committed = false
    public var joined: Int { lock.withLock { joinedCount } }
    public var expired: Int { lock.withLock { expiredCount } }

    /// Phases only move forward.
    public func enter(_ phase: NotificationRunPhase) {
        lock.withLock {
            if phase > currentPhase { currentPhase = phase }
            if phase == .committed { committed = true }
        }
    }
    public func update(_ change: (inout NotificationRunReport) -> Void) { lock.withLock { change(&currentReport) } }

    var isJoinable: Bool { lock.withLock { !abandoned && currentPhase < .presenting } }
    func abandon() { lock.withLock { abandoned = true } }
    func noteJoined() { lock.withLock { joinedCount += 1 } }
    func noteExpired() { lock.withLock { expiredCount += 1 } }
}

/// Serializes runs in one extension process and lets concurrent `didReceive` calls share them. Every remote request
/// waits for the run it joined and finishes with that run's outcome; the handler for each request is called by the
/// caller exactly once, either from `deliver` or from `expire`, whichever comes first.
public final class NotificationRunCoordinator: @unchecked Sendable {
    public typealias Operation = @Sendable (NotificationRunProgress) async -> NotificationRunOutcome

    private final class Run: @unchecked Sendable {
        let progress = NotificationRunProgress()
        var task: Task<NotificationRunOutcome, Never>?
        var waiters = Set<UUID>()
    }

    private let lock = NSLock()
    private let operation: Operation
    private var runs: [Run] = []

    public init(operation: @escaping Operation) { self.operation = operation }

    /// Joins the joinable run or queues a new one after the current run, then waits for its outcome.
    public func deliver(ticket: UUID) async -> NotificationRunOutcome {
        let (run, task) = attach(ticket)
        let outcome = await task.value
        lock.withLock { _ = run.waiters.remove(ticket) }
        return outcome
    }

    /// `serviceExtensionTimeWillExpire`: answer now. A committed run already posted every request, so suppressing is
    /// safe; anything earlier is unknown and falls back. A run nobody waits for any more is cancelled; a crash or
    /// cancellation before its delete leaves the candidates, and reposting them replaces rather than duplicates.
    public func expire(ticket: UUID) -> NotificationRunOutcome {
        lock.withLock {
            guard let run = runs.first(where: { $0.waiters.contains(ticket) }) else { return .fallback(.expired) }
            run.waiters.remove(ticket)
            run.progress.noteExpired()
            let outcome: NotificationRunOutcome = run.progress.isCommitted ? .settled(run.progress.report) : .fallback(.expired)
            if run.waiters.isEmpty {
                run.progress.abandon()
                run.task?.cancel()
            }
            return outcome
        }
    }

    /// Number of runs started or queued and not yet finished (tests and diagnostics).
    public var activeRuns: Int { lock.withLock { runs.count } }

    private func attach(_ ticket: UUID) -> (Run, Task<NotificationRunOutcome, Never>) {
        lock.withLock {
            if let last = runs.last, last.progress.isJoinable, let task = last.task {
                last.waiters.insert(ticket)
                last.progress.noteJoined()
                return (last, task)
            }
            let previous = runs.last?.task
            let run = Run()
            run.waiters.insert(ticket)
            run.progress.noteJoined()
            let operation = operation
            let task = Task { [weak self] () -> NotificationRunOutcome in
                // One run at a time: the next one starts only after the previous released the lease.
                if let previous { _ = await previous.value }
                let outcome: NotificationRunOutcome
                if Task.isCancelled { outcome = .fallback(.cancelled) } else { outcome = await operation(run.progress) }
                run.progress.enter(.finished)
                self?.finished(run)
                return outcome
            }
            run.task = task
            runs.append(run)
            return (run, task)
        }
    }

    private func finished(_ run: Run) {
        lock.withLock { runs.removeAll { $0 === run } }
    }
}

/// Posts a batch under the transport lease and then cleans up (plan D1–D4). Every `add` completes before the claimed
/// rows are deleted and before the run counts as committed; a failed or slow `add` throws, which means fallback.
public struct NotificationPresenter: Sendable {
    public let posting: any NotificationPosting
    public var addTimeout: Duration
    public var cleanupTimeout: Duration

    public init(posting: any NotificationPosting, addTimeout: Duration = .seconds(4), cleanupTimeout: Duration = .seconds(3)) {
        self.posting = posting; self.addTimeout = addTimeout; self.cleanupTimeout = cleanupTimeout
    }

    /// `authorize` rereads the protected account after the network work; it throws when the user signed out meanwhile.
    public func present(store: MessageStore, accountID: String, progress: NotificationRunProgress,
                        authorize: @Sendable () throws -> Void = {}) async throws {
        progress.enter(.presenting)
        try Task.checkCancellation()
        try authorize()
        let batch = try await store.pendingNotifications(accountID: accountID)
        let plan = NotificationPlanner.plan(batch)
        for request in plan.requests {
            try Task.checkCancellation()
            try await withTimeout(addTimeout) { try await posting.add(request) }
        }
        try await store.removeNotificationCandidates(accountID: accountID, keys: plan.claimed)
        progress.update {
            $0.posted = plan.requests.count; $0.claimed = plan.claimed.count; $0.deferred = batch.deferredCount
        }
        progress.enter(.committed)
        // Settled. Cleanup is best effort and never changes the outcome.
        let removed = try? await withTimeout(cleanupTimeout) {
            try await removeStaleDelivered(store: store, accountID: accountID)
        }
        if let removed { progress.update { $0.removedFallbacks = removed.fallbacks; $0.removedStale = removed.messages } }
    }

    /// Removes delivered notifications a successful run supersedes: every fallback (category `fallback`, whatever its
    /// request or collapse identifier) and message notifications whose message was retracted or no longer exists.
    /// Merge point: stream B's read-pointer rule adds the identifiers of read messages here.
    func removeStaleDelivered(store: MessageStore, accountID: String) async throws -> (fallbacks: Int, messages: Int) {
        let delivered = await posting.deliveredNotifications()
        let fallbacks = delivered.filter { $0.categoryIdentifier == NotificationIdentity.fallbackCategory }.map(\.identifier)
        let owned = delivered.filter { $0.categoryIdentifier == NotificationIdentity.messageCategory }
            .compactMap { notification in notification.destination.flatMap { $0.belongs(to: accountID) ? $0.messageID : nil } }
        let stale = try await store.staleNotificationMessageIDs(accountID: accountID, messageIDs: Array(owned.prefix(1000)))
        let messages = stale.map { NotificationIdentity.message(accountID: accountID, messageID: $0) }
        await posting.removeDelivered(identifiers: fallbacks + messages.sorted())
        return (fallbacks.count, messages.count)
    }
}

/// Runs `operation`, throwing `NotificationRunError.postTimedOut` when it does not finish within `limit`.
/// The operation is cancelled on timeout; a system call that ignores cancellation may still complete later.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: limit); return nil }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw NotificationRunError.postTimedOut }
        return value
    }
}
