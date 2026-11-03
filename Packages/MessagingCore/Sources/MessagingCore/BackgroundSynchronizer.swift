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
    public var accountID: String { username + "@" + domain }

    public init(route: XMPPRoute, domain: String, username: String, password: String, requiresSCRAM: Bool = false,
                labCertificateAuthority: Data? = nil, resource: String? = nil,
                push: XMPPPushConfiguration? = nil, leftForeground: Date? = nil) {
        self.route = route; self.domain = domain
        self.username = username; self.password = password; self.requiresSCRAM = requiresSCRAM
        self.labCertificateAuthority = labCertificateAuthority
        self.resource = resource; self.push = push; self.leftForeground = leftForeground
    }
    public var description: String { "BackgroundAccount(<redacted>)" }
    public var debugDescription: String { description }
}

public enum BackgroundSynchronizationError: Error, Sendable, Equatable {
    case identityUnavailable, deadlineExceeded, invalidTimeBudget, connectionEnded
    /// The own archive query was refused or unanswered, so the run cannot claim catch-up.
    case ownArchiveIncomplete
    /// The app answered the liveness handshake and presents the push itself.
    case handedOff
}

/// One bounded catch-up under the same kernel lease as the app. Success means durable archive completion, not that a
/// particular notification represents a new message.
public struct BackgroundSynchronizer: Sendable {
    public init() {}

    /// Runs under the lease.
    public typealias Presentation = @Sendable (MessageStore, PresentationStage) async throws -> Void

    /// `leaseWait` is spent inside `timeBudget`. With `liveness`, a busy lease first asks a running app; an answer in
    /// time throws `handedOff`. `presentation` runs as `.direct` once the own archive committed and rooms follow, and
    /// once at the end.
    public func synchronize(databaseURL: URL, wrappingKey: Data, account: BackgroundAccount,
                            timeBudget: Duration = .seconds(20), leaseWait: Duration = .seconds(6),
                            liveness: (any LivenessChannel)? = nil,
                            progress: NotificationRunProgress? = nil,
                            presentation: Presentation? = nil) async throws {
        guard timeBudget > .zero, timeBudget <= .seconds(25), leaseWait >= .zero, leaseWait < timeBudget else {
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
            do { waited = try await acquireTransportOwnership(store, waitingUpTo: leaseWait, liveness: liveness) }
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
            let client = XMPPClient(labCertificateAuthority: account.labCertificateAuthority)
            try await client.configureStreamManagement(persistence: StreamPersistence(
                store: store, accountID: account.accountID, encryption: encryption))
            if let resource = account.resource { try await client.configureResource(resource) }
            let preferences = try await store.accountPreferences(accountID: account.accountID)
            try await client.setAvailability(BackgroundSession.availability(sharesLastSeen: preferences.lastSeen,
                                                                            leftForeground: account.leftForeground),
                                             clientActive: false)
            try await store.recoverInterruptedSubmissions(accountID: account.accountID)
            // Taken before the timer starts, so never later than the real deadline.
            let deadline = ContinuousClock.now + timeBudget - waited
            try await BackgroundCatchUp(
                connect: {
                    try await client.connect(route: account.route, domain: account.domain, username: account.username,
                                             password: account.password, requireSCRAM: account.requiresSCRAM)
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
                                                                 store: store, within: readSyncTimeout(until: deadline))
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
                    try await ReadSync(store: store).pull(account: account.accountID, client: client, encryption: encryption, timeout: timeout)
                },
                consume: {
                    try await consumeBackgroundEvents(client.events, processor: InboundProcessor(encryption: encryption, client: client, account: account.accountID))
                },
                stop: { await client.disconnectAndWait() }
            ).run(store: store, timeBudget: timeBudget - waited, deadline: deadline, progress: progress, presentation: presentation)
        } catch {
            // runBackgroundWork has joined crypto, archive and reader work. close releases ownership only if this
            // instance acquired it.
            try await store.close()
            throw error
        }
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
    let pull: @Sendable (Duration) async throws -> Void
    let consume: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void
    var roomsAfterPost: Duration = .seconds(5)

    func run(store: MessageStore, timeBudget: Duration, deadline: ContinuousClock.Instant, progress: NotificationRunProgress?,
             presentation: BackgroundSynchronizer.Presentation?) async throws {
        let caughtUp = CatchUpMark(), ownArchiveWalked = CatchUpMark(), ledger = CatchUpLedger()
        // A slow or lost server leaves the run a success.
        @Sendable func pullReadState() async throws {
            if let timeout = readSyncTimeout(until: deadline) { try await pull(timeout) }
            await ledger.notePull()
        }
        @Sendable func walkArchives() async throws {
            try await walk({ if $0.archive != nil, $0.messages > 0 { await ledger.noteRoomMessages() } }, { complete, rooms in
                await ownArchiveWalked.reach()
                // The own archive holds the direct messages a push is about; without it the run shows the fallback.
                guard complete else { throw BackgroundSynchronizationError.ownArchiveIncomplete }
                await caughtUp.reach()
                guard rooms > 0 else { return }
                // Before the claim, so chats read on another device lose their candidates.
                try await pullReadState()
                guard let presentation else { return }
                do { try await presentation(store, .direct) }
                catch is CancellationError { throw CancellationError() }
                // The final presentation retries everything still pending.
                catch { BackgroundSession.log.notice("direct presentation failed: \(String(describing: type(of: error)), privacy: .public)") }
                // A presentation that failed part-way still counts as showing.
                if (progress?.report.posted ?? 0) > 0 { await ledger.notePostedEarly() }
            })
        }
        try await runBackgroundWork(timeBudget: timeBudget, caughtUp: caughtUp, operation: {
            try await connect()
            try Task.checkCancellation()
            async let duties: Void = sessionDuties(ownArchiveWalked)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await walkArchives() }
                    group.addTask {
                        while await !ledger.postedEarly { try await Task.sleep(for: .milliseconds(50)) }
                        try await Task.sleep(for: roomsAfterPost)
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
            await duties
        }, consume: {
            try await consumeUntilDisconnect(after: caughtUp) { try await consume() }
        }, stop: stop)
        try Task.checkCancellation()
        // From here a new push starts the next run.
        progress?.enter(.presenting)
        let stage = await ledger.finalStage(pastDeadline: ContinuousClock.now >= deadline)
        var final: (@Sendable (MessageStore) async throws -> Void)?
        if let presentation { final = { try await presentation($0, stage) } }
        try await finishBackgroundPresentation(store: store, presentation: final)
    }
}

actor CatchUpLedger {
    private(set) var postedEarly = false
    private var roomsWalked = false, pulled = false, roomMessages = false
    private var roomError: (any Error)?
    func notePostedEarly() { postedEarly = true }
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
func readSyncTimeout(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Duration? {
    let left = deadline - now - .seconds(1)
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
// running app once; an accepted answer throws `handedOff`. The lease is still tried first on every round.
func acquireTransportOwnership(_ store: MessageStore, waitingUpTo limit: Duration, interval: Duration = .milliseconds(250),
                               liveness: (any LivenessChannel)? = nil, answerPoll: Duration = .milliseconds(50)) async throws -> Duration {
    let clock = ContinuousClock(), start = clock.now
    var question: (request: LivenessRequest, listensUntil: ContinuousClock.Instant)?, asked = false
    while true {
        do {
            try await store.acquireTransportOwnership()
            return clock.now - start
        } catch MessageStoreError.transportOwnedElsewhere {
            guard clock.now - start + interval <= limit else { throw MessageStoreError.transportOwnedElsewhere }
            if let liveness, !asked {
                asked = true
                // Also on the monotonic clock, so a wall clock set back cannot stretch the window.
                let request = LivenessRequest(), listensUntil = clock.now + .seconds(LivenessHandshake.answerWindow)
                if (try? liveness.ask(request)) != nil { question = (request, listensUntil) }
            }
            let wake = clock.now + interval
            if let liveness, let question {
                while clock.now < wake, clock.now <= question.listensUntil, LivenessHandshake.isListening(to: question.request) {
                    if LivenessHandshake.accepts(liveness.latestAnswer(), to: question.request) { throw BackgroundSynchronizationError.handedOff }
                    try await Task.sleep(for: answerPoll)
                }
            }
            let left = wake - clock.now
            if left > .zero { try await Task.sleep(for: left) }
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

// Structured children cannot outlive lease ownership, even when the deadline wins the race. Once `caughtUp` is
// reached the deadline ends the work without failing it.
func runBackgroundWork(timeBudget: Duration, caughtUp: CatchUpMark? = nil,
                       operation: @escaping @Sendable () async throws -> Void,
                       consume: @escaping @Sendable () async throws -> Void,
                       stop: @escaping @Sendable () async -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await consume() }
        group.addTask {
            try await Task.sleep(for: timeBudget)
            if let caughtUp, await caughtUp.reached { return }
            throw BackgroundSynchronizationError.deadlineExceeded
        }
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
