import Foundation
import MessageStore
import OMEMO
import XMPPProtocol
@testable import MessagingCore

// Drives one account through the production `SessionEngine`, in the order the app's connect calls it, and notes when
// and after how many round trips the connection reached each point. Nothing here stands in for engine behaviour: the
// delegate only records, and tracks joined rooms as the app's group presence does.
@MainActor final class SyncBenchSession: SessionEngineDelegate {
    let engine: SessionEngine
    let bench: SyncBenchStore
    let account: SyncBenchFixture.Account
    private let proxy: SyncBenchProxy
    private let environment: SyncBenchEnvironment
    private let defaults: UserDefaults
    private let suite = "haus.syncbench.\(UUID().uuidString)"
    private let expectedRooms: Int
    var wantsTransport = true
    var mayDrainOutbox = true
    private(set) var joined: Set<String> = []
    private var uploadsKnown = false
    private(set) var failure: String?
    private var marks: [String: (at: ContinuousClock.Instant, counts: SyncBenchProxy.Counts)] = [:]
    private var started = (at: SyncBenchClock.now(), counts: SyncBenchProxy.Counts(), cpu: 0)
    private var signal: AsyncStream<Void>.Continuation?

    init(account: SyncBenchFixture.Account, bench: SyncBenchStore, proxy: SyncBenchProxy, environment: SyncBenchEnvironment,
         expectedRooms: Int) throws {
        guard let defaults = UserDefaults(suiteName: suite) else { throw SyncBenchFailure.configuration("no defaults suite") }
        self.account = account; self.bench = bench; self.proxy = proxy; self.environment = environment
        self.defaults = defaults; self.expectedRooms = expectedRooms
        engine = SessionEngine(profiles: ServerProfileMemory(defaults: defaults))
        engine.account = account.jid
        engine.store = bench.store
        engine.encryption = bench.encryption
        engine.outboxSender = OutboxSender(store: bench.store)
        engine.delegate = self
        // What iOS grants a backgrounded app, so the grace and the quiesce deadline are the app's.
        engine.backgroundTimeRemaining = { .seconds(30) }
    }

    // The App Group's profiles in the app: an extension run for this account connects with them.
    var streamProfiles: StreamProfileMemory { engine.profiles.streams }
    var joinedRooms: Set<String> { joined }
    func uploadsFresh(account: String) -> Bool { uploadsKnown }

    // The app's connect sequence without its interface steps: hand over, attach, join, consume, open.
    func connect() async throws {
        wantsTransport = true
        engine.resumeForeground()
        marks = [:]
        joined = []
        failure = nil
        started = (SyncBenchClock.now(), proxy.counts, SyncBenchClock.cpuMilliseconds())
        let handover = engine.beginConnection()
        let token = engine.generation
        let connection = engine.attach(XMPPClient(labCertificateAuthority: environment.authority))
        await engine.finish(handover)
        engine.startEvents(connection, token: token)
        let resource = environment.fixture.resource
        let login = SessionEngine.Login(account: account.jid, route: .fixed(XMPPEndpoint(host: "127.0.0.1", port: proxy.port, security: .directTLS)),
                                        domain: account.domain, username: account.localpart, password: account.password, pin: .none,
                                        sasl2: try environment.sasl2(account, carbons: true), resource: { resource }, presence: { (.active, true) })
        _ = try await engine.open(connection, token: token, login: login)
    }

    // Transport work stopped and joined, then the lease given back, as a quiesce does.
    func stop() async {
        await engine.stopTransportWork()
        await engine.releaseLease(bench.store)
        // A quiesce outside a background transition: its owner lets new work in again once the lease is back.
        engine.quiescing = false
    }

    func finish() { defaults.removePersistentDomain(forName: suite) }

    var counts: SyncBenchProxy.Counts { proxy.counts }
    var port: UInt16 { proxy.port }

    func reached(_ point: String) -> Bool { marks[point] != nil }

    // Settled, every expected room joined and no outbox pass running or asked for.
    var caughtUp: Bool { reached("settled") && joined.count >= expectedRooms && (engine.outboxIdle || !mayDrainOutbox) }

    func mark(_ point: String) {
        if marks[point] == nil { marks[point] = (SyncBenchClock.now(), proxy.counts) }
        signal?.yield()
    }

    // Checks `condition` at every engine callback and at least every 50 ms, for at most `limit`.
    func wait(_ what: String, limit: Duration = .seconds(60), until condition: () async -> Bool) async throws {
        let deadline = SyncBenchClock.now() + limit
        while !(await condition()) {
            if let failure { throw SyncBenchFailure.configuration("setup failed at \(failure) while waiting for \(what)") }
            guard SyncBenchClock.now() < deadline else { throw SyncBenchFailure.timedOut(what) }
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            signal = continuation
            let tick = Task {
                await SyncBenchClock.pause(.milliseconds(50))
                continuation.yield()
            }
            for await _ in stream { break }
            tick.cancel()
            signal = nil
        }
    }

    func result(_ scenario: String) -> SyncBenchResult {
        var result = SyncBenchResult(scenario: scenario)
        for (point, mark) in marks {
            result.wallMs[point] = SyncBenchClock.milliseconds(started.at, mark.at)
            result.roundTrips[point] = (mark.counts - started.counts).roundTrips
        }
        result.wallMs["total"] = SyncBenchClock.milliseconds(started.at, SyncBenchClock.now())
        result.totals = proxy.counts - started.counts
        result.roundTrips["total"] = result.totals.roundTrips
        result.cpuMs = SyncBenchClock.cpuMilliseconds() - started.cpu
        result.phasesMs = Dictionary(uniqueKeysWithValues: engine.timings.milliseconds.map { ($0.key.rawValue, $0.value) })
        result.values["resumed"] = marks["online"] == nil ? 0 : (resumed ? 1 : 0)
        result.values["roomsJoined"] = joined.count
        result.values["catchUpMessages"] = engine.catchUpByArchive.values.reduce(0) { $0 + $1.messages }
        return result
    }

    private var resumed = false

    func connectionChanged(_ state: XMPPConnectionState) {
        if case .online = state { mark("online") } else { signal?.yield() }
    }

    func streamOnline(client: XMPPClient?, resumed: Bool) { self.resumed = resumed }
    func setupReady() { mark("ready") }
    func setupSettled() { mark("settled") }
    func graceStarted() { mark("graceStarted") }
    func setupFailed(step: String, detail: String) { failure = "\(step): \(detail)"; signal?.yield() }
    func catchUpChanged(_ progress: CatchUpProgress?) { if progress == nil { mark("caughtUp") } }
    func outboxPassEnded(_ result: Result<Set<String>, any Error>, token: UUID) { signal?.yield() }
    func outboxIdle(token: UUID) { signal?.yield() }

    // The first pass of a connection is the first moment a queued message can go out.
    func outboxHooks(token: UUID) -> OutboxDrain.Hooks {
        mark("outbox")
        return OutboxDrain.Hooks()
    }

    func uploadsDiscovered(_ discovery: Result<XMPPUploadService?, any Error>, account: String, token: UUID) {
        if case .success = discovery { uploadsKnown = true }
    }

    // As the app's group state: a rejoin pass reports a room a resume restored and a self-ping confirmed.
    func roomRejoined(_ room: String, joined: Bool) {
        if joined { roomJoined(room) }
    }

    private func roomJoined(_ room: String) {
        joined.insert(room)
        if joined.count == expectedRooms { mark("roomsJoined") }
        engine.startOutbox()
    }

    func received(_ event: XMPPEvent, token: UUID) async {
        switch event {
        case .groupPresence(let room):
            // Only the room's own presence for us makes it joined; a failed read leaves it as it was.
            guard let client = engine.client, (try? await client.groupRoomSnapshot(room))??.joined == true else { break }
            roomJoined(room)
        case .streamAcknowledged:
            mark("acknowledged")
        default:
            break
        }
        signal?.yield()
    }

    // How many of `ids` the server has accepted, and how many left the queue at all.
    func outcome(of ids: [String]) async -> (accepted: Int, written: Int) {
        var accepted = 0, written = 0
        for id in ids {
            // An unreadable row counts as neither.
            guard let state = (try? await bench.store.message(accountID: account.jid, messageID: id))??.transportState else { continue }
            if state == .serverAccepted { accepted += 1 }
            if state != .queued { written += 1 }
        }
        return (accepted, written)
    }
}
