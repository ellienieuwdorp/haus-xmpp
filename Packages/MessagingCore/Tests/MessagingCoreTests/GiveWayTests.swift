import Foundation
import MessageStore
import Testing
import XMPPProtocol
@testable import MessagingCore

// What the app saved in the App Group, read as the extension reads it. A takeover can land at a later instant on
// `clock`, as the app's next lease poll writes it.
private final class FakeAppFiles: GiveWayChannel, @unchecked Sendable {
    // `lock` guards `request` and `takeover`.
    private let lock = NSLock()
    private var request: GiveWayRequest?
    private var takeover: (value: GiveWayTakeover, landsAt: TestClock.Instant)?
    private let clock: TestClock

    init(clock: TestClock) { self.clock = clock }

    @discardableResult
    func ask(nonce: String = "wait-1", age: TimeInterval = 0) -> GiveWayRequest {
        let request = GiveWayRequest(nonce: nonce, sentAt: clock.date.addingTimeInterval(-age))
        save(request)
        return request
    }

    func save(_ request: GiveWayRequest) { lock.withLock { self.request = request } }

    func take(_ takeover: GiveWayTakeover, landingAt instant: TestClock.Instant? = nil) {
        let landsAt = instant ?? clock.now
        lock.withLock { self.takeover = (takeover, landsAt) }
    }

    func latestRequest() -> GiveWayRequest? { lock.withLock { request } }

    func latestTakeover() -> GiveWayTakeover? {
        let now = clock.now
        return lock.withLock { takeover.flatMap { $0.landsAt <= now ? $0.value : nil } }
    }
}

private let account = "alice@example.org", room = "room@rooms.example.org"

private func giveWay(_ app: FakeAppFiles, on clock: TestClock) -> GiveWaySwitch {
    GiveWaySwitch(channel: app, now: { clock.date })
}

// Runs `body` with two stores on one database: the app's, which holds the lease, and the extension's.
private func withBusyLease(_ body: (_ extension: MessageStore, _ app: MessageStore, _ url: URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "give-way-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let app = try MessageStore(url: url)
    try await app.acquireTransportOwnership()
    try await app.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
    let extensionStore = try MessageStore(url: url)
    try await body(extensionStore, app, url)
    try await extensionStore.close()
    try await app.close()
}

struct GiveWayTests {
    // MARK: The ring

    // Anyone may ring. Without a request in the App Group, or with one the app stopped refreshing, one stamped ahead
    // of the clock, one without a nonce or one the app already took the lease for, the run carries on.
    @Test func aRingWithoutAFreshUnansweredRequestDoesNothing() {
        let clock = TestClock(), app = FakeAppFiles(clock: clock), giveWay = giveWay(app, on: clock)
        giveWay.check()
        #expect(giveWay.request == nil)
        app.ask(age: GiveWayHandshake.requestLifetime + 0.5)
        giveWay.check()
        app.ask(age: -1)
        giveWay.check()
        app.ask(nonce: "")
        giveWay.check()
        let answered = app.ask(nonce: "wait-0")
        app.take(GiveWayTakeover(nonce: answered.nonce, takenAt: clock.date))
        giveWay.check()
        #expect(giveWay.request == nil)
        let fresh = app.ask(age: GiveWayHandshake.requestLifetime - 0.5)
        giveWay.check()
        #expect(giveWay.request == fresh)
    }

    // The final presentation has begun: the run ends on its own, and the app's next lease poll gets the lease.
    @Test func aRingAfterTheFinalPresentationBeganIsIgnored() {
        let clock = TestClock(), app = FakeAppFiles(clock: clock), giveWay = giveWay(app, on: clock)
        giveWay.close()
        app.ask()
        giveWay.check()
        #expect(giveWay.request == nil)
    }

    // MARK: Safe points

    // The ring lands right after the own archive committed, before the direct presentation. The run skips that
    // presentation, stops the transport while the room is still walked and posts nothing; the candidate it stored is
    // still there, and the app's foreground claim posts it.
    @Test func aRingMidWalkStopsAtTheNextSafePointAndLeavesTheCandidatesForTheClaim() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 1, roomMessage: false, trouble: .stalls)
            let app = FakeAppFiles(clock: run.clock), giveWay = giveWay(app, on: run.clock)
            let stop = await #expect(throws: GiveWayStop.self) {
                try await bounded {
                    try await run.run(budget: .seconds(10), giveWay: giveWay, onPull: {
                        app.ask()
                        giveWay.check()
                    })
                }
            }
            #expect(stop?.request.nonce == "wait-1")
            #expect(await run.trace.events == ["pull", "stop"])
            #expect(await run.posting.added.isEmpty)
            #expect(run.clock.elapsed == .zero)
            #expect(!run.progress.isCommitted && run.progress.phase < .presenting)
            // The own page and its cursor committed together; the room's cursor never moved.
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "own-1")
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room)?.cursor == "room-0")

            let pending = try await store.pendingNotifications(accountID: account)
            #expect(pending.candidates.map(\.chatID) == ["bob@example.org"])
            let posting = FakePosting()
            let posted = try await NotificationPresenter(posting: posting)
                .presentForeground(store: store, accountID: account, readingChatID: nil, presents: true, now: Date(timeIntervalSince1970: 1_060))
            #expect(posted == 1)
            #expect(await posting.added.map(\.body) == ["Direct"])
            #expect(try await store.pendingNotifications(accountID: account).candidates.isEmpty)
        }
    }

    // The ring lands while the direct presentation's add is still in the system. The stop waits for that add and the
    // claim of what it posted, so the app never posts the same message again, then stops the transport.
    @Test func aRingDuringTheDirectPresentationWaitsForItsPostsAndClaim() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 1, roomMessage: false, trouble: .stalls)
            await run.posting.delayFirstAdd(by: .seconds(1))
            let app = FakeAppFiles(clock: run.clock), giveWay = giveWay(app, on: run.clock)
            let work = Task { try await run.run(budget: .seconds(10), giveWay: giveWay) }
            try await run.clock.sleeper(until: .seconds(1))
            app.ask()
            giveWay.check()
            #expect(giveWay.request != nil)
            #expect(await run.trace.events == ["pull"])
            run.clock.advance(by: .seconds(1))
            await #expect(throws: GiveWayStop.self) { try await bounded { try await work.value } }
            #expect(await run.trace.events == ["pull", "post", "stop"])
            #expect(run.progress.report.posted == 1 && run.progress.report.claimed == 1)
            #expect(try await store.pendingNotifications(accountID: account).candidates.isEmpty)
            #expect(!run.progress.isCommitted)
        }
    }

    // A commit already running when the ring lands finishes before the run returns, and so before the lease goes;
    // nothing after it starts.
    @Test func aRingMidTransactionWaitsForItsCommit() async throws {
        let probe = BackgroundProbe(), clock = TestClock(), app = FakeAppFiles(clock: clock), giveWay = giveWay(app, on: clock)
        let work = Task {
            do {
                try await runBackgroundWork(timeBudget: .seconds(20), clock: clock, giveWay: giveWay, operation: {
                    await probe.begin()
                    // A store transaction runs whole on its actor once started, whatever cancellation arrives.
                    await ignoringCancellation(for: .seconds(1), on: clock)
                    await probe.record("commit finished")
                    try Task.checkCancellation()
                    await probe.record("next transaction")
                }, consume: {
                    await untilCancelled()
                    throw CancellationError()
                }, stop: { await probe.record("transport stopped") })
            } catch {
                await probe.record("returned")
                throw error
            }
        }
        try await bounded { await probe.waitForStart() }
        try await clock.sleeper(until: .seconds(1))
        app.ask()
        giveWay.check()
        try await eventually("the transport to stop") { await probe.events.contains("transport stopped") }
        #expect(await !probe.events.contains("returned"))
        clock.advance(by: .seconds(1))
        await #expect(throws: GiveWayStop.self) { try await bounded { try await work.value } }
        #expect(await probe.events == ["transport stopped", "commit finished", "returned"])
    }

    // Shielded work that never ends cannot hold the lease past the budget: the deadline cancels it.
    @Test func aStopWaitingForAPresentationStillEndsAtTheDeadline() async throws {
        let probe = BackgroundProbe(), clock = TestClock(), app = FakeAppFiles(clock: clock), giveWay = giveWay(app, on: clock)
        let work = Task {
            try await runBackgroundWork(timeBudget: .seconds(2), clock: clock, giveWay: giveWay, operation: {
                try await giveWay.shielded {
                    await probe.begin()
                    await untilCancelled()
                    throw CancellationError()
                }
            }, consume: {
                await untilCancelled()
                throw CancellationError()
            }, stop: {})
        }
        try await bounded { await probe.waitForStart() }
        app.ask()
        giveWay.check()
        try await clock.sleeper(until: .seconds(2))
        clock.advance(by: .seconds(2))
        await #expect(throws: BackgroundSynchronizationError.deadlineExceeded) { try await bounded { try await work.value } }
    }

    // The final presentation's add is in the system when the ring lands: the run commits as usual.
    @Test func aRingDuringTheFinalPresentationLetsTheRunFinish() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 0, roomMessage: true, trouble: nil)
            await run.posting.delayFirstAdd(by: .seconds(1))
            let app = FakeAppFiles(clock: run.clock), giveWay = giveWay(app, on: run.clock)
            let work = Task { try await run.run(budget: .seconds(10), giveWay: giveWay) }
            try await run.clock.sleeper(until: .seconds(1))
            app.ask()
            giveWay.check()
            run.clock.advance(by: .seconds(1))
            try await bounded { try await work.value }
            #expect(await run.posting.added.map(\.body) == ["Room"])
            #expect(run.progress.isCommitted)
            #expect(giveWay.request == nil)
        }
    }

    // MARK: The lease wait

    // An app waiting for the lease ends the extension's own wait, and the extension never takes a lease that came
    // free while the app waits for it.
    @Test func aRingDuringTheLeaseWaitEndsItWithoutTheLease() async throws {
        try await withBusyLease { store, app, url in
            let clock = TestClock(), files = FakeAppFiles(clock: clock), giveWay = giveWay(files, on: clock)
            let wait = Task { try await acquireTransportOwnership(store, waitingUpTo: .seconds(6), giveWay: giveWay, clock: clock) }
            try await clock.sleepers(1)
            files.ask()
            giveWay.check()
            clock.advance(by: .milliseconds(250))
            await #expect(throws: GiveWayStop.self) { try await bounded { try await wait.value } }
            #expect(clock.elapsed == .milliseconds(250))

            try await app.close()
            await #expect(throws: GiveWayStop.self) {
                try await acquireTransportOwnership(store, waitingUpTo: .seconds(6), giveWay: giveWay, clock: clock)
            }
            let next = try MessageStore(url: url)
            try await next.acquireTransportOwnership()
            try await next.close()
        }
    }

    // MARK: The takeover

    // The app's next lease poll takes the lease and saves its takeover with the request's nonce.
    @Test func theAppsTakeoverOfThisRequestHandsThePushOver() async throws {
        let clock = TestClock(), app = FakeAppFiles(clock: clock), giveWay = giveWay(app, on: clock)
        let request = app.ask()
        let landing = clock.now + .milliseconds(300)
        app.take(GiveWayTakeover(nonce: request.nonce, takenAt: clock.date(at: landing)), landingAt: landing)
        #expect(try await clock.run { try await giveWay.takeover(of: request, clock: clock) })
        #expect(clock.elapsed == .milliseconds(300))
    }

    enum Takeover: CaseIterable, CustomStringConvertible {
        case none, anotherWait, beforeTheRequest, afterTheWindow
        var description: String {
            switch self {
            case .none: "none"
            case .anotherWait: "anotherWait"
            case .beforeTheRequest: "beforeTheRequest"
            case .afterTheWindow: "afterTheWindow"
            }
        }
    }

    // No takeover, one for another lease wait, one stamped before this request was made, or one that lands after the
    // window: the extension falls back once the window ends.
    @Test(arguments: Takeover.allCases)
    func anythingElseEndsAtTheTakeoverWindowUnconfirmed(_ takeover: Takeover) async throws {
        let clock = TestClock(), app = FakeAppFiles(clock: clock), giveWay = giveWay(app, on: clock)
        let request = app.ask()
        switch takeover {
        case .none: break
        case .anotherWait: app.take(GiveWayTakeover(nonce: "wait-2", takenAt: clock.date))
        case .beforeTheRequest: app.take(GiveWayTakeover(nonce: request.nonce, takenAt: request.sentAt.addingTimeInterval(-1)))
        case .afterTheWindow:
            let late = clock.now + GiveWayHandshake.takeoverWindow + .milliseconds(50)
            app.take(GiveWayTakeover(nonce: request.nonce, takenAt: clock.date(at: late)), landingAt: late)
        }
        #expect(try await !clock.run { try await giveWay.takeover(of: request, clock: clock) })
        #expect(clock.elapsed == GiveWayHandshake.takeoverWindow)
    }

    // The whole run: the app asked before the run reached its lease wait, then took the lease. The run closes the
    // store without touching it and ends handed off; an unconfirmed takeover is a fallback, never suppressed.
    @Test func aConfirmedTakeoverEndsTheRunHandedOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "give-way-run-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        try await MessageStore(url: url).close()
        let clock = TestClock(), app = FakeAppFiles(clock: clock), giveWay = giveWay(app, on: clock)
        let request = app.ask()
        giveWay.check()
        app.take(GiveWayTakeover(nonce: request.nonce, takenAt: clock.date))
        let progress = NotificationRunProgress()
        let error = await #expect(throws: BackgroundSynchronizationError.handedOff) {
            try await BackgroundSynchronizer().synchronize(
                databaseURL: url, wrappingKey: Data(repeating: 1, count: 32),
                account: BackgroundAccount(route: .fixed(XMPPEndpoint(host: "localhost", port: 5223, security: .directTLS)), domain: "example.org",
                                           username: "alice", password: "unused"),
                giveWay: giveWay, progress: progress)
        }
        #expect(error.map { NotificationRunOutcome.ended(by: $0, progress: progress) } == .handedOff)
        #expect(progress.phase == .leaseWait)

        let unconfirmed = NotificationRunOutcome.ended(by: BackgroundSynchronizationError.takeoverUnconfirmed, progress: progress)
        #expect(unconfirmed == .fallback(.takeoverUnconfirmed) && !unconfirmed.suppressesRemoteAlert)
    }
}
