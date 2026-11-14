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

    // On the sender's own store: enqueue to acknowledged on a ready session, then three messages enqueued
    // right before the transport goes to the background.
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
            let background = try await backgroundSend(to: peer, session: session)
            try background.write(to: environment.results)
        }
    }

    private func sendLatency(_ count: Int, to peer: String, session: SyncBenchSession) async throws -> SyncBenchResult {
        let before = session.result("before")
        var ids: [String] = []
        for index in 0..<count {
            let message = try await OutgoingEnqueue.text("syncbench \(index + 1) of \(count)", account: session.account.jid, chatID: peer,
                                                         store: session.bench.store)
            ids.append(message.id)
            session.engine.startOutbox()
        }
        try await session.wait("\(count) acknowledged") { await session.outcome(of: ids).accepted == count }
        var result = session.result("send-\(count)")
        result.subtract(before)
        result.passed = true
        return result
    }

    private func backgroundSend(to peer: String, session: SyncBenchSession) async throws -> SyncBenchResult {
        let before = session.result("before")
        var ids: [String] = []
        for index in 0..<3 {
            let message = try await OutgoingEnqueue.text("syncbench leaving \(index + 1)", account: session.account.jid, chatID: peer,
                                                         store: session.bench.store)
            ids.append(message.id)
            session.engine.startOutbox()
        }
        session.wantsTransport = false
        session.engine.backgroundRequested()
        await session.engine.enterBackground()
        let outcome = await session.outcome(of: ids)
        var result = session.result("background-send")
        result.subtract(before)
        result.values["sent"] = outcome.accepted
        result.values["written"] = outcome.written
        result.passed = outcome.accepted == ids.count
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
