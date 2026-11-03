import Foundation
import MessageStore
import Testing
@testable import MessagingCore

// A running app on the far side of the handshake: it answers each request `delay` after it was asked, with what
// `decide` makes of it at that moment, as the app's responder writes it to the App Group.
private final class FakeApp: LivenessChannel, @unchecked Sendable {
    // `lock` guards `requests`.
    private let lock = NSLock()
    private var requests: [(request: LivenessRequest, asked: TestClock.Instant)] = []
    private let clock: TestClock
    private let delay: Duration
    private let decide: @Sendable (LivenessRequest, _ answeredAt: Date) -> LivenessAnswer?

    init(clock: TestClock, after delay: Duration = .milliseconds(100),
         decide: @escaping @Sendable (LivenessRequest, _ answeredAt: Date) -> LivenessAnswer?) {
        self.clock = clock; self.delay = delay; self.decide = decide
    }

    // An app that can keep the promise, or not, answering through the real decision.
    convenience init(clock: TestClock, after delay: Duration = .milliseconds(100), conditions: LivenessConditions) {
        self.init(clock: clock, after: delay) { LivenessHandshake.answer(to: $0, conditions: conditions, now: $1) }
    }

    var asked: Int { lock.withLock { requests.count } }

    func ask(_ request: LivenessRequest) throws {
        lock.withLock { requests.append((request, clock.now)) }
    }

    func latestAnswer() -> LivenessAnswer? {
        let now = clock.now
        return lock.withLock {
            requests.reversed().lazy.compactMap { [clock, delay, decide] in
                let answeredAt = $0.asked.advanced(by: delay)
                return answeredAt <= now ? decide($0.request, clock.date(at: answeredAt)) : nil
            }.first
        }
    }
}

// The extension's lease wait on `clock`, run to its end.
private func waitForLease(_ store: MessageStore, upTo limit: Duration, liveness: FakeApp, clock: TestClock) async throws {
    _ = try await clock.run {
        try await acquireTransportOwnership(store, waitingUpTo: limit, liveness: liveness, clock: clock, now: { clock.date })
    }
}

private let live = LivenessConditions(wantsConnection: true, quiescing: false, ownsLease: true, servesExtensionAccount: true,
                                      presentsCatchUp: true)
private let account = "alice@example.org"

// Runs `body` with the extension's store and the app's, which holds the lease for the whole test.
private func withBusyLease(_ body: (_ extension: MessageStore, _ app: MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "liveness-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let app = try MessageStore(url: url)
    try await app.acquireTransportOwnership()
    try await app.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
    let extensionStore = try MessageStore(url: url)
    try await body(extensionStore, app)
    try await extensionStore.close()
    try await app.close()
}

struct LivenessHandshakeTests {
    // MARK: The app's decision

    @Test func aLiveAppAnswersAFreshRequestWithItsNonce() {
        let request = LivenessRequest(nonce: "n1", sentAt: Date(timeIntervalSince1970: 1_000))
        let answer = LivenessHandshake.answer(to: request, conditions: live, now: Date(timeIntervalSince1970: 1_000.2))
        #expect(answer == LivenessAnswer(nonce: "n1", answeredAt: Date(timeIntervalSince1970: 1_000.2)))
    }

    // Each condition the promise needs, missing on its own, keeps the app silent: a quiescing app (on its way to the
    // background or to sleep) is about to drop the lease and the connection, and an app that dismisses what it
    // catches up on (the iPhone) could lose the message to a reconnect.
    @Test(arguments: [
        LivenessConditions(wantsConnection: true, quiescing: true, ownsLease: true, servesExtensionAccount: true, presentsCatchUp: true),
        LivenessConditions(wantsConnection: false, quiescing: false, ownsLease: true, servesExtensionAccount: true, presentsCatchUp: true),
        LivenessConditions(wantsConnection: true, quiescing: false, ownsLease: false, servesExtensionAccount: true, presentsCatchUp: true),
        LivenessConditions(wantsConnection: true, quiescing: false, ownsLease: true, servesExtensionAccount: false, presentsCatchUp: true),
        LivenessConditions(wantsConnection: true, quiescing: false, ownsLease: true, servesExtensionAccount: true, presentsCatchUp: false),
    ])
    func anAppThatCannotKeepThePromiseStaysSilent(_ conditions: LivenessConditions) {
        let now = Date()
        #expect(LivenessHandshake.answer(to: LivenessRequest(sentAt: now), conditions: conditions, now: now) == nil)
    }

    // A ring delivered late (an app resumed from suspension) or a request from the future is not answered.
    @Test func onlyAFreshRequestIsAnswered() {
        let sent = Date(timeIntervalSince1970: 1_000)
        func answers(after seconds: TimeInterval) -> Bool {
            LivenessHandshake.answer(to: LivenessRequest(sentAt: sent), conditions: live, now: sent.addingTimeInterval(seconds)) != nil
        }
        #expect(answers(after: 0) && answers(after: LivenessHandshake.requestLifetime))
        #expect(!answers(after: LivenessHandshake.requestLifetime + 0.1))
        #expect(!answers(after: -1))
        #expect(LivenessHandshake.answer(to: nil, conditions: live) == nil)
        #expect(LivenessHandshake.answer(to: LivenessRequest(nonce: "", sentAt: sent), conditions: live, now: sent) == nil)
    }

    // MARK: The extension's decision

    @Test func theExtensionTakesOnlyAnAnswerToItsNonceInsideTheWindow() {
        let sent = Date(timeIntervalSince1970: 1_000)
        let request = LivenessRequest(nonce: "mine", sentAt: sent)
        let inTime = sent.addingTimeInterval(0.3)
        #expect(LivenessHandshake.accepts(LivenessAnswer(nonce: "mine", answeredAt: inTime), to: request, now: inTime))
        #expect(!LivenessHandshake.accepts(nil, to: request, now: inTime))
        #expect(!LivenessHandshake.accepts(LivenessAnswer(nonce: "other", answeredAt: inTime), to: request, now: inTime))
        // Given after the window, or read after it.
        let late = sent.addingTimeInterval(LivenessHandshake.answerWindow + 0.1)
        #expect(!LivenessHandshake.accepts(LivenessAnswer(nonce: "mine", answeredAt: late), to: request, now: late))
        #expect(!LivenessHandshake.accepts(LivenessAnswer(nonce: "mine", answeredAt: inTime), to: request, now: late))
        // An answer older than the request is not to it.
        #expect(!LivenessHandshake.accepts(LivenessAnswer(nonce: "mine", answeredAt: sent.addingTimeInterval(-5)), to: request, now: inTime))
    }

    // MARK: The extension's lease wait

    @Test func anAnswerInTimeHandsThePushToTheApp() async throws {
        try await withBusyLease { store, _ in
            let clock = TestClock(), app = FakeApp(clock: clock, conditions: live)
            await #expect(throws: BackgroundSynchronizationError.handedOff) {
                try await waitForLease(store, upTo: .seconds(6), liveness: app, clock: clock)
            }
            // The first answer poll after the app's 100 ms reply.
            #expect(clock.elapsed == .milliseconds(100))
            #expect(app.asked == 1)
        }
    }

    @Test func noAnswerKeepsTheWaitAndTheFallback() async throws {
        try await withBusyLease { store, _ in
            let clock = TestClock(), app = FakeApp(clock: clock) { _, _ in nil }
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                try await waitForLease(store, upTo: .seconds(2), liveness: app, clock: clock)
            }
            #expect(clock.elapsed == .seconds(2))
            // Asked once per wait, not on every round.
            #expect(app.asked == 1)
        }
    }

    // An answer after the window, while the wait goes on toward its fallback, never suppresses. (The real app does not
    // answer a request this old at all; this one does.)
    @Test func aLateAnswerDoesNotHandOff() async throws {
        try await withBusyLease { store, _ in
            let clock = TestClock()
            let app = FakeApp(clock: clock, after: .seconds(LivenessHandshake.answerWindow + 0.3)) { LivenessAnswer(nonce: $0.nonce, answeredAt: $1) }
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                try await waitForLease(store, upTo: .seconds(2.5), liveness: app, clock: clock)
            }
            #expect(clock.elapsed == .seconds(2.5))
            #expect(app.latestAnswer() != nil)
        }
    }

    @Test func aQuiescingAppNeverSuppresses() async throws {
        try await withBusyLease { store, _ in
            var quiescing = live
            quiescing.quiescing = true
            let clock = TestClock(), app = FakeApp(clock: clock, conditions: quiescing)
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                try await waitForLease(store, upTo: .seconds(2), liveness: app, clock: clock)
            }
            #expect(app.asked == 1 && app.latestAnswer() == nil)
        }
    }

    // An answer to another request (a stale file, another wait's nonce) is ignored.
    @Test func anAnswerWithAnotherNonceIsIgnored() async throws {
        try await withBusyLease { store, _ in
            let clock = TestClock()
            let app = FakeApp(clock: clock) { LivenessAnswer(nonce: $0.nonce + "-other", answeredAt: $1) }
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                try await waitForLease(store, upTo: .seconds(2), liveness: app, clock: clock)
            }
            #expect(app.latestAnswer() != nil)
        }
    }

    // A wall clock set back during the wait cannot stretch the window: the extension stops listening on the monotonic
    // clock, so an answer the wall clock still calls in time is ignored.
    @Test func aWallClockSetBackDoesNotStretchTheWindow() async throws {
        try await withBusyLease { store, _ in
            let clock = TestClock()
            let app = FakeApp(clock: clock, after: .seconds(LivenessHandshake.answerWindow + 0.3)) { request, _ in
                LivenessAnswer(nonce: request.nonce, answeredAt: request.sentAt)
            }
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                _ = try await clock.run {
                    try await acquireTransportOwnership(store, waitingUpTo: .seconds(2.5), liveness: app, clock: clock,
                                                        now: { Date(timeIntervalSince1970: 1_000_000_000) })
                }
            }
            #expect(app.latestAnswer() != nil)
        }
    }

    // The lease is tried first on every round: a lease that comes free is taken, answered or not.
    @Test func aFreeLeaseNeverAsks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "liveness-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        let clock = TestClock(), app = FakeApp(clock: clock, conditions: live)
        try await waitForLease(store, upTo: .seconds(6), liveness: app, clock: clock)
        #expect(app.asked == 0 && clock.elapsed == .zero)
        try await store.close()
    }

    // MARK: After a hand-off

    // The Mac may sleep or lose its stream after answering, so the message may come with a much later catch-up. The
    // hand-off claims nothing and the desktop catch-up claim posts whatever its age, so the push still ends in a
    // banner; the phone's claim would dismiss it as history, which is why only an app that presents catch-up answers.
    @Test func whatArrivesAfterAHandOffIsPostedByTheNextCatchUp() async throws {
        try await withBusyLease { store, app in
            let now = Date().timeIntervalSince1970
            try await receive(app, chat: "bob@example.org", body: "Held while catching up", at: now - 60)
            let clock = TestClock()
            await #expect(throws: BackgroundSynchronizationError.handedOff) {
                try await waitForLease(store, upTo: .seconds(6), liveness: FakeApp(clock: clock, conditions: live), clock: clock)
            }
            #expect(try await app.pendingNotifications(accountID: account).candidates.count == 1)
            try await receive(app, chat: "carol@example.org", body: "Sent before the sleep", at: now - 8 * 3_600)
            let posting = FakePosting()
            let posted = try await NotificationPresenter(posting: posting)
                .presentCaughtUp(store: app, accountID: account, readingChatID: nil, presents: true)
            #expect(posted == 2)
            #expect(Set(await posting.added.map(\.body)) == ["Held while catching up", "Sent before the sleep"])
        }
    }

    // MARK: Outcome

    @Test func aHandedOffRunSuppressesTheRemoteAlert() {
        let progress = NotificationRunProgress()
        let outcome = NotificationRunOutcome.ended(by: BackgroundSynchronizationError.handedOff, progress: progress)
        #expect(outcome == .handedOff && outcome.suppressesRemoteAlert)
        #expect(NotificationRunOutcome.ended(by: MessageStoreError.transportOwnedElsewhere, progress: progress) == .fallback(.leaseBusy))
        #expect(NotificationOutcomeRecord(progress: progress, outcome: .handedOff).outcome == "handed-off")
    }
}
