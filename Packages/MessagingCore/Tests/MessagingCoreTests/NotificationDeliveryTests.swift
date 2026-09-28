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
    /// Time each add spends preparing (an intent donation) before the system add, and the system add itself.
    var preparation: Duration = .zero
    var systemAdd: Duration = .zero
    nonisolated let allowance: Duration

    init(delivered: [DeliveredNotification] = [], allowance: Duration = .zero) { self.delivered = delivered; self.allowance = allowance }
    func configure(failAtIndex: Int? = nil, hang: Bool = false, preparation: Duration = .zero, systemAdd: Duration = .zero) {
        self.failAtIndex = failAtIndex; self.hang = hang; self.preparation = preparation; self.systemAdd = systemAdd
    }
    nonisolated func preparationAllowance(for request: PlannedNotification) -> Duration { allowance }

    func add(_ request: PlannedNotification) async throws {
        // Like the UNUserNotificationCenter completion-handler bridge: a hung add ignores cancellation.
        if hang { await ignoringCancellation(for: .seconds(2)) }
        if preparation > .zero { await ignoringCancellation(for: preparation) }
        if systemAdd > .zero { await ignoringCancellation(for: systemAdd) }
        if failAtIndex == added.count { throw Failure.rejected }
        added.append(request)
        delivered.removeAll { $0.identifier == request.identifier }
        delivered.append(DeliveredNotification(identifier: request.identifier, categoryIdentifier: request.categoryIdentifier,
                                               destination: request.destination, reference: request.reference))
    }
    func deliver(_ notification: DeliveredNotification) { delivered.append(notification) }
    func deliveredNotifications() async -> [DeliveredNotification] { delivered }
    func removeDelivered(identifiers: [String]) async {
        removed += identifiers
        delivered.removeAll { identifiers.contains($0.identifier) }
    }
}

private let account = "alice@example.org"

/// Suspends for `duration` without observing cancellation, as a completion-handler bridge does.
func ignoringCancellation(for duration: Duration) async {
    let (seconds, attoseconds) = duration.components
    let delay = Double(seconds) + Double(attoseconds) / 1e18
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
    }
}

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
            let clock = ContinuousClock(), start = clock.now
            do {
                try await NotificationPresenter(posting: posting, addTimeout: .milliseconds(50)).present(store: store, accountID: account, progress: slow)
                Issue.record("A hanging add must not settle")
            } catch { #expect(NotificationFallbackReason(error) == .postFailed) }
            // The timeout returns at its limit although the hung add ignores cancellation.
            #expect(clock.now - start < .seconds(1))
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
            let progress = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: progress)
            // 20 messages plus one summary for the 5 chats without room: the settled run never hides them.
            let added = await posting.added
            #expect(added.count == 21 && progress.isCommitted && progress.report.deferred == 5)
            let summary = NotificationIdentity.overflow(accountID: account)
            #expect(added.first?.identifier == summary && added.first?.body == "New messages in 5 more chats" && added.first?.playsSound == false)
            #expect(added.filter(\.playsSound).map(\.identifier) == [added.last?.identifier])
            #expect(try await store.pendingNotifications(accountID: account).candidates.count == 5)
            // The next run posts the deferred chats themselves and removes the summary it no longer needs.
            let next = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: next)
            #expect(next.report.posted == 5 && next.report.deferred == 0)
            #expect(await !posting.delivered.map(\.identifier).contains(summary))
            #expect(await posting.removed.contains(summary))
        }
    }

    @Test func reviewAndPlaceholderNotificationsAreRemovedOnceStale() async throws {
        try await withStore { store in
            let revision = try #require(try await store.encryptionStateRevision(accountID: account))
            try await store.retainEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: "held", wire: Data([1]), reason: .trustPending,
                notification: PendingNotificationContext(chatID: "bob@example.org", sentAt: Date(timeIntervalSince1970: 1)))
            try await store.retainEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: "still", wire: Data([2]), reason: .trustPending,
                notification: PendingNotificationContext(chatID: "bob@example.org", sentAt: Date(timeIntervalSince1970: 2)))
            let posting = FakePosting()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            let review = await posting.added
            #expect(review.count == 2 && review.allSatisfy { $0.reference?.kind == .retained && $0.destination == nil })
            // Approval commits the first ciphertext: its review notification goes, the still-retained one stays.
            let approved = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "bob@example.org", senderID: "bob@example.org",
                                         body: "Synthetic", sentAt: Date(timeIntervalSince1970: 1), encryptionProfile: "modern")
            try await store.commitEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: "held", expectedRevision: revision,
                                                    state: Data([9]), message: approved)
            // A delivered placeholder whose row no longer exists (for example after the account was reset).
            let gone = try #require(NotificationReference.placeholder(accountID: account, messageID: "unreadable-" + String(repeating: "a", count: 64)))
            let goneID = NotificationIdentity.message(accountID: account, messageID: try #require(gone.messageID))
            await posting.deliver(DeliveredNotification(identifier: goneID, categoryIdentifier: NotificationIdentity.messageCategory, destination: nil, reference: gone))
            let progress = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: progress)
            let remaining = Set(await posting.delivered.map(\.identifier))
            #expect(!remaining.contains(review[0].identifier) && remaining.contains(review[1].identifier) && !remaining.contains(goneID))
            #expect(remaining.contains(NotificationIdentity.message(accountID: account, messageID: approved.id)))
            #expect(progress.report.removedStale == 2)
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

    @Test func messagesReadElsewhereLeaveNotificationCenterAtTheEndOfARun() async throws {
        try await withStore { store in
            let first = try await receive(store, body: "One", at: 1)
            let second = try await receive(store, body: "Two", at: 2)
            let posting = FakePosting()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.delivered.count == 2)
            // Another device read the first message (XEP-0490 or an own marker moves the same pointer).
            #expect(try await store.markRead(accountID: account, chatID: first.chatID, throughMessageID: first.id))
            let progress = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: progress)
            let remaining = Set(await posting.delivered.map(\.identifier))
            #expect(!remaining.contains(NotificationIdentity.message(accountID: account, messageID: first.id)))
            #expect(remaining.contains(NotificationIdentity.message(accountID: account, messageID: second.id)))
            #expect(progress.report.removedStale == 1)
        }
    }

    @Test func readingOrMutingAChatDropsItsRetainedReviewCandidate() async throws {
        try await withStore { store in
            let context = PendingNotificationContext(chatID: "bob@example.org", sentAt: Date(timeIntervalSince1970: 1))
            try await store.retainEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: "held", wire: Data([1]),
                                                    reason: .trustPending, notification: context)
            let later = try await receive(store, at: 5)
            #expect(try await store.markRead(accountID: account, chatID: later.chatID, throughMessageID: later.id))
            #expect(try await store.pendingNotifications(accountID: account).candidates.isEmpty)
            // A retained message older than the pointer never becomes a candidate again.
            try await store.retainEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: "old", wire: Data([2]),
                                                    reason: .trustPending, notification: context)
            #expect(try await store.pendingNotifications(accountID: account).candidates.isEmpty)
            // Muting a chat drops its waiting review alert too.
            try await store.upsertChat(accountID: account, chatID: "carol@example.org", title: "Carol")
            try await store.retainEncryptedIncoming(accountID: account, sender: "carol@example.org", digest: "carol", wire: Data([3]), reason: .trustPending,
                                                    notification: PendingNotificationContext(chatID: "carol@example.org", sentAt: Date(timeIntervalSince1970: 9)))
            #expect(try await store.pendingNotifications(accountID: account).candidates.count == 1)
            try await store.setChatNotificationSetting(accountID: account, chatID: "carol@example.org",
                                                       ChatNotificationSetting(level: .all, mutedUntil: Date().addingTimeInterval(3600)))
            #expect(try await store.pendingNotifications(accountID: account).candidates.isEmpty)
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

struct NotificationTimeoutTests {
    @Test func timeoutReturnsAtItsLimitWhenTheOperationIgnoresCancellation() async throws {
        let clock = ContinuousClock(), start = clock.now
        await #expect(throws: NotificationRunError.postTimedOut) {
            try await withTimeout(.milliseconds(100)) { await ignoringCancellation(for: .seconds(2)); return 1 }
        }
        #expect(clock.now - start < .seconds(1))
        #expect(try await withTimeout(.seconds(2)) { 7 } == 7)
        await #expect(throws: FakePosting.Failure.self) { try await withTimeout(.seconds(2)) { () async throws -> Int in throw FakePosting.Failure.rejected } }
    }

    @Test func cancellingTheCallerReturnsWithoutWaitingForTheOperation() async throws {
        let clock = ContinuousClock(), start = clock.now
        let task = Task { try await withTimeout(.seconds(5)) { await ignoringCancellation(for: .seconds(2)); return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(1))
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

struct NotificationBadgeAndReactionDeliveryTests {
    @Test func settledRunsCarryTheBadgeOnRequestsAndInTheReport() async throws {
        try await withStore { store in
            try await receive(store, chat: "bob@example.org", body: "One", at: 1)
            try await receive(store, chat: "carol@example.org", body: "Two", at: 2)
            try await receive(store, chat: "carol@example.org", body: "Three", at: 3)
            try await store.setChatNotificationSetting(accountID: account, chatID: "bob@example.org", ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
            let posting = FakePosting()
            let progress = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: progress)
            // Bob is muted: his unread message neither alerts nor counts.
            #expect(await posting.added.map(\.badge) == [2, 2])
            #expect(progress.report.badge == 2)
            #expect(try await NotificationBadge.count(store: store, accountID: account) == 2)
        }
    }

    @Test func aSlowDonationDoesNotShortenTheSystemAddsLimit() async throws {
        try await withStore { store in
            try await receive(store, at: 1)
            // Scaled down: a 240 ms donation (allowance 250 ms) followed by a 200 ms system add, with a 300 ms add limit.
            let posting = FakePosting(allowance: .milliseconds(250))
            await posting.configure(preparation: .milliseconds(240), systemAdd: .milliseconds(200))
            let progress = NotificationRunProgress()
            try await NotificationPresenter(posting: posting, addTimeout: .milliseconds(300)).present(store: store, accountID: account, progress: progress)
            #expect(progress.isCommitted && progress.report.posted == 1)
            // Without the allowance the same timings fall back, which is what the donation used to cause.
            try await receive(store, at: 2)
            let unallowed = FakePosting()
            await unallowed.configure(preparation: .milliseconds(240), systemAdd: .milliseconds(200))
            let failed = NotificationRunProgress()
            do {
                try await NotificationPresenter(posting: unallowed, addTimeout: .milliseconds(300)).present(store: store, accountID: account, progress: failed)
                Issue.record("the add limit alone must not cover the donation")
            } catch { #expect(NotificationFallbackReason(error) == .postFailed) }
        }
        let plain = PlannedNotification(identifier: "m", threadIdentifier: "t", title: "", body: "b", playsSound: false, destination: nil)
        let person = NotificationCommunication.Person(handle: "bob@x", displayName: "Bob", avatarHash: nil)
        let communicated = PlannedNotification(identifier: "m", threadIdentifier: "t", title: "Bob", body: "b", playsSound: false, destination: nil,
                                               communication: NotificationCommunication(sender: person, conversationIdentifier: "t", account: person, body: "b"))
        #expect(UserNotificationPoster.allowance(for: plain, donates: true) == .zero, "no communication, no donation")
        #expect(UserNotificationPoster.allowance(for: communicated, donates: false) == .zero)
        #expect(UserNotificationPoster.allowance(for: communicated, donates: true) == UserNotificationPoster.donationLimit)
    }

    @Test func aPartlyWithdrawnOrSeenReactionLeavesNotificationCenterAtTheEndOfARun() async throws {
        try await withStore { store in
            let mine = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "bob@example.org", senderID: account, body: "Lunch?",
                                     isOutgoing: true, encryptionProfile: "modern", wireID: "wire-mine", wireIDAuthenticated: true)
            try await store.upsertChat(accountID: account, chatID: "bob@example.org", title: "Bob")
            try await store.insertMessage(mine)
            func react(_ id: String, _ emoji: [String], at second: TimeInterval) async throws {
                let revision = try #require(try await store.encryptionStateRevision(accountID: account))
                try await store.commitEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: id, expectedRevision: revision,
                    state: Data([UInt8(revision % 250 + 1)]), message: nil,
                    reaction: AuthenticatedReaction(id: id, chatID: "bob@example.org", actorID: "bob@example.org", targetWireID: "wire-mine",
                                                    reactions: emoji, updatedAt: Date(timeIntervalSince1970: second)))
            }
            let posting = FakePosting()
            let identifier = NotificationIdentity.reaction(accountID: account, chatID: "bob@example.org", actorID: "bob@example.org", targetMessageID: mine.id)
            try await react("r1", ["❤️", "👍"], at: 10)
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.delivered.map(\.categoryIdentifier) == [NotificationIdentity.reactionCategory])
            // 👍 is withdrawn but ❤️ stays: the delivered "Reacted ❤️👍" is no longer true, and it does not re-alert.
            try await react("r2", ["❤️"], at: 20)
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            let removed = await posting.removed
            #expect(await posting.added.count == 1 && removed == [identifier])
            // A new reaction alerts; a message read after it (here or elsewhere) takes it out of Notification Center.
            try await react("r3", ["❤️", "🔥"], at: 30)
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.delivered.map(\.identifier) == [identifier])
            let incoming = try await receive(store, at: 40)
            #expect(try await store.markRead(accountID: account, chatID: "bob@example.org", throughMessageID: incoming.id))
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await !posting.delivered.map(\.identifier).contains(identifier))
        }
    }

    @Test func aWithdrawnReactionLosesItsDeliveredNotificationAndAReplacementReusesTheIdentifier() async throws {
        try await withStore { store in
            let mine = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "bob@example.org", senderID: account, body: "Lunch?",
                                     isOutgoing: true, encryptionProfile: "modern", wireID: "wire-mine", wireIDAuthenticated: true)
            try await store.upsertChat(accountID: account, chatID: "bob@example.org", title: "Bob")
            try await store.insertMessage(mine)
            func react(_ id: String, _ emoji: [String], at second: TimeInterval) async throws {
                let revision = try #require(try await store.encryptionStateRevision(accountID: account))
                try await store.commitEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: id, expectedRevision: revision,
                    state: Data([UInt8(revision % 250 + 1)]), message: nil,
                    reaction: AuthenticatedReaction(id: id, chatID: "bob@example.org", actorID: "bob@example.org", targetWireID: "wire-mine",
                                                    reactions: emoji, updatedAt: Date(timeIntervalSince1970: second)))
            }
            let posting = FakePosting()
            let identifier = NotificationIdentity.reaction(accountID: account, chatID: "bob@example.org", actorID: "bob@example.org", targetMessageID: mine.id)
            try await react("r1", ["👍"], at: 10)
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.added.map(\.identifier) == [identifier])
            #expect(await posting.added.map(\.body) == ["Reacted 👍 to “Lunch?”"])
            try await react("r2", ["🔥"], at: 20)
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.added.map(\.body) == ["Reacted 👍 to “Lunch?”", "Reacted 🔥 to “Lunch?”"])
            #expect(await posting.delivered.map(\.identifier) == [identifier], "a replacement replaces")
            #expect(await posting.removed.isEmpty)
            try await react("r3", [], at: 30)
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.removed == [identifier])
            #expect(await posting.delivered.isEmpty)
        }
    }
}
