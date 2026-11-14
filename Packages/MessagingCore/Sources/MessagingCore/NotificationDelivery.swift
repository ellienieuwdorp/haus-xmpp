import Foundation
import MessageStore
import os
import XMPPProtocol

/// Every reason shows the generic fallback: unknown is never suppressed.
public enum NotificationFallbackReason: String, Sendable, Equatable, Codable {
    case leaseBusy, network, deadline, expired, protectedData, noAccount, identityUnavailable, postFailed, cancelled, failed
    /// The store needs an upgrade or restore that only the app performs.
    case upgradePending
    /// The run gave way to the app, which did not confirm it took the lease.
    case takeoverUnconfirmed

    public init(_ error: any Error) {
        switch error {
        case MessageStoreError.transportOwnedElsewhere: self = .leaseBusy
        case MessageStoreError.upgradeRequired(_), MessageStoreError.replaced, NotificationRunError.upgradePending: self = .upgradePending
        case BackgroundSynchronizationError.deadlineExceeded: self = .deadline
        case BackgroundSynchronizationError.identityUnavailable: self = .identityUnavailable
        case BackgroundSynchronizationError.connectionEnded: self = .network
        case BackgroundSynchronizationError.takeoverUnconfirmed: self = .takeoverUnconfirmed
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
    public var badge: Int?
    /// Nil when nothing was posted.
    public var firstPostMilliseconds: Int?
    public init() {}
}

public enum NotificationRunOutcome: Sendable, Equatable {
    case settled(NotificationRunReport)
    /// The app answered the liveness handshake, or took over the lease the run gave way to, and presents the push
    /// itself. What the run stored but did not post stays for the app's claim.
    case handedOff
    case fallback(NotificationFallbackReason)

    public var suppressesRemoteAlert: Bool {
        switch self {
        case .settled, .handedOff: true
        case .fallback: false
        }
    }

    /// A committed run already posted and deleted its claims, so a later failure (closing the store) does not show
    /// the fallback on top of the real notifications.
    public static func ended(by error: any Error, progress: NotificationRunProgress) -> NotificationRunOutcome {
        if progress.isCommitted { return .settled(progress.report) }
        if case BackgroundSynchronizationError.handedOff = error { return .handedOff }
        return .fallback(NotificationFallbackReason(error))
    }
}

/// A push that arrives before `presenting` joins the run, whose network work still fetches the new message. Later
/// pushes start or join the next run.
public enum NotificationRunPhase: String, Sendable, Equatable, Codable, Comparable {
    case queued, leaseWait, syncing, presenting, committed, finished
    private var order: Int { [.queued, .leaseWait, .syncing, .presenting, .committed, .finished].firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// Read by the coordinator (joining, expiry), written by the run.
public final class NotificationRunProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var currentPhase = NotificationRunPhase.queued
    private var currentReport = NotificationRunReport()
    private var abandoned = false
    private var soundPlayed = false
    private var joinedCount = 0
    private var expiredCount = 0
    public let started = Date()

    public init() {}

    public var phase: NotificationRunPhase { lock.withLock { currentPhase } }
    public var report: NotificationRunReport { lock.withLock { currentReport } }
    /// Every post completed and the claimed rows were deleted, so suppressing the remote alert is safe.
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
    // A run plays one sound, whichever presentation adds it. An add that is cancelled or times out may still land with
    // its sound; only a refused one frees it for a later presentation.
    var hasPlayedSound: Bool { lock.withLock { soundPlayed } }
    func noteAddingSound() { lock.withLock { soundPlayed = true } }
    func noteSoundRefused() { lock.withLock { soundPlayed = false } }
    // Counted as it happens, so a presentation that fails part-way leaves an exact record.
    func noteAdded() {
        lock.withLock {
            currentReport.posted += 1
            if currentReport.firstPostMilliseconds == nil {
                currentReport.firstPostMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
            }
        }
    }
    func noteJoined() { lock.withLock { joinedCount += 1 } }
    func noteExpired() { lock.withLock { expiredCount += 1 } }
}

/// Serializes runs in one extension process and lets concurrent `didReceive` calls share them. Call each request's
/// handler exactly once, from `deliver` or `expire`, whichever comes first. iOS may suspend the extension once every
/// handler ran, so neither answers while a run it ended still holds the lease.
public final class NotificationRunCoordinator: @unchecked Sendable {
    public typealias Operation = @Sendable (NotificationRunProgress) async -> NotificationRunOutcome

    /// iOS gives a push about 30 s and calls `serviceExtensionTimeWillExpire` near their end. A run still going this
    /// long after its first push arrived is cancelled, which closes its socket at once, so it answers with the lease
    /// released well before the expiry.
    public static let runLimit: Duration = .seconds(25)
    /// How long `expire` waits for the run it cancelled to close its store, which releases the lease.
    public static let expiryWait: Duration = .milliseconds(1500)

    // Every var is read and written only under the coordinator's `lock`.
    private final class Run: @unchecked Sendable {
        let progress = NotificationRunProgress()
        var task: Task<NotificationRunOutcome, Never>?
        var limit: Task<Void, Never>?
        var waiters = Set<UUID>()
        // The operation began, so the run may hold the lease until its task ends.
        var started = false
        var limitReached = false
    }

    private let lock = NSLock()
    private let operation: Operation
    private let runLimit: Duration
    private let clock: any Clock<Duration>
    private let startStopwatch: @Sendable () -> () -> Duration
    private var runs: [Run] = []
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "notifications")

    /// `clock` times `runLimit` and the expiry wait.
    public init<C: Clock<Duration>>(runLimit: Duration = NotificationRunCoordinator.runLimit, clock: C = ContinuousClock(),
                                    operation: @escaping Operation) {
        self.runLimit = runLimit; self.clock = clock; self.operation = operation
        startStopwatch = { stopwatch(clock) }
    }

    public func deliver(ticket: UUID) async -> NotificationRunOutcome {
        let (run, task) = attach(ticket)
        let outcome = await task.value
        lock.withLock { _ = run.waiters.remove(ticket) }
        return outcome
    }

    /// For `serviceExtensionTimeWillExpire`. Only a committed run suppresses. A run nobody else waits for is cancelled
    /// and waited for up to `wait`; candidates it did not delete are reposted later under the same identifiers, which
    /// replace. Past `wait` it answers anyway and logs a fault: the lease is never released under live work.
    public func expire(ticket: UUID, waitingUpTo wait: Duration = NotificationRunCoordinator.expiryWait) async -> NotificationRunOutcome {
        let found = lock.withLock { () -> (run: Run, ended: Task<NotificationRunOutcome, Never>?)? in
            guard let run = runs.first(where: { $0.waiters.contains(ticket) }) else { return nil }
            run.waiters.remove(ticket)
            run.progress.noteExpired()
            guard run.waiters.isEmpty else { return (run, nil) }
            run.progress.abandon()
            run.task?.cancel()
            // A run that never started holds nothing, and its cancelled task skips the operation.
            return (run, run.started ? run.task : nil)
        }
        let held = MessageStore.processHoldsTransportLock
        Self.log.notice("extension expiring, lease held=\(held, privacy: .public)")
        guard let found else { return .fallback(.expired) }
        if let ended = found.ended { await join(ended, of: found.run, within: wait, leaseHeld: held) }
        return found.run.progress.isCommitted ? .settled(found.run.progress.report) : .fallback(.expired)
    }

    public var activeRuns: Int { lock.withLock { runs.count } }

    private func join(_ task: Task<NotificationRunOutcome, Never>, of run: Run, within wait: Duration, leaseHeld held: Bool) async {
        let took = startStopwatch()
        let joined = (try? await withTimeout(wait, clock: clock) { await task.value }) != nil
        let milliseconds = Int(took() / .milliseconds(1))
        guard joined else {
            Self.log.fault("""
                expired run still stopping after \(milliseconds, privacy: .public) ms in \(run.progress.phase.rawValue, privacy: .public), \
                lease held=\(MessageStore.processHoldsTransportLock, privacy: .public)
                """)
            return
        }
        if held { Self.log.notice("lease released at expiry after \(milliseconds, privacy: .public) ms") }
    }

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
                // The next run starts only after the previous released the lease.
                if let previous { _ = await previous.value }
                var outcome: NotificationRunOutcome
                if self?.begin(run) == false { outcome = .fallback(.cancelled) } else { outcome = await operation(run.progress) }
                if case .fallback = outcome, self?.reachedLimit(run) == true { outcome = .fallback(.deadline) }
                run.progress.enter(.finished)
                self?.finished(run)
                return outcome
            }
            run.task = task
            // From the first push, so time a run spent queued behind the previous one counts.
            let limit = runLimit, clock = clock
            run.limit = Task { [weak self] in
                guard (try? await clock.sleep(for: limit)) != nil else { return }
                self?.stop(run)
            }
            runs.append(run)
            return (run, task)
        }
    }

    // Read with the cancellation under the lock, so `expire` either waits for a run or knows it never starts.
    private func begin(_ run: Run) -> Bool {
        lock.withLock {
            guard !Task.isCancelled else { return false }
            run.started = true
            return true
        }
    }

    private func stop(_ run: Run) {
        let stopped = lock.withLock { () -> Bool in
            guard runs.contains(where: { $0 === run }) else { return false }
            run.limitReached = true
            run.progress.abandon()
            run.task?.cancel()
            return true
        }
        if stopped { Self.log.notice("run cancelled at its limit in \(run.progress.phase.rawValue, privacy: .public)") }
    }

    private func reachedLimit(_ run: Run) -> Bool { lock.withLock { run.limitReached } }

    private func finished(_ run: Run) {
        lock.withLock {
            runs.removeAll { $0 === run }
            run.limit?.cancel()
        }
    }
}

// Started now; each call returns the time since.
func stopwatch<C: Clock<Duration>>(_ clock: C) -> () -> Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
}

/// Direct messages are presented as soon as the own archive committed, while rooms are still walked. Each
/// presentation claims only what it posted; stable identifiers make a later one replace, not duplicate.
public struct PresentationStage: Sendable {
    /// The early presentation leaves the phase alone, so pushes keep joining, and never commits or cleans up.
    public let isFinal: Bool
    /// Why rooms were cut short. A run that then added nothing throws it instead of settling: what the push was
    /// about is unknown.
    public let unfinished: (any Error)?

    public init(isFinal: Bool, unfinished: (any Error)? = nil) {
        self.isFinal = isFinal; self.unfinished = unfinished
    }
    public static let complete = PresentationStage(isFinal: true)
    public static let direct = PresentationStage(isFinal: false)
}

/// Posts a batch under the transport lease, then cleans up. Every `add` completes before the claimed rows are deleted
/// and the run commits; a failed or slow `add` throws, which means fallback.
public struct NotificationPresenter: Sendable {
    public let posting: any NotificationPosting
    public var addTimeout: Duration
    public var cleanupTimeout: Duration
    public var withdrawDonations: @Sendable (_ conversation: String) async -> Void = { await CommunicationHistory.deleteConversations([$0]) }
    /// Times the add and cleanup limits.
    public var clock: any Clock<Duration>

    public init(posting: any NotificationPosting, addTimeout: Duration = .seconds(4), cleanupTimeout: Duration = .seconds(3),
                clock: any Clock<Duration> = ContinuousClock()) {
        self.posting = posting; self.addTimeout = addTimeout; self.cleanupTimeout = cleanupTimeout; self.clock = clock
    }

    // Re-reads contact links so a plan made before an unlink or relink never donates the old contact; a link that
    // changes during the add withdraws the conversation's donations, also when the add failed.
    func add(_ planned: PlannedNotification, store: MessageStore, accountID: String,
             _ add: (PlannedNotification) async throws -> Void) async throws {
        let request = await planned.linkingContactsAsStored(store: store, accountID: accountID)
        do { try await add(request) } catch {
            await withdrawDonationsIfRelinked(request, store: store, accountID: accountID)
            throw error
        }
        await withdrawDonationsIfRelinked(request, store: store, accountID: accountID)
    }

    private func withdrawDonationsIfRelinked(_ request: PlannedNotification, store: MessageStore, accountID: String) async {
        guard let communication = request.communication else { return }
        let withdraw = withdrawDonations, timeout = cleanupTimeout, clock = clock
        await CommunicationHistory.withdrawIfRelinked([communication.sender] + communication.otherRecipients,
                                                      conversation: communication.conversationIdentifier, accountID: accountID, store: store) { conversation in
            // Only the limit throws, and a withdrawal past it still finishes on its own.
            _ = try? await withTimeout(timeout, clock: clock) { await withdraw(conversation) }
        }
    }

    /// `authorize` throws when the user signed out during the network work. Blocked candidates are claimed unshown and
    /// not counted in the badge.
    public func present(store: MessageStore, accountID: String, progress: NotificationRunProgress, stage: PresentationStage = .complete,
                        blocklist: XMPPBlocklist = XMPPBlocklist(), authorize: @Sendable () throws -> Void = {}) async throws {
        if stage.isFinal { progress.enter(.presenting) }
        try Task.checkCancellation()
        try authorize()
        let batch = try await store.pendingNotifications(accountID: accountID).excludingBlocked(blocklist)
        // An unknown badge leaves the icon as it is rather than failing the run.
        let badge = try? await NotificationBadge.count(store: store, accountID: accountID, blocklist: blocklist)
        let plan = NotificationPlanner.plan(batch, accountID: accountID, badge: badge, playsSound: !progress.hasPlayedSound)
        if plan.requests.isEmpty {
            if progress.report.posted == 0, let unfinished = stage.unfinished { throw unfinished }
            if !stage.isFinal { return }
        }
        progress.update { $0.badge = badge }
        for request in plan.requests {
            try Task.checkCancellation()
            if request.playsSound { progress.noteAddingSound() }
            do {
                try await add(request, store: store, accountID: accountID) { request in
                    try await withTimeout(addTimeout + posting.preparationAllowance(for: request), clock: clock) { try await posting.add(request) }
                }
            } catch {
                // A cancelled or timed-out add keeps running in the system and may still play the sound.
                if request.playsSound, !(error is CancellationError), error as? NotificationRunError != .postTimedOut {
                    progress.noteSoundRefused()
                }
                throw error
            }
            progress.noteAdded()
        }
        try await store.removeNotificationCandidates(accountID: accountID, keys: plan.claimed)
        progress.update { $0.claimed += plan.claimed.count; $0.deferred = batch.deferredCount }
        guard stage.isFinal else { return }
        progress.enter(.committed)
        // Cleanup is best effort and never changes the outcome.
        let removed = try? await withTimeout(cleanupTimeout, clock: clock) {
            try await removeStaleDelivered(store: store, accountID: accountID, summaryPosted: plan.summarizesDeferredChats)
        }
        if let removed { progress.update { $0.removedFallbacks = removed.fallbacks; $0.removedStale = removed.messages } }
    }

    // Removes every fallback (whatever its collapse identifier), messages retracted, missing or read, review
    // notifications no longer retained, withdrawn reactions, and a summary this run did not repost.
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
        let read = try await store.readNotificationMessageIDs(accountID: accountID, messageIDs: Set(bounded))
        var messages = stale.union(read).map { NotificationIdentity.message(accountID: accountID, messageID: $0) }
        messages += try await RetainedNotificationCleanup.staleIdentifiers(store: store, accountID: accountID, delivered: mine)
        messages += try await ReactionNotificationCleanup.staleIdentifiers(store: store, accountID: accountID, delivered: delivered)
        let summary = NotificationIdentity.overflow(accountID: accountID)
        if !summaryPosted, mine.contains(where: { $0.identifier == summary }) { messages.append(summary) }
        await posting.removeDelivered(identifiers: fallbacks + messages.sorted())
        return (fallbacks.count, messages.count)
    }
}

/// Review notifications whose ciphertext is no longer retained: it committed and alerts as the message itself, or
/// became a placeholder.
public enum RetainedNotificationCleanup {
    public static func staleIdentifiers(store: MessageStore, accountID: String, delivered: [DeliveredNotification]) async throws -> [String] {
        let retained = delivered.filter { $0.reference?.kind == .retained && $0.reference?.belongs(to: accountID) == true }
        guard !retained.isEmpty else { return [] }
        let live = Set(try await store.retainedEncryptedIncomingKeys(accountID: accountID).map { key in
            NotificationPlanner.identifier(accountID: accountID, key: key)
        })
        return retained.map(\.identifier).filter { !live.contains($0) }
    }
}

/// Reaction notifications withdrawn in part or whole, whose target is gone, or whose chat was read since.
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

// Returns at the limit even when the operation ignores cancellation, as the `UNUserNotificationCenter` bridges do: it
// races in an unstructured task left to finish on its own. A late system add may still show; a later run reposts the
// same identifier, which replaces it.
func withTimeout<T: Sendable>(_ limit: Duration, clock: any Clock<Duration> = ContinuousClock(),
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            race.start(continuation,
                       work: Task { do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) } },
                       timer: Task {
                           guard (try? await clock.sleep(for: limit)) != nil else { return }
                           race.finish(.failure(NotificationRunError.postTimedOut))
                       })
        }
    } onCancel: { race.finish(.failure(CancellationError())) }
}

// Resumes exactly once with whichever of work, timer or cancellation finishes first. A result that arrives before the
// continuation is installed is delivered on `start`.
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

extension PlannedNotification {
    func linkingContactsAsStored(store: MessageStore, accountID: String) async -> PlannedNotification {
        guard let communication else { return self }
        var others: [NotificationCommunication.Person] = []
        for person in communication.otherRecipients { others.append(await CommunicationHistory.linkedNow(person, accountID: accountID, store: store)) }
        let sender = await CommunicationHistory.linkedNow(communication.sender, accountID: accountID, store: store)
        let linked = NotificationCommunication(sender: sender, conversationIdentifier: communication.conversationIdentifier,
                                               account: communication.account, groupName: communication.groupName,
                                               groupAvatarHash: communication.groupAvatarHash, otherRecipients: others, body: communication.body)
        guard linked != communication else { return self }
        return PlannedNotification(identifier: identifier, threadIdentifier: threadIdentifier, categoryIdentifier: categoryIdentifier, title: title,
                                   body: body, playsSound: playsSound, destination: destination, communication: linked, reference: reference,
                                   badge: badge)
    }
}
