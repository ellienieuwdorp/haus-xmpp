import Foundation
import MessageStore
import Testing
@testable import MessagingCore

// Records every call instead of touching the operating system's notification store.
actor FakePosting: NotificationPosting {
    enum Failure: Error { case rejected }
    private(set) var added: [PlannedNotification] = []
    private(set) var delivered: [DeliveredNotification] = []
    private(set) var removed: [String] = []
    var failAtIndex: Int?
    var hang = false
    // Time each add spends preparing (an intent donation) before the system add, and the system add itself, on `clock`.
    var preparation: Duration = .zero
    var systemAdd: Duration = .zero
    nonisolated let allowance: Duration
    nonisolated let clock: TestClock
    // Runs inside each add before it completes: what happens while a donation is in flight.
    private var during: (@Sendable (PlannedNotification) async -> Void)?

    init(delivered: [DeliveredNotification] = [], allowance: Duration = .zero, clock: TestClock = TestClock()) {
        self.delivered = delivered; self.allowance = allowance; self.clock = clock
    }
    func configure(failAtIndex: Int? = nil, hang: Bool = false, preparation: Duration = .zero, systemAdd: Duration = .zero) {
        self.failAtIndex = failAtIndex; self.hang = hang; self.preparation = preparation; self.systemAdd = systemAdd
    }
    nonisolated func preparationAllowance(for request: PlannedNotification) -> Duration { allowance }
    func duringAdd(_ hook: @escaping @Sendable (PlannedNotification) async -> Void) { during = hook }

    func add(_ request: PlannedNotification) async throws {
        // Like the UNUserNotificationCenter completion-handler bridge: a hung add ignores cancellation.
        if hang { await ignoringCancellation(for: .seconds(10), on: clock) }
        if preparation > .zero { await ignoringCancellation(for: preparation, on: clock) }
        if systemAdd > .zero { await ignoringCancellation(for: systemAdd, on: clock) }
        await during?(request)
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

func withStore(_ body: (MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "delivery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
    try await store.acquireTransportOwnership()
    try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
    do { try await body(store); try await store.close() } catch { try? await store.close(); throw error }
}

@discardableResult
func receive(_ store: MessageStore, chat: String = "bob@example.org", body: String = "Synthetic", at: TimeInterval,
                     wireID: String? = nil) async throws -> StoredMessage {
    let message = StoredMessage(id: UUID().uuidString, accountID: account, chatID: chat, senderID: chat, body: body,
                                sentAt: Date(timeIntervalSince1970: at), encryptionProfile: "modern", wireID: wireID, wireIDAuthenticated: wireID != nil)
    let revision = try #require(try await store.encryptionStateRevision(accountID: account))
    try await store.commitEncryptedIncoming(accountID: account, sender: chat, digest: message.id, expectedRevision: revision,
                                            state: Data([UInt8(revision % 250 + 1)]), message: message)
    return message
}

// The conversations whose donations a presenter withdrew.
actor WithdrawnDonations {
    private(set) var conversations: [String] = []
    func add(_ conversation: String) { conversations.append(conversation) }
}

func linkContact(_ store: MessageStore, chat: String, identifier: String) async throws {
    try await store.saveContactLink(ContactLink(accountID: account, jid: chat, contactIdentifier: identifier, source: .picker,
                                                displayName: "Robin Okafor", isReachable: true))
}

struct NotificationPresenterTests {
    // An extension run names the contact linked when each request posts, and a relink while one is posted (its
    // donation in flight) withdraws that conversation's donations once it is done, also when the add fails.
    @Test func aRelinkDuringAnAddWithdrawsTheConversationsDonations() async throws {
        try await withStore { store in
            try await linkContact(store, chat: "bob@example.org", identifier: "contact-1")
            try await receive(store, at: 1)
            let posting = FakePosting(), withdrawn = WithdrawnDonations()
            await posting.duringAdd { _ in try? await linkContact(store, chat: "bob@example.org", identifier: "contact-2") }
            await posting.configure(failAtIndex: 0)
            var presenter = NotificationPresenter(posting: posting)
            presenter.withdrawDonations = { await withdrawn.add($0) }
            await #expect(throws: FakePosting.Failure.self) {
                try await presenter.present(store: store, accountID: account, progress: NotificationRunProgress())
            }
            #expect(await withdrawn.conversations == [NotificationIdentity.thread(accountID: account, chatID: "bob@example.org")])

            // The next run names the new contact, and nothing changes meanwhile: nothing is withdrawn.
            await posting.configure()
            await posting.duringAdd { _ in }
            try await presenter.present(store: store, accountID: account, progress: NotificationRunProgress())
            #expect(await posting.added.map { $0.communication?.sender.contactIdentifier } == ["contact-2"])
            #expect(await withdrawn.conversations.count == 1)
        }
    }

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
            let clock = TestClock(), posting = FakePosting(clock: clock)
            await posting.configure(failAtIndex: 1)
            let failed = NotificationRunProgress()
            await #expect(throws: FakePosting.Failure.self) {
                try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: failed)
            }
            #expect(!failed.isCommitted)
            #expect(try await store.pendingNotifications(accountID: account).candidates.count == 2)
            await posting.configure(hang: true)
            let slow = NotificationRunProgress()
            let presenting = Task {
                try await NotificationPresenter(posting: posting, addTimeout: .milliseconds(50), clock: clock).present(store: store, accountID: account, progress: slow)
            }
            // The add's limit and the hung add.
            try await clock.sleepers(2)
            clock.advance(by: .milliseconds(50))
            do {
                try await bounded { try await presenting.value }
                Issue.record("A hanging add must not settle")
            } catch { #expect(NotificationFallbackReason(error) == .postFailed) }
            // The timeout returned at its limit while the hung add, which ignores cancellation, still sleeps.
            #expect(clock.elapsed == .milliseconds(50) && clock.sleeperCount == 1)
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

    // The app's cleanup asks the same question without a run: only this account's review notifications whose
    // ciphertext is gone are stale.
    @Test func retainedCleanupKeepsPendingReviewsAndOtherAccounts() async throws {
        try await withStore { store in
            let revision = try #require(try await store.encryptionStateRevision(accountID: account))
            for (digest, at) in [("held", 1.0), ("still", 2.0)] {
                try await store.retainEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: digest, wire: Data([1]), reason: .trustPending,
                    notification: PendingNotificationContext(chatID: "bob@example.org", sentAt: Date(timeIntervalSince1970: at)))
            }
            let posting = FakePosting()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: NotificationRunProgress())
            let review = await posting.added
            let approved = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "bob@example.org", senderID: "bob@example.org",
                                         body: "Synthetic", sentAt: Date(timeIntervalSince1970: 1), encryptionProfile: "modern")
            try await store.commitEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: "held", expectedRevision: revision,
                                                    state: Data([9]), message: approved)
            let other = try #require(NotificationReference.retained(accountID: "other@example.org"))
            let delivered = await posting.delivered.filter { $0.reference?.kind == .retained }
                + [DeliveredNotification(identifier: "other-review", categoryIdentifier: NotificationIdentity.messageCategory, destination: nil, reference: other)]
            let stale = try await RetainedNotificationCleanup.staleIdentifiers(store: store, accountID: account, delivered: delivered)
            #expect(stale == [review[0].identifier])
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
            // A 2.5 s donation (allowance 4 s) followed by a 0.5 s system add, with a 1.5 s add limit: 3 s of work within
            // 5.5 s with the allowance, against 1.5 s without it.
            let clock = TestClock()
            let posting = FakePosting(allowance: .seconds(4), clock: clock)
            await posting.configure(preparation: .milliseconds(2500), systemAdd: .milliseconds(500))
            let progress = NotificationRunProgress()
            let allowed = Task {
                try await NotificationPresenter(posting: posting, addTimeout: .milliseconds(1500), clock: clock).present(store: store, accountID: account, progress: progress)
            }
            // The 5.5 s limit beside the donation, then beside the system add.
            try await clock.sleeper(until: .milliseconds(2500))
            try await clock.sleeper(until: .milliseconds(5500))
            clock.advance(by: .milliseconds(2500))
            try await clock.sleeper(until: .seconds(3))
            clock.advance(by: .milliseconds(500))
            try await bounded { try await allowed.value }
            #expect(progress.isCommitted && progress.report.posted == 1)
            // Without the allowance the same timings fall back at the add limit, during the donation.
            try await receive(store, at: 2)
            let unallowed = FakePosting(clock: clock)
            await unallowed.configure(preparation: .milliseconds(2500), systemAdd: .milliseconds(500))
            let failed = NotificationRunProgress()
            let unallowedRun = Task {
                try await NotificationPresenter(posting: unallowed, addTimeout: .milliseconds(1500), clock: clock).present(store: store, accountID: account, progress: failed)
            }
            try await clock.sleeper(until: .milliseconds(5500))
            try await clock.sleeper(until: .milliseconds(4500))
            clock.advance(by: .milliseconds(1500))
            do {
                try await bounded { try await unallowedRun.value }
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
