import Foundation
import MessageStore

/// Why a run could not settle. Every one of them shows the generic fallback (plan D2): unknown is never suppressed.
public enum NotificationFallbackReason: String, Sendable, Equatable, Codable {
    case leaseBusy, network, deadline, expired, protectedData, noAccount, identityUnavailable, postFailed, cancelled, failed
    /// The store is older than this build, or a restore of the previous version's data is under way or done: only
    /// the app changes it.
    case upgradePending

    public init(_ error: any Error) {
        switch error {
        case MessageStoreError.transportOwnedElsewhere: self = .leaseBusy
        case MessageStoreError.upgradeRequired(_), MessageStoreError.replaced, NotificationRunError.upgradePending: self = .upgradePending
        case BackgroundSynchronizationError.deadlineExceeded: self = .deadline
        case BackgroundSynchronizationError.identityUnavailable: self = .identityUnavailable
        case BackgroundSynchronizationError.connectionEnded: self = .network
        case let failure as NotificationRunError:
            switch failure {
            case .noAccount: self = .noAccount
            case .protectedDataUnavailable: self = .protectedData
            case .postTimedOut: self = .postFailed
            case .upgradePending: self = .upgradePending
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
    /// The app is restoring, or has restored, the previous version's data.
    case upgradePending
}

/// Counts only: no identifiers, addresses or content. Feeds the DEBUG outcome ring.
public struct NotificationRunReport: Sendable, Equatable, Codable {
    public var posted = 0
    public var claimed = 0
    public var deferred = 0
    public var removedFallbacks = 0
    public var removedStale = 0
    public var leaseWaitMilliseconds = 0
    /// The icon badge the run computed (a count, not content); nil when it could not.
    public var badge: Int?
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
        // Best effort: an unknown badge leaves the icon as it is rather than failing the run.
        let badge = try? await NotificationBadge.count(store: store, accountID: accountID)
        progress.update { $0.badge = badge }
        let plan = NotificationPlanner.plan(batch, accountID: accountID, badge: badge)
        for request in plan.requests {
            try Task.checkCancellation()
            // The system add keeps its whole limit; an intent donation before it has its own allowance.
            try await withTimeout(addTimeout + posting.preparationAllowance(for: request)) { try await posting.add(request) }
        }
        try await store.removeNotificationCandidates(accountID: accountID, keys: plan.claimed)
        progress.update {
            $0.posted = plan.requests.count; $0.claimed = plan.claimed.count; $0.deferred = batch.deferredCount
        }
        progress.enter(.committed)
        // Settled. Cleanup is best effort and never changes the outcome.
        let removed = try? await withTimeout(cleanupTimeout) {
            try await removeStaleDelivered(store: store, accountID: accountID, summaryPosted: plan.summarizesDeferredChats)
        }
        if let removed { progress.update { $0.removedFallbacks = removed.fallbacks; $0.removedStale = removed.messages } }
    }

    /// Removes delivered notifications a successful run supersedes:
    /// - every fallback (category `fallback`, whatever its request or collapse identifier);
    /// - message notifications whose message was retracted or no longer exists, including unreadable placeholders;
    /// - review notifications of retained ciphertext that is no longer retained (it committed, and then alerts as the
    ///   message itself, or became a placeholder);
    /// - reaction notifications whose reaction was withdrawn;
    /// - the deferred-chats summary, when this run posted none: its chats were posted since, or dismissed.
    /// Removes fallbacks, a stale overflow summary, and messages that were retracted, went missing or were read
    /// (`owned` lists the message IDs behind delivered destinations and placeholder references).
    func removeStaleDelivered(store: MessageStore, accountID: String, summaryPosted: Bool) async throws -> (fallbacks: Int, messages: Int) {
        let delivered = await posting.deliveredNotifications()
        let fallbacks = delivered.filter { $0.categoryIdentifier == NotificationIdentity.fallbackCategory }.map(\.identifier)
        let mine = delivered.filter { NotificationIdentity.isMessageRun(category: $0.categoryIdentifier) }
        let owned = mine.compactMap { notification -> String? in
            if let destination = notification.destination, destination.kind == .message { return destination.belongs(to: accountID) ? destination.messageID : nil }
            if let reference = notification.reference, reference.kind == .placeholder, reference.belongs(to: accountID) { return reference.messageID }
            return nil
        }
        let bounded = Array(owned.prefix(1000))
        let stale = try await store.staleNotificationMessageIDs(accountID: accountID, messageIDs: bounded)
        // Read here or on another device (pointer, own marker, XEP-0490 item, or history before the baseline).
        let read = try await store.readNotificationMessageIDs(accountID: accountID, messageIDs: Set(bounded))
        var messages = stale.union(read).map { NotificationIdentity.message(accountID: accountID, messageID: $0) }
        let retained = mine.filter { $0.reference?.kind == .retained && $0.reference?.belongs(to: accountID) == true }
        if !retained.isEmpty {
            let live = Set(try await store.retainedEncryptedIncomingKeys(accountID: accountID).map { key in
                NotificationPlanner.identifier(accountID: accountID, key: key)
            })
            messages += retained.map(\.identifier).filter { !live.contains($0) }
        }
        messages += try await ReactionNotificationCleanup.staleIdentifiers(store: store, accountID: accountID, delivered: delivered)
        let summary = NotificationIdentity.overflow(accountID: accountID)
        if !summaryPosted, mine.contains(where: { $0.identifier == summary }) { messages.append(summary) }
        await posting.removeDelivered(identifiers: fallbacks + messages.sorted())
        return (fallbacks.count, messages.count)
    }
}

/// Delivered reaction notifications that are no longer current (plan D8): withdrawn in part or whole, the target gone,
/// or the chat read or opened since they were posted (`MessageStore.liveReactionNotifications`). Shared by the
/// extension's end-of-run cleanup and the app's cleanup after a read pointer moved.
public enum ReactionNotificationCleanup {
    public static func staleIdentifiers(store: MessageStore, accountID: String, delivered: [DeliveredNotification]) async throws -> [String] {
        let reactions = delivered.filter {
            $0.categoryIdentifier == NotificationIdentity.reactionCategory && $0.reference?.kind == .reaction && $0.reference?.belongs(to: accountID) == true
        }
        guard !reactions.isEmpty else { return [] }
        let targets = Set(reactions.compactMap(\.reference?.messageID).sorted().prefix(1000))
        let live = Set(try await store.liveReactionNotifications(accountID: accountID, targetMessageIDs: targets).map {
            NotificationIdentity.reaction(accountID: accountID, chatID: $0.chatID, actorID: $0.actorID, targetMessageID: $0.targetMessageID)
        })
        return reactions.map(\.identifier).filter { !live.contains($0) }
    }
}

/// Runs `operation`, throwing `NotificationRunError.postTimedOut` when it does not finish within `limit`. Returns at
/// the limit even when the operation ignores cancellation (as the `UNUserNotificationCenter` completion-handler
/// bridges do): the operation is raced in an unstructured task that is cancelled and left to finish on its own. A
/// system call that completes after the limit may still show its notification; the run has already fallen back and
/// kept its candidates, and a later run reposts the same identifier, which replaces it.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            race.start(continuation,
                       work: Task { do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) } },
                       timer: Task { try? await Task.sleep(for: limit); race.finish(.failure(NotificationRunError.postTimedOut)) })
        }
    } onCancel: { race.finish(.failure(CancellationError())) }
}

/// Resumes its continuation exactly once, with whichever of work, timer or cancellation finishes first, then cancels
/// the other tasks. A result that arrives before the continuation is installed is kept and delivered on `start`.
private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var result: Result<T, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var done = false

    func start(_ continuation: CheckedContinuation<T, any Error>, work: Task<Void, Never>, timer: Task<Void, Never>) {
        let early: Result<T, any Error>? = lock.withLock {
            if let result { done = true; return result }
            self.continuation = continuation; tasks = [work, timer]
            return nil
        }
        if let early { work.cancel(); timer.cancel(); continuation.resume(with: early) }
    }

    func finish(_ outcome: Result<T, any Error>) {
        let (waiting, pending): (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) = lock.withLock {
            guard !done else { return (nil, []) }
            guard let continuation else { if result == nil { result = outcome }; return (nil, []) }
            done = true; self.continuation = nil
            defer { tasks = [] }
            return (continuation, tasks)
        }
        pending.forEach { $0.cancel() }
        waiting?.resume(with: outcome)
    }
}
