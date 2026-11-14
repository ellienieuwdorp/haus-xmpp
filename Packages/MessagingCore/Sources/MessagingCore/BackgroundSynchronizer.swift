import Foundation
import os
import MessageStore
import OMEMO
import XMPPProtocol

/// Loaded from protected local account storage, never from an untrusted push payload.
public struct BackgroundAccount: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Discovery runs only if this route fails and allows it.
    public let route: XMPPRoute
    public let domain: String
    public let username: String
    public let password: String
    /// PLAIN is refused once the account has authenticated with SCRAM.
    public let requiresSCRAM: Bool
    public let labCertificateAuthority: Data?
    /// Nil keeps a random one for this run.
    public let resource: String?
    /// Re-enabled on a fresh session; nil when push is not settled.
    public let push: XMPPPushConfiguration?
    /// Announced as XEP-0319 idle when the account shares last seen.
    public let leftForeground: Date?
    /// The app's shared `StreamProfileMemory`: the connection sends ahead with what the server last offered, and
    /// learns or refuses for every process. Nil connects in the plain order.
    public let streamProfiles: (any XMPPStreamProfileStore)?
    public var accountID: String { username + "@" + domain }

    public init(route: XMPPRoute, domain: String, username: String, password: String, requiresSCRAM: Bool = false,
                labCertificateAuthority: Data? = nil, resource: String? = nil,
                push: XMPPPushConfiguration? = nil, leftForeground: Date? = nil, streamProfiles: (any XMPPStreamProfileStore)? = nil) {
        self.route = route; self.domain = domain
        self.username = username; self.password = password; self.requiresSCRAM = requiresSCRAM
        self.labCertificateAuthority = labCertificateAuthority
        self.resource = resource; self.push = push; self.leftForeground = leftForeground; self.streamProfiles = streamProfiles
    }
    public var description: String { "BackgroundAccount(<redacted>)" }
    public var debugDescription: String { description }
}

public enum BackgroundSynchronizationError: Error, Sendable, Equatable {
    case identityUnavailable, deadlineExceeded, invalidTimeBudget, connectionEnded
    /// The own archive query was refused or unanswered, so the run cannot claim catch-up.
    case ownArchiveIncomplete
    /// The app answered the liveness handshake, or took over the lease this run gave way to, and presents the push itself.
    case handedOff
    /// This run gave the lease way to the app, which did not confirm it took over in time.
    case takeoverUnconfirmed
}

/// One bounded catch-up under the same kernel lease as the app. Success means durable archive completion, not that a
/// particular notification represents a new message.
public struct BackgroundSynchronizer: Sendable {
    public init() {}

    /// The network work's share of the coordinator's `runLimit`: the farewell, the final presentation and closing the
    /// store follow it.
    public static let timeBudget: Duration = .seconds(17)
    public static let maximumTimeBudget: Duration = .seconds(20)

    /// Runs under the lease.
    public typealias Presentation = @Sendable (MessageStore, PresentationStage) async throws -> Void

    /// `leaseWait` is spent inside `timeBudget`. With `liveness`, a busy lease first asks a running app; an answer in
    /// time throws `handedOff`. `presentation` runs as `.direct` once the own archive committed, and once at the end. With `giveWay`, an app's request stops the run before its final presentation: it closes the
    /// store and throws `handedOff` once the app confirms its takeover, `takeoverUnconfirmed` otherwise. Cancelling the
    /// run closes its socket at once; it returns once the store is closed.
    public func synchronize(databaseURL: URL, wrappingKey: Data, account: BackgroundAccount,
                            timeBudget: Duration = Self.timeBudget, leaseWait: Duration = .seconds(6),
                            liveness: (any LivenessChannel)? = nil, giveWay: GiveWaySwitch? = nil,
                            progress: NotificationRunProgress? = nil,
                            presentation: Presentation? = nil) async throws {
        guard timeBudget > .zero, timeBudget <= Self.maximumTimeBudget, leaseWait >= .zero, leaseWait < timeBudget else {
            throw BackgroundSynchronizationError.invalidTimeBudget
        }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw BackgroundSynchronizationError.identityUnavailable
        }
        // Never migrates: an older store waits, untouched, for the app to snapshot and upgrade it.
        let store = try MessageStore(url: databaseURL, schema: .currentOnly)
        do {
            // Busy means a bounded wait, then defer: never expire another process's lock or reset its attempts.
            progress?.enter(.leaseWait)
            let clock = ContinuousClock(), waitStarted = clock.now
            let waited: Duration
            do { waited = try await acquireTransportOwnership(store, waitingUpTo: leaseWait, liveness: liveness, giveWay: giveWay) }
            catch BackgroundSynchronizationError.handedOff {
                progress?.update { $0.leaseWaitMilliseconds = Int((clock.now - waitStarted) / .milliseconds(1)) }
                throw BackgroundSynchronizationError.handedOff
            }
            progress?.update { $0.leaseWaitMilliseconds = Int(waited / .milliseconds(1)) }
            progress?.enter(.syncing)
            guard try await store.encryptionState(accountID: account.accountID) != nil else {
                throw BackgroundSynchronizationError.identityUnavailable
            }
            let encryption = OMEMOService(store: store, protection: try StateProtection(key: wrappingKey))
            let client = try await account.client(store: store, encryption: encryption)
            try await store.recoverInterruptedSubmissions(accountID: account.accountID)
            // Taken before the timer starts, so never later than the real deadline.
            let deadline = ContinuousClock.now + timeBudget - waited
            try await BackgroundCatchUp(
                connect: {
                    try await client.connect(route: account.route, domain: account.domain, username: account.username,
                                             password: account.password, requireSCRAM: account.requiresSCRAM)
                    progress?.noteOnline(resumed: await client.sessionResumed)
                },
                sessionDuties: { ownArchiveWalked in
                    // A fresh bind replaced the session the server pushed for, so re-enable push and rejoin rooms.
                    let fresh = await !client.sessionResumed
                    BackgroundSession.log.notice("background session resumed=\(!fresh, privacy: .public)")
                    async let pushEnabled: Void = fresh ? BackgroundSession.enablePush(account.push, client: client) : ()
                    // Rejoins wait for the own archive, so they cannot use up the direct messages' time. Never fail the run.
                    @Sendable func rejoin() async -> Set<String> {
                        while await !ownArchiveWalked.reached {
                            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return [] }
                        }
                        return await BackgroundSession.joinRooms(account: account.accountID, client: client, encryption: encryption,
                                                                 store: store, within: readSyncTimeout(until: deadline, now: .now))
                    }
                    async let joined = fresh ? rejoin() : []
                    _ = await (pushEnabled, joined)
                },
                // No identity initialization, trust acceptance, queued-message preparation or outbox drain. Resumption
                // may replay only previously authorized exact bytes.
                walk: { walkProgress, ownArchiveWalked in
                    try await ArchiveSynchronizer(store: store).synchronize(account: account.accountID, client: client, encryption: encryption,
                                                                            progress: walkProgress, ownArchiveWalked: ownArchiveWalked)
                },
                pull: { timeout in
                    let apply = try await ReadSync(store: store).fetched(account: account.accountID, encryption: encryption) {
                        try await client.fetchDisplayedSync(timeout: timeout)
                    }
                    return { _ = try await apply() }
                },
                consume: {
                    try await consumeBackgroundEvents(client.events, processor: InboundProcessor(encryption: encryption, client: client, account: account.accountID))
                },
                stop: { await stopTransport(client) }, giveWay: giveWay ?? GiveWaySwitch()
            ).run(store: store, deadline: deadline, clock: ContinuousClock(), progress: progress, presentation: presentation)
        } catch {
            // runBackgroundWork has joined crypto, archive and reader work. close releases ownership only if this
            // instance acquired it.
            try await store.close()
            try await Self.rethrow(error, givingWay: giveWay)
        }
    }

    // The candidates a run that gave way stored stay for the app's claim; the push is the app's only once it holds the
    // lease.
    private static func rethrow(_ error: any Error, givingWay giveWay: GiveWaySwitch?) async throws -> Never {
        guard let stop = error as? GiveWayStop, let giveWay else { throw error }
        let confirmed = try await giveWay.takeover(of: stop.request, clock: ContinuousClock())
        BackgroundSession.log.notice("gave way to the app, takeover confirmed=\(confirmed, privacy: .public)")
        throw confirmed ? BackgroundSynchronizationError.handedOff : BackgroundSynchronizationError.takeoverUnconfirmed
    }
}

// After the own archive commits, the deadline only ends best-effort work, so a slow room cannot turn committed direct
// messages into the fallback. After an early post the user may open the app, which waits for this lease, so rooms get
// only `roomsAfterPost` more.
struct BackgroundCatchUp: Sendable {
    let connect: @Sendable () async throws -> Void
    let sessionDuties: @Sendable (_ ownArchiveWalked: CatchUpMark) async -> Void
    let walk: @Sendable (_ progress: @escaping @Sendable (ArchiveSyncProgress) async -> Void,
                         _ ownArchiveWalked: @escaping @Sendable (_ complete: Bool, _ rooms: Int) async throws -> Void) async throws -> Void
    // Fetches the read state within the timeout; what it returns applies it.
    let pull: @Sendable (Duration) async throws -> ReadStatePrefetch.Apply
    let consume: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void
    var roomsAfterPost: Duration = .seconds(5)
    var giveWay = GiveWaySwitch()

    // The budget's timer ends at `deadline`.
    func run<C: Clock<Duration>>(store: MessageStore, deadline: C.Instant, clock: C, progress: NotificationRunProgress?,
                                 presentation: BackgroundSynchronizer.Presentation?) async throws {
        let caughtUp = CatchUpMark(), ownArchiveWalked = CatchUpMark(), ledger = CatchUpLedger(), early = ReadStatePrefetch()
        // A slow or lost server leaves the run a success. The first pull takes the fetch made beside the own archive's
        // walk; a later one fetches again.
        @Sendable func pullReadState() async throws {
            if let apply = try await early.take() { try await apply() }
            else if let timeout = readSyncTimeout(until: deadline, now: clock.now) { try await pull(timeout)() }
            await ledger.notePull()
        }
        let giveWay = giveWay
        @Sendable func walkArchives() async throws {
            try await walk({ if $0.archive != nil, $0.messages > 0 { await ledger.noteRoomMessages() } }, { complete, _ in
                await ownArchiveWalked.reach()
                // The own archive holds the direct messages a push is about; without it the run shows the fallback.
                guard complete else { throw BackgroundSynchronizationError.ownArchiveIncomplete }
                progress?.noteOwnArchiveCommitted()
                await caughtUp.reach()
                // Before the claim, so chats read on another device lose their candidates. Also without rooms: the
                // final presentation waits for the farewell's round trip.
                try await pullReadState()
                guard let presentation else { return }
                // A stop waits for a presentation that is posting, so nothing is posted twice.
                do { try await giveWay.shielded { try await presentation(store, .direct) } }
                catch is CancellationError { throw CancellationError() }
                // The final presentation retries everything still pending.
                catch { BackgroundSession.log.notice("direct presentation failed: \(String(describing: type(of: error)), privacy: .public)") }
                // A presentation that failed part-way still counts as showing.
                if (progress?.report.posted ?? 0) > 0 { await ledger.notePostedEarly() }
            })
        }
        try await runBackgroundWork(timeBudget: clock.now.duration(to: deadline), clock: clock, caughtUp: caughtUp, giveWay: giveWay, operation: {
            try await connect()
            try Task.checkCancellation()
            await early.start()
            async let prefetched: Void = early.fetch {
                guard let timeout = readSyncTimeout(until: deadline, now: clock.now) else { return nil }
                return try await pull(timeout)
            }
            async let duties: Void = sessionDuties(ownArchiveWalked)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await walkArchives() }
                    group.addTask {
                        try await ledger.untilPostedEarly()
                        try await clock.sleep(for: roomsAfterPost)
                        throw BackgroundSynchronizationError.deadlineExceeded
                    }
                    try await group.next()
                    group.cancelAll()
                }
                await ledger.noteRoomsWalked()
            } catch {
                // Rooms are best effort once the own archive committed; a storage failure or cancellation still ends the run.
                guard await caughtUp.reached, !(error is CancellationError), !(error is MessageStoreError) else { throw error }
                BackgroundSession.log.notice("room walk ended early: \(String(describing: type(of: error)), privacy: .public)")
                await ledger.noteRoomWalkFailed(error)
            }
            if await ledger.needsPull { try await pullReadState() }
            await prefetched
            await duties
        }, consume: {
            try await consumeUntilDisconnect(after: caughtUp) { try await consume() }
        }, stop: stop)
        try Task.checkCancellation()
        giveWay.close()
        // From here a new push starts the next run.
        progress?.enter(.presenting)
        let stage = await ledger.finalStage(pastDeadline: clock.now >= deadline)
        var final: (@Sendable (MessageStore) async throws -> Void)?
        if let presentation { final = { try await presentation($0, stage) } }
        try await finishBackgroundPresentation(store: store, presentation: final)
    }
}

actor CatchUpLedger {
    private(set) var postedEarly = false
    private var roomsWalked = false, pulled = false, roomMessages = false
    private var roomError: (any Error)?
    private var earlyPostWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func notePostedEarly() {
        postedEarly = true
        earlyPostWaiters.values.forEach { $0.resume() }
        earlyPostWaiters = [:]
    }
    // Throws CancellationError when cancelled first.
    func untilPostedEarly() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                if postedEarly { waiter.resume() }
                else if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                else { earlyPostWaiters[id] = waiter }
            }
        } onCancel: { Task { await self.stopWaiting(id) } }
    }
    private func stopWaiting(_ id: UUID) { earlyPostWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func noteRoomsWalked() { roomsWalked = true }
    func noteRoomWalkFailed(_ error: any Error) { roomError = error }
    func notePull() { pulled = true }
    func noteRoomMessages() { roomMessages = true }
    var needsPull: Bool { !pulled || roomMessages }
    // No room error means the stream ended first.
    func finalStage(pastDeadline: Bool) -> PresentationStage {
        guard !roomsWalked else { return .complete }
        if pastDeadline { return PresentationStage(isFinal: true, unfinished: BackgroundSynchronizationError.deadlineExceeded) }
        guard let roomError, !(roomError is XMPPClientError) else {
            return PresentationStage(isFinal: true, unfinished: BackgroundSynchronizationError.connectionEnded)
        }
        return PresentationStage(isFinal: true, unfinished: roomError)
    }
}

extension BackgroundAccount {
    // Stream management on the account's store, the app's resource and stream profile; away, so the session never
    // makes the user look online.
    func client(store: MessageStore, encryption: OMEMOService) async throws -> XMPPClient {
        let client = XMPPClient(labCertificateAuthority: labCertificateAuthority)
        try await client.configureStreamManagement(persistence: StreamPersistence(store: store, accountID: accountID, encryption: encryption))
        if let resource { try await client.configureResource(resource) }
        if let streamProfiles { try await client.configureStreamProfiles(streamProfiles) }
        let preferences = try await store.accountPreferences(accountID: accountID)
        try await client.setAvailability(BackgroundSession.availability(sharesLastSeen: preferences.lastSeen, leftForeground: leftForeground),
                                         clientActive: false)
        return client
    }
}

extension NotificationRunProgress {
    func noteOnline(resumed: Bool) {
        update { $0.onlineMilliseconds = Int(Date().timeIntervalSince(started) * 1000); $0.resumed = resumed }
    }

    func noteOwnArchiveCommitted() { update { $0.ownArchiveMilliseconds = Int(Date().timeIntervalSince(started) * 1000) } }
}

/// A fresh bind away from the foreground replaced the app's session, which had push enabled and sat in the rooms.
public enum BackgroundSession {
    static let concurrentJoins = 8

    /// Stable across runs: a changed value is announced to every contact, so a moving one would make every resumed
    /// run broadcast presence.
    public static func availability(sharesLastSeen: Bool, leftForeground: Date?, now: Date = Date()) -> XMPPAvailability {
        .away(since: sharesLastSeen ? leftForeground.map { min($0, now) } : nil)
    }

    /// XEP-0357 enable only; gateway registration stays the app's job. A failure is left for the next app connection.
    public static func enablePush(_ push: XMPPPushConfiguration?, client: XMPPClient) async {
        guard let push else { return }
        do { try await client.enablePush(push) }
        catch { log.notice("push re-enable failed: \(String(describing: type(of: error)), privacy: .public)") }
    }

    /// Joins with `<history maxstanzas='0'/>` (the archive walk covers history) so room traffic is routed and pushed to
    /// this session. A room not confirmed by the deadline is left to the next app connection. Returns those confirmed.
    @discardableResult
    public static func joinRooms(account: String, client: XMPPClient, encryption: OMEMOService, store: MessageStore,
                                 skipping: Set<String> = [], within limit: Duration?) async -> Set<String> {
        guard let limit, let known = try? await encryption.knownGroupRooms(account: account).keys.sorted() else { return [] }
        let rooms = known.filter { !skipping.contains($0) }
        guard !rooms.isEmpty else { return [] }
        let fallback = String(account.prefix { $0 != "@" })
        var nicknames: [String: String] = [:]
        for room in rooms { nicknames[room] = (try? await store.groupNickname(accountID: account, room: room)) ?? fallback }
        // Each child returns its room when joined, "" when it failed, and nil for the deadline.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await Task.sleep(for: limit); return nil }
            var pending = rooms[...], joined: Set<String> = [], running = 0
            func start(_ group: inout TaskGroup<String?>) {
                while running < concurrentJoins, let room = pending.popFirst(), let nickname = nicknames[room] {
                    running += 1
                    group.addTask { await join(room, nickname: nickname, client: client, within: limit) ? room : "" }
                }
            }
            start(&group)
            while running > 0, let result = await group.next() {
                guard let room = result else { break }
                running -= 1
                if !room.isEmpty { joined.insert(room) }
                start(&group)
            }
            group.cancelAll()
            log.notice("rejoined \(joined.count, privacy: .public) of \(rooms.count, privacy: .public) rooms")
            return joined
        }
    }

    /// Confirmation is the room reflecting our presence with status 110. A new connection's room state starts unjoined,
    /// even when a resumed session is still in the room.
    public static func join(_ room: String, nickname: String, client: XMPPClient, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        guard (try? await client.joinGroupRoom(room, nickname: nickname)) != nil else { return false }
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if (try? await client.groupRoomSnapshot(room))?.joined == true { return true }
            if await client.groupRoomRefusedJoin(room) { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    static let log = Logger(subsystem: "haus.xmpp.ios", category: "sync")
}

// Once reached, the run's outcome no longer depends on the connection.
actor CatchUpMark {
    private(set) var reached = false
    func reach() { reached = true }
}

// Ends 1 s before the deadline so the pull can never turn a finished catch-up into `deadlineExceeded`.
func readSyncTimeout<I: InstantProtocol<Duration>>(until deadline: I, now: I) -> Duration? {
    let left = now.duration(to: deadline) - .seconds(1)
    guard left >= .milliseconds(500) else { return nil }
    return min(.seconds(5), left)
}

// A connection lost after the own archive committed ends the run successfully; before that, it fails the run.
func consumeUntilDisconnect(after mark: CatchUpMark, _ consume: () async throws -> Void) async throws {
    do { try await consume() }
    catch BackgroundSynchronizationError.connectionEnded {
        guard await mark.reached else { throw BackgroundSynchronizationError.connectionEnded }
    }
}

// Polls the non-blocking kernel lease; returns the time spent waiting. With `liveness`, the first busy answer asks a
// running app once; an accepted answer throws `handedOff`. The lease is still tried first on every round. `now` is the
// wall clock both processes stamp the handshake with. An app waiting to give way to ends the wait without the lease.
func acquireTransportOwnership<C: Clock<Duration>>(_ store: MessageStore, waitingUpTo limit: Duration, interval: Duration = .milliseconds(250),
                                                   liveness: (any LivenessChannel)? = nil, giveWay: GiveWaySwitch? = nil,
                                                   answerPoll: Duration = .milliseconds(50),
                                                   clock: C = ContinuousClock(), now: @Sendable () -> Date = Date.init) async throws -> Duration {
    let start = clock.now
    var question: (request: LivenessRequest, listensUntil: C.Instant)?, asked = false
    while true {
        if let request = giveWay?.request { throw GiveWayStop(request: request) }
        do {
            try await store.acquireTransportOwnership()
            return start.duration(to: clock.now)
        } catch MessageStoreError.transportOwnedElsewhere {
            guard start.duration(to: clock.now) + interval <= limit else { throw MessageStoreError.transportOwnedElsewhere }
            if let liveness, !asked {
                asked = true
                // Also on the monotonic clock, so a wall clock set back cannot stretch the window.
                let request = LivenessRequest(sentAt: now()), listensUntil = clock.now.advanced(by: .seconds(LivenessHandshake.answerWindow))
                if (try? liveness.ask(request)) != nil { question = (request, listensUntil) }
            }
            let wake = clock.now.advanced(by: interval)
            if let liveness, let question {
                while clock.now < wake, clock.now <= question.listensUntil, LivenessHandshake.isListening(to: question.request, now: now()) {
                    if LivenessHandshake.accepts(liveness.latestAnswer(), to: question.request, now: now()) {
                        throw BackgroundSynchronizationError.handedOff
                    }
                    try await clock.sleep(for: answerPoll)
                }
            }
            if clock.now < wake { try await clock.sleep(until: wake, tolerance: nil) }
        }
    }
}

// Holds the lease through authorization, posting and the candidate delete. Local state and the OS presentation cannot
// be atomic, which is why posting replaces by stable identifier. The caller must still revalidate its credentials.
func finishBackgroundPresentation(store: MessageStore,
                                  presentation: (@Sendable (MessageStore) async throws -> Void)?) async throws {
    do {
        try Task.checkCancellation()
        try await presentation?(store)
        try await store.close()
    } catch {
        try await store.close()
        throw error
    }
}

// A cancelled run (an expiry or the run limit) has no time for the farewell: the socket closes at once, which ends every
// read and write and leaves the stream-management session to resume.
func stopTransport(_ client: XMPPClient) async {
    await withTaskCancellationHandler {
        if Task.isCancelled { await client.disconnect() }
        await client.disconnectAndWait()
    } onCancel: {
        Task { await client.disconnect() }
    }
}

// No automatic trust changes, no outbox, no plaintext (the processor ignores `.message`). A storage failure propagates
// so the sync stops before the next barrier.
func consumeBackgroundEvents(_ events: AsyncStream<XMPPEvent>, processor: InboundProcessor) async throws {
    for await event in events {
        try Task.checkCancellation()
        if case .state(.disconnected) = event { throw BackgroundSynchronizationError.connectionEnded }
        _ = try await processor.process(event)
    }
    try Task.checkCancellation()
    throw BackgroundSynchronizationError.connectionEnded
}

// Structured children cannot outlive lease ownership. Once `caughtUp` is reached the deadline ends the work without
// failing it; a granted `giveWay` throws `GiveWayStop`. Either way store transactions run whole on their actor, and a
// decryption cancelled before its commit keeps the ciphertext and the ratchet.
func runBackgroundWork(timeBudget: Duration, clock: some Clock<Duration> = ContinuousClock(), caughtUp: CatchUpMark? = nil,
                       giveWay: GiveWaySwitch? = nil,
                       operation: @escaping @Sendable () async throws -> Void,
                       consume: @escaping @Sendable () async throws -> Void,
                       stop: @escaping @Sendable () async -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await consume() }
        group.addTask {
            try await clock.sleep(for: timeBudget)
            if let caughtUp, await caughtUp.reached { return }
            throw BackgroundSynchronizationError.deadlineExceeded
        }
        if let giveWay { group.addTask { throw GiveWayStop(request: try await giveWay.untilStop()) } }
        do {
            try await group.next()
            group.cancelAll()
            await stop()
        } catch {
            group.cancelAll()
            await stop()
            throw error
        }
        // Group scope joins every child, even a durable commit that finishes after cancel.
    }
}
