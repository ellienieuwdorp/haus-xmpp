import Foundation
import os
import MessageStore
import OMEMO
import XMPPProtocol

/// Loaded from protected local account storage, never from an untrusted push payload.
public struct BackgroundAccount: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The endpoint the app last connected through; discovery runs only if it fails and the route allows it.
    public let route: XMPPRoute
    public let domain: String
    public let username: String
    public let password: String
    /// PLAIN is refused once the account has authenticated with SCRAM.
    public let requiresSCRAM: Bool
    public let labCertificateAuthority: Data?
    /// This installation's resource for the account; nil keeps a random one for this run.
    public let resource: String?
    /// The subscription a fresh session re-enables (`BackgroundSession.enablePush`); nil when push is not settled.
    public let push: XMPPPushConfiguration?
    /// The last time the app was in front, announced as XEP-0319 idle when the account shares last seen.
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
    /// The server refused or did not answer a query on the account's own archive: the run cannot claim catch-up.
    case ownArchiveIncomplete
}

/// An extension performs one bounded catch-up under the same kernel lease as the app.
/// Success means durable archive completion. It does not claim a particular notification
/// represents a new message; notification previews require a separate privacy-aware projection.
public struct BackgroundSynchronizer: Sendable {
    public init() {}

    /// `leaseWait` is spent inside `timeBudget`: the app or another run may briefly hold the lease (plan D2).
    public func synchronize(databaseURL: URL, wrappingKey: Data, account: BackgroundAccount,
                            timeBudget: Duration = .seconds(20), leaseWait: Duration = .seconds(6),
                            progress: NotificationRunProgress? = nil,
                            presentation: (@Sendable (MessageStore) async throws -> Void)? = nil) async throws {
        guard timeBudget > .zero, timeBudget <= .seconds(25), leaseWait >= .zero, leaseWait < timeBudget else {
            throw BackgroundSynchronizationError.invalidTimeBudget
        }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw BackgroundSynchronizationError.identityUnavailable
        }
        // Never migrates: a store an older build wrote waits, untouched, for the app to snapshot and upgrade it.
        let store = try MessageStore(url: databaseURL, schema: .currentOnly)
        do {
            // Busy means wait a bounded time, then defer: never expire another process's lock or reset its attempts.
            progress?.enter(.leaseWait)
            let waited = try await acquireTransportOwnership(store, waitingUpTo: leaseWait)
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
                                                                            leftForeground: account.leftForeground))
            try await store.recoverInterruptedSubmissions(accountID: account.accountID)
            // Taken before the timer starts, so it is never later than the real deadline.
            let deadline = ContinuousClock.now + timeBudget - waited
            let caughtUp = CatchUpMark()
            try await runBackgroundWork(timeBudget: timeBudget - waited, operation: {
                try await client.connect(route: account.route, domain: account.domain, username: account.username,
                                         password: account.password, requireSCRAM: account.requiresSCRAM)
                try Task.checkCancellation()
                // A fresh bind replaced the session the server pushed for: it must push again and receive room traffic.
                let fresh = await !client.sessionResumed
                BackgroundSession.log.notice("background session resumed=\(!fresh, privacy: .public)")
                async let pushEnabled: Void = fresh ? BackgroundSession.enablePush(account.push, client: client) : ()
                // Direct messages first: the rejoins start once the own archive is walked (the first room page commits)
                // or the walk ends, so a long room walk cannot use up their time. Best effort: they never fail the run.
                let ownArchiveWalked = CatchUpMark()
                @Sendable func rejoin() async -> Set<String> {
                    while await !ownArchiveWalked.reached {
                        guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return [] }
                    }
                    return await BackgroundSession.joinRooms(account: account.accountID, client: client, encryption: encryption,
                                                             store: store, within: readSyncTimeout(until: deadline))
                }
                async let joined = fresh ? rejoin() : []
                // No identity initialization, trust acceptance, queued-message preparation or
                // outbox drain. Resumption may replay only previously authorized exact bytes.
                let outcome = try await ArchiveSynchronizer(store: store).synchronize(
                    account: account.accountID, client: client, encryption: encryption,
                    progress: { if $0.archive != nil { await ownArchiveWalked.reach() } })
                await ownArchiveWalked.reach()
                // The own archive holds the direct messages a push is about; without its newest entry the run shows the
                // fallback, and the next run or the app walks it again. A refused or unreachable room does not fail it.
                guard outcome.ownArchiveComplete else { throw BackgroundSynchronizationError.ownArchiveIncomplete }
                await caughtUp.reach()
                // Best effort from here: the pull, the rejoins and the enable can no longer fail a run whose walk committed.
                // After catch-up, before the claim: chats read on another device have their pointers moved, which
                // removes their candidates. Own XEP-0333 markers were applied by the walk and the live consumer.
                // Best effort within what is left of the budget: a slow or lost server leaves the run a success.
                if let timeout = readSyncTimeout(until: deadline) {
                    try await ReadSync(store: store).pull(account: account.accountID, client: client, encryption: encryption, timeout: timeout)
                }
                _ = await (pushEnabled, joined)
            }, consume: {
                try await consumeUntilDisconnect(after: caughtUp) {
                    try await consumeBackgroundEvents(client.events, processor: InboundProcessor(encryption: encryption, client: client, account: account.accountID))
                }
            }, stop: { await client.disconnectAndWait() })
            try Task.checkCancellation()
            // From here a new push starts the next run: this one's network work is over.
            progress?.enter(.presenting)
            try await finishBackgroundPresentation(store: store, presentation: presentation)
        } catch {
            // runBackgroundWork joins crypto, archive and reader work before reaching here.
            // close releases ownership only if this instance acquired it.
            try await store.close()
            throw error
        }
    }
}

/// What a session opened away from the foreground (this extension, a notification action) owes the server. After a
/// fresh bind the new session replaced the one the app set up: that one had push enabled and sat in the rooms.
public enum BackgroundSession {
    /// Rooms joined at once; the rest wait for a slot, all inside one deadline.
    static let concurrentJoins = 8

    /// Away since the app was last in front, without the timestamp for an account that does not share last seen or
    /// when that time was never recorded. Stable across runs: a changed value is announced to every contact, and a
    /// value that moved with each run would make every resumed run broadcast presence.
    public static func availability(sharesLastSeen: Bool, leftForeground: Date?, now: Date = Date()) -> XMPPAvailability {
        .away(since: sharesLastSeen ? leftForeground.map { min($0, now) } : nil)
    }

    /// XEP-0357 enable of the saved subscription on the new session. Registration with the gateway stays the app's
    /// job; this only tells the account server where to push. A failure leaves the next app connection to repair it.
    public static func enablePush(_ push: XMPPPushConfiguration?, client: XMPPClient) async {
        guard let push else { return }
        do { try await client.enablePush(push) }
        catch { log.notice("push re-enable failed: \(String(describing: type(of: error)), privacy: .public)") }
    }

    /// Joins every stored room but `skipping` (`<history maxstanzas='0'/>`: the room archive walk covers history) so the
    /// server routes and pushes room traffic to this session again. Concurrent and bounded by `within`; a room that
    /// refuses, fails or has not confirmed the join by the deadline is left to the next app connection. Returns the rooms
    /// that confirmed.
    @discardableResult
    public static func joinRooms(account: String, client: XMPPClient, encryption: OMEMOService, store: MessageStore,
                                 skipping: Set<String> = [], within limit: Duration?) async -> Set<String> {
        guard let limit, let known = try? await encryption.knownGroupRooms(account: account).keys.sorted() else { return [] }
        let rooms = known.filter { !skipping.contains($0) }
        guard !rooms.isEmpty else { return [] }
        let fallback = String(account.prefix { $0 != "@" })
        var nicknames: [String: String] = [:]
        for room in rooms { nicknames[room] = (try? await store.groupNickname(accountID: account, room: room)) ?? fallback }
        // Each child answers with its room when joined, "" when it failed, and nil for the deadline.
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

    /// Joins `room` and waits until it confirms (it reflects our own presence with status 110), refuses, or `limit`
    /// passes. A new connection's room state starts unjoined, even when a resumed session is still in the room.
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

/// Set once the archive walk has committed: from then on the run's outcome no longer depends on the connection.
actor CatchUpMark {
    private(set) var reached = false
    func reach() { reached = true }
}

/// How long the post-catch-up XEP-0490 pull may take: at most 5 s, ending 1 s before the run's deadline so the pull
/// can never turn a finished catch-up into `deadlineExceeded`. nil when too little is left to try.
func readSyncTimeout(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Duration? {
    let left = deadline - now - .seconds(1)
    guard left >= .milliseconds(500) else { return nil }
    return min(.seconds(5), left)
}

/// A connection that ends after catch-up committed (while the best-effort pull runs) ends the run as the walk alone
/// would have: successfully, with the candidates it committed. Before that, a lost connection fails the run as always.
func consumeUntilDisconnect(after mark: CatchUpMark, _ consume: () async throws -> Void) async throws {
    do { try await consume() }
    catch BackgroundSynchronizationError.connectionEnded {
        guard await mark.reached else { throw BackgroundSynchronizationError.connectionEnded }
    }
}

/// Polls the non-blocking kernel lease until it is free or `limit` passes; cancellable. Returns the time spent waiting.
func acquireTransportOwnership(_ store: MessageStore, waitingUpTo limit: Duration,
                               interval: Duration = .milliseconds(250)) async throws -> Duration {
    let clock = ContinuousClock(), start = clock.now
    while true {
        do {
            try await store.acquireTransportOwnership()
            return clock.now - start
        } catch MessageStoreError.transportOwnedElsewhere {
            guard clock.now - start + interval <= limit else { throw MessageStoreError.transportOwnedElsewhere }
            try await Task.sleep(for: interval)
        }
    }
}

/// Keep the cross-process lease through authorization, posting and the candidate delete. The caller must still
/// revalidate its current protected credentials; this cannot make local state and the operating system's
/// presentation atomic, which is why posting replaces by stable identifier.
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

/// The extension persists exactly what the app would: the processor decides, this loop only
/// ends on disconnect. No automatic trust changes, no outbox, no plaintext (the processor
/// ignores `.message`); a storage failure propagates so the sync stops before the next barrier.
func consumeBackgroundEvents(_ events: AsyncStream<XMPPEvent>, processor: InboundProcessor) async throws {
    for await event in events {
        try Task.checkCancellation()
        if case .state(.disconnected) = event { throw BackgroundSynchronizationError.connectionEnded }
        _ = try await processor.process(event)
    }
    try Task.checkCancellation()
    throw BackgroundSynchronizationError.connectionEnded
}

/// The seam tests lifetime ordering with suspended persistence instead of a fake crypto engine.
/// Structured children cannot outlive ownership, including when the deadline wins the race.
func runBackgroundWork(timeBudget: Duration,
                       operation: @escaping @Sendable () async throws -> Void,
                       consume: @escaping @Sendable () async throws -> Void,
                       stop: @escaping @Sendable () async -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await consume() }
        group.addTask {
            try await Task.sleep(for: timeBudget)
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
