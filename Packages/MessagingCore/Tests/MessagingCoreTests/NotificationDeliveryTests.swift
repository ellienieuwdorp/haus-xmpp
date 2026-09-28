import Foundation
import MessageStore
import Testing
@testable import MessagingCore

/// Records every call instead of touching the operating system's notification store.
actor FakePosting: NotificationPosting {
    enum Failure: Error { case rejected }
    private(set) var added: [PlannedNotification] = []
    private(set) var delivered: [DeliveredNotification] = []
    private(set) var removed: [String] = []
    var failAtIndex: Int?
    var hang = false

    init(delivered: [DeliveredNotification] = []) { self.delivered = delivered }
    func configure(failAtIndex: Int? = nil, hang: Bool = false) { self.failAtIndex = failAtIndex; self.hang = hang }

    func add(_ request: PlannedNotification) async throws {
        if hang { try await Task.sleep(for: .seconds(30)) }
        if failAtIndex == added.count { throw Failure.rejected }
        added.append(request)
        delivered.removeAll { $0.identifier == request.identifier }
        delivered.append(DeliveredNotification(identifier: request.identifier, categoryIdentifier: request.categoryIdentifier, destination: request.destination))
    }
    func deliveredNotifications() async -> [DeliveredNotification] { delivered }
    func removeDelivered(identifiers: [String]) async {
        removed += identifiers
        delivered.removeAll { identifiers.contains($0.identifier) }
    }
}

private let account = "alice@example.org"

private func withStore(_ body: (MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "delivery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
    try await store.acquireTransportOwnership()
    try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
    do { try await body(store); try await store.close() } catch { try? await store.close(); throw error }
}

@discardableResult
private func receive(_ store: MessageStore, chat: String = "bob@example.org", body: String = "Synthetic", at: TimeInterval,
                     wireID: String? = nil) async throws -> StoredMessage {
    let message = StoredMessage(id: UUID().uuidString, accountID: account, chatID: chat, senderID: chat, body: body,
                                sentAt: Date(timeIntervalSince1970: at), encryptionProfile: "modern", wireID: wireID, wireIDAuthenticated: wireID != nil)
    let revision = try #require(try await store.encryptionStateRevision(accountID: account))
    try await store.commitEncryptedIncoming(accountID: account, sender: chat, digest: message.id, expectedRevision: revision,
                                            state: Data([UInt8(revision % 250 + 1)]), message: message)
    return message
}

struct NotificationPresenterTests {
    @Test func postsEveryRequestBeforeDeletingClaimsAndCommitting() async throws {
        try await withStore { store in
            let first = try await receive(store, body: "One", at: 1)
            let second = try await receive(store, body: "Two", at: 2)
            let posting = FakePosting()
            let progress = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: progress)
            let added = await posting.added
            #expect(added.map(\.identifier) == [first, second].map { NotificationIdentity.message(accountID: account, messageID: $0.id) })
            #expect(added.map(\.playsSound) == [false, true])
            #expect(progress.isCommitted && progress.report.posted == 2 && progress.report.claimed == 2)
            #expect(try await store.pendingNotifications(accountID: account).candidates.isEmpty)
            // A settled run with nothing new (a receipt or own-carbon push) posts nothing and still commits.
            let quiet = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: quiet)
            let total = await posting.added.count
            #expect(quiet.isCommitted && quiet.report.posted == 0 && total == 2)
        }
    }

    @Test func aFailedOrSlowAddKeepsEveryCandidateAndNeverCommits() async throws {
        try await withStore { store in
            try await receive(store, at: 1); try await receive(store, at: 2)
            let posting = FakePosting()
            await posting.configure(failAtIndex: 1)
            let failed = NotificationRunProgress()
            await #expect(throws: FakePosting.Failure.self) {
                try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: failed)
            }
            #expect(!failed.isCommitted)
            #expect(try await store.pendingNotifications(accountID: account).candidates.count == 2)
            await posting.configure(hang: true)
            let slow = NotificationRunProgress()
            do {
                try await NotificationPresenter(posting: posting, addTimeout: .milliseconds(50)).present(store: store, accountID: account, progress: slow)
                Issue.record("A hanging add must not settle")
            } catch { #expect(NotificationFallbackReason(error) == .postFailed) }
            #expect(!slow.isCommitted)
            // The retry reposts the same identifiers: the one already added is replaced, not duplicated.
            await posting.configure()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(Set(await posting.delivered.map(\.identifier)).count == 2)
        }
    }

    @Test func revokedAuthorizationPostsNothing() async throws {
        try await withStore { store in
            try await receive(store, at: 1)
            let posting = FakePosting()
            await #expect(throws: CancellationError.self) {
                try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress(),
                                                                          authorize: { throw CancellationError() })
            }
            #expect(await posting.added.isEmpty)
        }
    }

    @Test func aBurstIsCappedPerRunAndTheRestWaits() async throws {
        try await withStore { store in
            for index in 0..<25 { try await receive(store, chat: "peer\(index)@example.org", at: Double(index)) }
            let posting = FakePosting()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.added.count == 20)
            #expect(await posting.added.filter(\.playsSound).count == 1)
            #expect(try await store.pendingNotifications(accountID: account).candidates.count == 5)
        }
    }

    @Test func successRemovesDeliveredFallbacksAndRetractedMessagesOnly() async throws {
        try await withStore { store in
            let kept = try await receive(store, at: 1, wireID: "w1")
            let unsent = try await receive(store, at: 2, wireID: "w2")
            let other = try #require(NotificationDestination(accountID: "other@example.org", messageID: UUID().uuidString))
            let posting = FakePosting(delivered: [
                DeliveredNotification(identifier: "collapse-1", categoryIdentifier: NotificationIdentity.fallbackCategory, destination: nil),
                DeliveredNotification(identifier: "other-account", categoryIdentifier: NotificationIdentity.messageCategory, destination: other)])
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.removed == ["collapse-1"])
            // The sender unsends one; the next settled run removes exactly that delivered notification.
            let revision = try #require(try await store.encryptionStateRevision(accountID: account))
            try await store.commitEncryptedIncoming(accountID: account, sender: unsent.chatID, digest: "unsend", expectedRevision: revision, state: Data([99]),
                message: nil, event: MessageEvent(id: "r", chatID: unsent.chatID, actorID: unsent.chatID, targetWireID: "w2", kind: .retraction, payload: "{}", updatedAt: Date()))
            let progress = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: progress)
            let remaining = await posting.delivered.map(\.identifier)
            #expect(remaining.contains(NotificationIdentity.message(accountID: account, messageID: kept.id)))
            #expect(!remaining.contains(NotificationIdentity.message(accountID: account, messageID: unsent.id)))
            #expect(remaining.contains("other-account"))
            #expect(progress.report.removedStale == 1 && progress.report.removedFallbacks == 0)
        }
    }
}

/// A run whose steps the test releases one at a time.
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

private func eventually(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
    Issue.record("Condition never became true")
}

struct NotificationRunCoordinatorTests {
    @Test func pushesDuringTheNetworkPhaseJoinOneRunAndShareItsOutcome() async throws {
        let gate = Gate(), runs = Counter()
        let coordinator = NotificationRunCoordinator { progress in
            _ = await runs.increment()
            progress.enter(.syncing)
            await gate.wait()
            progress.enter(.committed)
            return .settled(progress.report)
        }
        let first = Task { await coordinator.deliver(ticket: UUID()) }
        try await eventually { await runs.value == 1 }
        let second = Task { await coordinator.deliver(ticket: UUID()) }
        let third = Task { await coordinator.deliver(ticket: UUID()) }
        try await Task.sleep(for: .milliseconds(20))
        await gate.release()
        let outcomes = [await first.value, await second.value, await third.value]
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
        await presenting.wait()
        let second = Task { await coordinator.deliver(ticket: UUID()) }
        try await Task.sleep(for: .milliseconds(20))
        // The second run waits for the first: one lease owner at a time.
        #expect(await runs.value == 1)
        await finish.release()
        let outcomes = [await first.value, await second.value]
        #expect(outcomes.allSatisfy { $0.suppressesRemoteAlert })
        #expect(await runs.value == 2)
    }

    @Test func expiryBeforeCommitFallsBackAndCancelsAnAbandonedRun() async throws {
        let started = Gate(), cancelled = Gate()
        let coordinator = NotificationRunCoordinator { progress in
            progress.enter(.syncing)
            await started.release()
            do { try await Task.sleep(for: .seconds(30)) } catch { await cancelled.release() }
            return .fallback(.cancelled)
        }
        let ticket = UUID()
        let delivery = Task { await coordinator.deliver(ticket: ticket) }
        await started.wait()
        #expect(coordinator.expire(ticket: ticket) == .fallback(.expired))
        await cancelled.wait()
        #expect(await delivery.value == .fallback(.cancelled))
        // Expiring an unknown or already finished request still answers, and never suppresses.
        #expect(coordinator.expire(ticket: UUID()) == .fallback(.expired))
    }

    @Test func expiryAfterCommitSuppressesAndOtherWaitersKeepTheRun() async throws {
        let committed = Gate(), finish = Gate()
        let coordinator = NotificationRunCoordinator { progress in
            progress.enter(.syncing)
            await committed.wait()
            progress.update { $0.posted = 3 }
            progress.enter(.committed)
            await finish.wait()
            return .settled(progress.report)
        }
        let early = UUID(), late = UUID()
        let first = Task { await coordinator.deliver(ticket: early) }
        try await eventually { coordinator.activeRuns == 1 }
        let second = Task { await coordinator.deliver(ticket: late) }
        try await Task.sleep(for: .milliseconds(20))
        // Unknown outcome: fall back, but the joined request keeps the run alive.
        #expect(coordinator.expire(ticket: early) == .fallback(.expired))
        await committed.release()
        try await Task.sleep(for: .milliseconds(20))
        guard case let .settled(report) = coordinator.expire(ticket: late) else { Issue.record("Committed run must suppress"); return }
        #expect(report.posted == 3)
        await finish.release()
        _ = await first.value; _ = await second.value
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
        await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
            try await acquireTransportOwnership(waiter, waitingUpTo: .milliseconds(120), interval: .milliseconds(20))
        }
        let cancelled = Task { try await acquireTransportOwnership(waiter, waitingUpTo: .seconds(5), interval: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let released = Task { try await acquireTransportOwnership(waiter, waitingUpTo: .seconds(5), interval: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        try await holder.releaseTransportOwnership()
        let waited = try await released.value
        #expect(waited >= .milliseconds(80) && waited < .seconds(5))
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
