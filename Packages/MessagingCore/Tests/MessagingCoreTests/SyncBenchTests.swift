import Foundation
import MessageStore
import Testing
import XMPPProtocol
@testable import MessagingCore

// The connection pipeline's fixed cost against the local lab through a delaying relay, one JSON result per scenario in
// the work directory's results/. Each scenario starts from a copy of a provisioned snapshot, so every run walks the
// same archives from the same ratchet state. Runs only with HAUS_SYNC_BENCH; see `SyncBenchEnvironment`.
@Suite(.serialized, .enabled(if: SyncBenchEnvironment.enabled))
@MainActor struct SyncBenchTests {
    private func run(_ snapshot: String?, account: (SyncBenchFixture) -> SyncBenchFixture.Account, rooms: Int,
                     _ body: (SyncBenchSession, SyncBenchEnvironment) async throws -> Void) async throws {
        let environment = try SyncBenchEnvironment()
        let proxy = try await SyncBenchProxy.start(oneWayMilliseconds: environment.oneWayMilliseconds, target: 5223)
        defer { proxy.stop() }
        let bench = try snapshot.map { try SyncBenchStore.restore(environment.snapshot($0)) } ?? SyncBenchStore.open(environment.senderStore)
        let session = try SyncBenchSession(account: account(environment.fixture), bench: bench, proxy: proxy, environment: environment,
                                           expectedRooms: rooms)
        do { try await body(session, environment) } catch {
            await session.stop()
            throw error
        }
        await session.stop()
        session.finish()
        try await bench.close(removing: snapshot != nil)
    }

    // Connects and waits until setup settled, the rooms are joined and the outbox is idle.
    private func connectAndSettle(_ session: SyncBenchSession, _ what: String) async throws {
        try await session.connect()
        try await session.wait("\(what) to settle") { session.caughtUp }
    }

    // A fresh bind with nothing new in the archives, one contact and two rooms; then the same account
    // resumed.
    @Test func freshThenResumedFloor() async throws {
        try await run("base", account: \.app, rooms: 2) { session, environment in
            try await connectAndSettle(session, "the fresh bind")
            var fresh = session.result("fresh")
            fresh.passed = fresh.values["resumed"] == 0
            try fresh.write(to: environment.results)
            await session.stop()
            try await connectAndSettle(session, "the resume")
            var resumed = session.result("resume")
            resumed.passed = resumed.values["resumed"] == 1
            try resumed.write(to: environment.results)
            #expect(fresh.values["resumed"] == 0)
            #expect(resumed.values["resumed"] == 1)
        }
    }

    // The seeded encrypted direct messages wait in the archive. The outbox is held: the receipts it would send land in
    // the measured archive and every later run would walk them.
    @Test(.enabled(if: SyncBenchEnvironment.full)) func catchUp() async throws {
        try await run("catchup", account: \.app, rooms: 2) { session, environment in
            session.mayDrainOutbox = false
            try await connectAndSettle(session, "the catch-up")
            var result = session.result("catchup")
            let messages = result.values["catchUpMessages"] ?? 0
            let walk = (result.wallMs["caughtUp"] ?? 0) - (result.wallMs["online"] ?? 0)
            result.values["entriesPerSecond"] = walk > 0 ? messages * 1000 / walk : 0
            result.passed = messages >= SyncBenchFixture.catchUpMessages
            try result.write(to: environment.results)
            #expect(messages >= SyncBenchFixture.catchUpMessages)
        }
    }

    // Five joined rooms, fresh and then resumed.
    @Test(.enabled(if: SyncBenchEnvironment.full)) func rooms() async throws {
        try await run("rooms", account: \.app, rooms: 5) { session, environment in
            try await connectAndSettle(session, "the rooms' fresh bind")
            try session.result("rooms-fresh").write(to: environment.results)
            await session.stop()
            try await connectAndSettle(session, "the rooms' resume")
            try session.result("rooms-resume").write(to: environment.results)
            #expect(session.joined.count == 5)
        }
    }

    // On the sender's own store: enqueue to acknowledged on a ready session, then the background grace through the
    // engine's entry points: a return during it, messages enqueued before and during it, and an idle session leaving.
    // Each quiesce ends the stream, so the next scenario resumes it.
    @Test func sendThenBackground() async throws {
        try await run(nil, account: \.sender, rooms: 0) { session, environment in
            let peer = environment.fixture.peer.jid
            try await connectAndSettle(session, "the sender")
            try await session.wait("the previous run's queue") {
                (try? await session.bench.store.queuedOutgoing(accountID: session.account.jid))?.isEmpty ?? false
            }
            for count in [1, 5] {
                try await sendLatency(count, to: peer, session: session).write(to: environment.results)
            }
            try await returnDuringGrace(to: peer, session: session).write(to: environment.results)
            try await backgroundSend(to: peer, session: session).write(to: environment.results)
            try await connectAndSettle(session, "the resume after the background send")
            try await backgroundSend(to: peer, session: session, enqueuedDuringGrace: true).write(to: environment.results)
            try await connectAndSettle(session, "the resume after the grace enqueue")
            try await idleBackground(session).write(to: environment.results)
        }
    }

    private func sendLatency(_ count: Int, to peer: String, session: SyncBenchSession) async throws -> SyncBenchResult {
        let before = session.result("before")
        let ids = try await enqueue(count, "syncbench", to: peer, session: session)
        try await session.wait("\(count) acknowledged") { await session.outcome(of: ids).accepted == count }
        var result = session.result("send-\(count)")
        result.subtract(before)
        result.passed = true
        return result
    }

    private func enqueue(_ count: Int, _ label: String, to peer: String, session: SyncBenchSession) async throws -> [String] {
        var ids: [String] = []
        for index in 0..<count {
            let message = try await OutgoingEnqueue.text("\(label) \(index + 1) of \(count)", account: session.account.jid, chatID: peer,
                                                         store: session.bench.store)
            ids.append(message.id)
            session.engine.startOutbox()
        }
        return ids
    }

    // The app's background request: the transport is unwanted at once, and the grace holds the stream for the outbox.
    private func leave(_ session: SyncBenchSession) -> Task<BackgroundOutcome, Never> {
        session.wantsTransport = false
        session.engine.backgroundRequested(grace: true)
        return Task { await session.engine.enterBackground() }
    }

    // Passes only if the server acknowledged every message before the transport quiesced; `graceMs` is
    // the time from the background request to all acknowledged.
    private func backgroundSend(to peer: String, session: SyncBenchSession, enqueuedDuringGrace: Bool = false) async throws -> SyncBenchResult {
        let before = session.result("before")
        var ids = try await enqueue(3, "syncbench leaving", to: peer, session: session)
        let leaving = leave(session)
        if enqueuedDuringGrace {
            try await session.wait("the grace to start") { session.reached("graceStarted") }
            ids += try await enqueue(1, "syncbench during the grace", to: peer, session: session)
        }
        let outcome = await leaving.value
        let sent = await session.outcome(of: ids)
        var result = session.result(enqueuedDuringGrace ? "background-enqueue" : "background-send")
        result.subtract(before)
        result.values["sent"] = sent.accepted
        result.values["written"] = sent.written
        result.values["graceMs"] = Int(outcome.graceDuration / .milliseconds(1))
        result.values["graceIdle"] = outcome.grace == .idle ? 1 : 0
        result.values["released"] = outcome.quiesce?.released == true ? 1 : 0
        result.passed = sent.accepted == ids.count && outcome.grace == .idle && outcome.quiesce?.released == true
        return result
    }

    // Back during the grace. The stream stays, so ready takes no round trip, and the messages still go out.
    private func returnDuringGrace(to peer: String, session: SyncBenchSession) async throws -> SyncBenchResult {
        let before = session.result("before")
        let ids = try await enqueue(3, "syncbench back", to: peer, session: session)
        let leaving = leave(session)
        try await session.wait("the grace to start") { session.reached("graceStarted") }
        let atReturn = session.counts
        session.wantsTransport = true
        session.engine.foregroundRequested()
        let outcome = await leaving.value
        let kept = session.engine.resumeForeground()
        let toReady = (session.counts - atReturn).roundTrips
        try await session.wait("3 acknowledged after the return") { await session.outcome(of: ids).accepted == ids.count }
        var result = session.result("background-return")
        result.subtract(before)
        result.roundTrips["ready"] = session.engine.isReady ? toReady : -1
        result.values["kept"] = kept ? 1 : 0
        result.values["sent"] = ids.count
        result.passed = kept && session.engine.isReady && outcome.grace == .foreground && outcome.quiesce == nil && toReady == 0
        return result
    }

    // Nothing pending, so no grace is held and the quiesce starts at once.
    private func idleBackground(_ session: SyncBenchSession) async -> SyncBenchResult {
        let before = session.result("before")
        let outcome = await leave(session).value
        var result = session.result("background-idle")
        result.subtract(before)
        result.values["graceMs"] = Int(outcome.graceDuration / .milliseconds(1))
        result.values["graceHeld"] = session.reached("graceStarted") ? 1 : 0
        result.passed = outcome.grace == .idle && !session.reached("graceStarted") && outcome.quiesce?.released == true
        return result
    }
}

extension SyncBenchResult {
    // What happened since `before`, on the same connection.
    mutating func subtract(_ before: SyncBenchResult) {
        let total = wallMs["total"] ?? 0, earlier = before.wallMs["total"] ?? 0
        wallMs = ["total": total - earlier]
        totals = totals - before.totals
        roundTrips = ["total": totals.roundTrips]
        cpuMs -= before.cpuMs
        phasesMs = [:]
        values = [:]
    }
}
