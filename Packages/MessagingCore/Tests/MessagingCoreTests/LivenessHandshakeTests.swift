import Foundation
import MessageStore
import Testing
@testable import MessagingCore

/// A running app on the far side of the handshake: it answers each request after `delay` with what `answer` decides,
/// as the app's responder writes it to the App Group.
private final class FakeApp: LivenessChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [LivenessRequest] = []
    private var answer: LivenessAnswer?
    private let delay: Duration
    private let decide: @Sendable (LivenessRequest) -> LivenessAnswer?

    init(after delay: Duration = .milliseconds(100), decide: @escaping @Sendable (LivenessRequest) -> LivenessAnswer?) {
        self.delay = delay; self.decide = decide
    }

    /// An app that can keep the promise, or not, answering through the real decision.
    convenience init(after delay: Duration = .milliseconds(100), conditions: LivenessConditions) {
        self.init(after: delay) { LivenessHandshake.answer(to: $0, conditions: conditions) }
    }

    var asked: Int { lock.withLock { requests.count } }

    func ask(_ request: LivenessRequest) throws {
        lock.withLock { requests.append(request) }
        Task {
            try? await Task.sleep(for: delay)
            let answer = decide(request)
            lock.withLock { if let answer { self.answer = answer } }
        }
    }

    func latestAnswer() -> LivenessAnswer? { lock.withLock { answer } }
}

private let live = LivenessConditions(wantsConnection: true, quiescing: false, ownsLease: true, servesExtensionAccount: true)

/// Runs `body` with a store whose lease another owner (the app) holds for the whole test.
private func withBusyLease(_ body: (MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "liveness-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let app = try MessageStore(url: url)
    try await app.acquireTransportOwnership()
    let extensionStore = try MessageStore(url: url)
    try await body(extensionStore)
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

    /// Each condition the promise needs, missing on its own, keeps the app silent: a quiescing app (on its way to the
    /// background or to sleep) is about to drop the lease and the connection.
    @Test(arguments: [
        LivenessConditions(wantsConnection: true, quiescing: true, ownsLease: true, servesExtensionAccount: true),
        LivenessConditions(wantsConnection: false, quiescing: false, ownsLease: true, servesExtensionAccount: true),
        LivenessConditions(wantsConnection: true, quiescing: false, ownsLease: false, servesExtensionAccount: true),
        LivenessConditions(wantsConnection: true, quiescing: false, ownsLease: true, servesExtensionAccount: false),
    ])
    func anAppThatCannotKeepThePromiseStaysSilent(_ conditions: LivenessConditions) {
        let now = Date()
        #expect(LivenessHandshake.answer(to: LivenessRequest(sentAt: now), conditions: conditions, now: now) == nil)
    }

    /// A ring delivered late (an app resumed from suspension) or a request from the future is not answered.
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
        try await withBusyLease { store in
            let app = FakeApp(conditions: live)
            let clock = ContinuousClock(), start = clock.now
            await #expect(throws: BackgroundSynchronizationError.handedOff) {
                try await acquireTransportOwnership(store, waitingUpTo: .seconds(6), liveness: app)
            }
            #expect(clock.now - start < .seconds(1))
            #expect(app.asked == 1)
        }
    }

    @Test func noAnswerKeepsTheWaitAndTheFallback() async throws {
        try await withBusyLease { store in
            let app = FakeApp { _ in nil }
            let clock = ContinuousClock(), start = clock.now
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                try await acquireTransportOwnership(store, waitingUpTo: .seconds(2), liveness: app)
            }
            #expect(clock.now - start >= .milliseconds(1_750))
            // Asked once per wait, not on every round.
            #expect(app.asked == 1)
        }
    }

    /// An answer after the window, while the wait goes on toward its fallback, never suppresses. (The real app does not
    /// answer a request this old at all; this one does.)
    @Test func aLateAnswerDoesNotHandOff() async throws {
        try await withBusyLease { store in
            let app = FakeApp(after: .seconds(LivenessHandshake.answerWindow + 0.3)) { LivenessAnswer(nonce: $0.nonce) }
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                try await acquireTransportOwnership(store, waitingUpTo: .seconds(2.5), liveness: app)
            }
            #expect(app.latestAnswer() != nil)
        }
    }

    @Test func aQuiescingAppNeverSuppresses() async throws {
        try await withBusyLease { store in
            let app = FakeApp(conditions: LivenessConditions(wantsConnection: true, quiescing: true, ownsLease: true, servesExtensionAccount: true))
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                try await acquireTransportOwnership(store, waitingUpTo: .seconds(2), liveness: app)
            }
            #expect(app.asked == 1 && app.latestAnswer() == nil)
        }
    }

    /// An answer to another request (a stale file, another wait's nonce) is ignored.
    @Test func anAnswerWithAnotherNonceIsIgnored() async throws {
        try await withBusyLease { store in
            let app = FakeApp { LivenessAnswer(nonce: $0.nonce + "-other", answeredAt: Date()) }
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
                try await acquireTransportOwnership(store, waitingUpTo: .seconds(2), liveness: app)
            }
        }
    }

    /// The lease is tried first on every round: a lease that comes free is taken, answered or not.
    @Test func aFreeLeaseNeverAsks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "liveness-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        let app = FakeApp(conditions: live)
        _ = try await acquireTransportOwnership(store, waitingUpTo: .seconds(6), liveness: app)
        #expect(app.asked == 0)
        try await store.close()
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
