import Foundation
import MessageStore
import OMEMO
import Testing
import XMPPProtocol
@testable import MessagingCore

// The background grace on the engine, on a test clock: it holds the stream for the outbox only while work is
// pending, ends at idle, at its deadline, at expiry or at a return to the foreground, and then runs the bounded quiesce.
// Nothing re-acquires the lease until the foreground, and a message left unsent gets the content-free notice.
@MainActor struct BackgroundGraceTests {
    @MainActor private final class Owner: SessionEngineDelegate {
        var wantsTransport = false
        var holdsGrace = false
        var started = 0
        var endings: [GraceEnd] = []
        var notices: [Bool] = []
        var stuck: [[String]] = []
        var passes = 0
        var released = 0
        func graceStarted() { started += 1 }
        func graceEnding(_ end: GraceEnd) { endings.append(end) }
        func unsentNotice(_ visible: Bool) { notices.append(visible) }
        func quiesceStuck(_ work: [String]) { stuck.append(work) }
        func outboxHooks(token: UUID) -> OutboxDrain.Hooks { passes += 1; return OutboxDrain.Hooks() }
        func release() -> Bool { released += 1; return true }
    }

    private static let account = "alice@localhost"

    // A stream that is up and holds the lease, as the app has it when it leaves the foreground.
    private func engine(_ owner: Owner, clock: TestClock, remaining: Duration? = .seconds(30)) throws -> SessionEngine {
        let suite = "BackgroundGraceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let engine = SessionEngine(profiles: ServerProfileMemory(defaults: defaults))
        engine.delegate = owner
        engine.account = Self.account
        engine.clock = EngineClock(clock)
        engine.backgroundTimeRemaining = { remaining }
        engine.attach(XMPPClient())
        engine.streamOnline = true
        engine.hasTransportOwnership = true
        return engine
    }

    // The store, encryption and sender an outbox pass needs; the pass itself fails without an identity or the lease,
    // which ends it like any other pass.
    private func withStore(_ engine: SessionEngine) throws -> MessageStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "grace-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        engine.store = store
        engine.encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        engine.outboxSender = OutboxSender(store: store)
        return store
    }

    private func queue(_ body: String, store: MessageStore) async throws {
        try await store.upsertChat(accountID: Self.account, chatID: "bob@localhost", title: "bob@localhost")
        _ = try await OutgoingEnqueue.text(body, account: Self.account, chatID: "bob@localhost", store: store)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("never: \(what)")
        throw CancellationError()
    }

    private func leave(_ engine: SessionEngine, _ owner: Owner, grace: Bool = true) -> Task<BackgroundOutcome, Never> {
        engine.backgroundRequested(grace: grace)
        return Task { await engine.enterBackground(release: { owner.release() }) }
    }

    @Test func anIdleSessionHoldsNoGraceAndQuiescesAtOnce() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        let outcome = await leave(engine, owner).value
        #expect(outcome.grace == .idle && outcome.graceDuration == .zero)
        #expect(owner.started == 0 && owner.endings.isEmpty)
        #expect(outcome.quiesce?.released == true && owner.released == 1)
        #expect(engine.backgroundPhase == .background && engine.quiescing)
        #expect(owner.notices.isEmpty)
    }

    @Test func theGraceEndsOnceIdleThenQuiesces() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        owner.holdsGrace = true
        let run = leave(engine, owner)
        try await until("the grace to start") { owner.started == 1 }
        #expect(engine.backgroundPhase == .grace && owner.released == 0)
        owner.holdsGrace = false
        engine.graceWorkChanged()
        let outcome = await run.value
        #expect(outcome.grace == .idle && owner.endings == [.idle])
        #expect(outcome.quiesce == TransportQuiesce.Outcome(released: true) && owner.released == 1)
        #expect(engine.backgroundPhase == .background && engine.quiescing)
    }

    @Test func theGraceEndsAtItsDeadline() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        owner.holdsGrace = true
        let run = leave(engine, owner)
        // 30 s granted: min(20 s, 30 − 5 − 4 s).
        try await clock.sleeper(until: .seconds(20))
        clock.advance(by: .seconds(20))
        let outcome = await run.value
        #expect(outcome.grace == .deadline && outcome.graceDuration == .seconds(20))
        #expect(outcome.quiesce?.released == true && outcome.quiesce?.hardClosed == false)
    }

    @Test func aShortBudgetLeavesNoGrace() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock, remaining: .seconds(8))
        owner.holdsGrace = true
        let outcome = await leave(engine, owner).value
        #expect(outcome.grace == .deadline && outcome.graceDuration == .zero && owner.started == 0)
        #expect(outcome.quiesce?.released == true)
    }

    @Test func expiryDuringTheGraceRunsTheBoundedQuiesceAndNeverReleasesUnderLiveWork() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        owner.holdsGrace = true
        let run = leave(engine, owner)
        try await until("the grace to start") { owner.started == 1 }
        // A UI crypto mutation that began before the transition and does not end.
        engine.activeOperations = 1
        engine.backgroundTimeExpiring()
        try await clock.sleeper(until: .seconds(1))
        clock.advance(by: .seconds(1))
        try await until("the stuck work to be named") { !owner.stuck.isEmpty }
        #expect(owner.stuck == [["1 crypto operation(s)"]] && owner.released == 0)
        #expect(owner.endings == [.expired])
        engine.activeOperations = 0
        let outcome = await run.value
        #expect(outcome.grace == .expired)
        #expect(outcome.quiesce == TransportQuiesce.Outcome(hardClosed: true, stuck: ["1 crypto operation(s)"], released: true))
        #expect(owner.released == 1)
    }

    @Test func aReturnToTheForegroundCancelsTheGraceAndKeepsTheStream() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        owner.holdsGrace = true
        let run = leave(engine, owner)
        try await until("the grace to start") { owner.started == 1 }
        owner.wantsTransport = true
        engine.foregroundRequested()
        let outcome = await run.value
        #expect(outcome.grace == .foreground && outcome.quiesce == nil && owner.released == 0)
        #expect(engine.client != nil && engine.hasTransportOwnership)
        #expect(engine.quiescing, "refused until the foreground task lets work in")
        #expect(engine.resumeForeground(), "the stream was kept")
        #expect(!engine.quiescing && engine.backgroundPhase == .foreground)
        #expect(owner.notices == [false])
    }

    @Test func aMessageQueuedDuringTheGraceGetsAPassWhileTheTransportIsUnwanted() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        let store = try withStore(engine)
        engine.isReady = true
        owner.holdsGrace = true
        try await queue("queued before leaving", store: store)
        let run = leave(engine, owner)
        try await until("the grace to start") { owner.started == 1 }
        try await until("the grace's first pass to end") { engine.drainPasses == 1 }
        try await queue("queued during the grace", store: store)
        engine.startOutbox()
        #expect(owner.passes == 2 && engine.drainTask != nil, "the outbox runs in the grace")
        try await until("the second pass to end") { engine.drainPasses == 2 }
        owner.holdsGrace = false
        engine.graceWorkChanged()
        let outcome = await run.value
        #expect(outcome.grace == .idle)
        // The pass could not send without an identity: the message is still queued, so the notice goes up.
        #expect(outcome.unsent && owner.notices == [true])
        engine.startOutbox()
        #expect(owner.passes == 2, "no pass once quiesced")
    }

    @Test func nothingReacquiresTheLeaseBeforeTheForeground() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        let store = try withStore(engine)
        _ = await leave(engine, owner, grace: false).value
        owner.wantsTransport = true
        await #expect(throws: CancellationError.self) { try await engine.acquireOwnership(store, token: engine.generation) }
        #expect(await !store.holdsTransportOwnership)
        engine.resumeForeground()
        try await engine.acquireOwnership(store, token: engine.generation)
        #expect(await store.holdsTransportOwnership)
        await engine.releaseLease(store)
    }

    @Test func anUnsentMessageRaisesTheNoticeAndTheForegroundWithdrawsIt() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        let store = try withStore(engine)
        try await queue("left behind", store: store)
        let outcome = await leave(engine, owner, grace: false).value
        #expect(outcome.grace == nil && outcome.unsent)
        #expect(owner.notices == [true])
        engine.resumeForeground()
        #expect(owner.notices == [true, false])
    }

    @Test func messagesInAChatHeldForTrustRaiseNoNotice() async throws {
        let owner = Owner(), clock = TestClock()
        let engine = try engine(owner, clock: clock)
        let store = try withStore(engine)
        try await queue("waits for a decision", store: store)
        engine.heldChats = ["bob@localhost"]
        let outcome = await leave(engine, owner).value
        #expect(outcome.grace == .idle && !outcome.unsent && owner.notices.isEmpty)
    }
}
