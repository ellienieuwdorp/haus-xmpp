import Foundation
import MessageStore
import OMEMO
import os
import XMPPProtocol

/// One account's connection pipeline: lease, stream, live consumer, setup through `.ready` to a finished walk, room
/// rejoins, the outbox and the quiesce that stops it all. Interface state, platform work and app policy go through
/// the delegate. Main-actor isolated, so its state reads and writes order exactly as its owner's do.
@MainActor public final class SessionEngine {
    static let syncLog = Logger(subsystem: "haus.xmpp.ios", category: "sync")
    static let lifecycleLog = Logger(subsystem: "haus.xmpp.ios", category: "lifecycle")

    /// When the connection reached each point, for measurement; reset when the stream comes online.
    public struct Milestones: Sendable {
        public var online: ContinuousClock.Instant?
        public var ready: ContinuousClock.Instant?
        public var outboxStarted: ContinuousClock.Instant?
        public var caughtUp: ContinuousClock.Instant?
        public var settled: ContinuousClock.Instant?
        public init() {}
    }

    /// The tasks a new connection joins before it starts: the previous client's consumer, setup and backfill.
    public struct Handover {
        let client: XMPPClient?
        let events: Task<Void, Never>?
        let setup: Task<Void, Never>?
        let backfill: Task<Void, Never>?
    }

    public weak var delegate: (any SessionEngineDelegate)?
    let profiles: ServerProfileMemory
    public var account = ""
    public var store: MessageStore?
    public var encryption: OMEMOService?
    public var outboxSender: OutboxSender?

    /// Rotated by every reset; work captured under an older token stops at its next check.
    public var generation = UUID()
    public private(set) var client: XMPPClient?
    public internal(set) var eventTask: Task<Void, Never>?
    public internal(set) var setupTask: Task<Void, Never>?
    public internal(set) var drainTask: Task<Void, Never>?
    /// Cancelled by a reset, joined by a quiesce and by the next connection.
    public var backfillTask: Task<Void, Never>?
    var inbound: InboundProcessor?

    /// Refuses new transport, crypto and setup work while closed, and counts outside work a quiesce waits for.
    public let gate = TransportGate()
    /// With the delegate's `wantsTransport`, guards all transport, crypto and setup work, so a background transition
    /// blocks new work at once. A background transition keeps it on until the next foreground, past the release.
    public var quiescing: Bool { get { gate.closed } set { gate.closed = newValue } }
    /// Crypto and store work outside the engine's own tasks; a quiesce waits for it to reach zero.
    public var activeOperations: Int { get { gate.operations } set { gate.operations = newValue } }
    public var acquiringOwnership: Bool { get { gate.acquiring } set { gate.acquiring = newValue } }
    public var hasTransportOwnership = false
    /// Where the engine is between the foreground and a released lease; see `SessionEngine+Background`.
    public internal(set) var backgroundPhase = BackgroundPhase.foreground
    public var limits = BackgroundLimits()
    public var clock = EngineClock.continuous
    /// The background time the platform still grants; nil when it sets no limit (the Mac, a test that wants none).
    public var backgroundTimeRemaining: @MainActor () -> Duration? = { nil }
    var graceWakeup = Wakeup()
    var activeDeadline: QuiesceDeadline?
    var graceDeadline: QuiesceDeadline?
    var graceEndsAt: Duration?
    var backgroundExpired = false
    /// The last state the stream reported was `.online`.
    public internal(set) var streamOnline = false
    // Chats the last outbox pass held for a trust decision or a group problem: their queued messages wait for the user.
    var heldChats: Set<String> = []
    public internal(set) var outboxRequested = false
    /// Counts finished outbox passes, so a waiter can tell that a pass ran after its message was queued.
    public internal(set) var drainPasses = 0
    /// This connection's forward walk finished, so the single archive query is free.
    public internal(set) var archiveWalkFinished = false
    /// Setup reached `.ready` on the current stream and nothing has failed or reset since.
    public internal(set) var isReady = false

    public internal(set) var timings = SyncPhaseTimings()
    public internal(set) var milestones = Milestones()
    var connectPhases = SyncPhaseTimings.ConnectPhases()
    var onlineAt: ContinuousClock.Instant?
    var catchUpByArchive: [String: CatchUpProgress] = [:]
    var walking = false
    var firstMessageLogged = false
    var liveStoredLogged = false

    public init(profiles: ServerProfileMemory) { self.profiles = profiles }

    var wantsTransport: Bool { delegate?.wantsTransport ?? true }

    /// `.disconnected` cancels the setup task without changing the generation, so the generation alone would let a
    /// late `.step` or `.ready` overwrite the offline state and stop the reconciler.
    public func setupIsCurrent(_ token: UUID) -> Bool { generation == token && !Task.isCancelled }

    public func syncElapsed() -> Int {
        guard let onlineAt else { return -1 }
        return Int((ContinuousClock.now - onlineAt) / .milliseconds(1))
    }

    /// Invalidates the connection's generation and cancels its tasks without joining them, then lets the delegate
    /// reset what it shows. Returns the client to disconnect.
    @discardableResult public func resetConnection() -> XMPPClient? {
        generation = UUID()
        drainTask?.cancel()
        // Cancelled, not cleared: the next connection and a quiesce join the handle.
        setupTask?.cancel()
        // Cancelled, not cleared: a new connection's walk must never meet an old backfill.
        backfillTask?.cancel()
        archiveWalkFinished = false
        walking = false
        isReady = false
        streamOnline = false
        heldChats = []
        eventTask?.cancel()
        eventTask = nil
        let previous = client
        client = nil
        inbound = nil
        delegate?.sessionEngineDidReset()
        return previous
    }

    /// The first step of a connection: captures the previous connection's tasks and resets it.
    public func beginConnection() -> Handover {
        let events = eventTask, setup = setupTask, backfill = backfillTask
        return Handover(client: resetConnection(), events: events, setup: setup, backfill: backfill)
    }

    @discardableResult public func attach(_ connection: XMPPClient) -> XMPPClient {
        client = connection
        return connection
    }

    /// Disconnects the previous client and joins everything it ran.
    public func finish(_ handover: Handover) async {
        await handover.client?.disconnectAndWait()
        await handover.events?.value
        await handover.setup?.value
        await handover.backfill?.value
        if backfillTask == handover.backfill { backfillTask = nil }
        await drainTask?.value
    }

    /// Kept or taken, never by force: two minutes of a lease held elsewhere, or a change of generation or transport
    /// wish, ends the attempt.
    /// The delegate hears of every busy attempt and of how the wait ended, for the extension give-way.
    public func acquireOwnership(_ store: MessageStore, token: UUID) async throws {
        acquiringOwnership = true
        var waited = false, acquired = false
        defer {
            acquiringOwnership = false
            if waited { delegate?.leaseWaitEnded(acquired: acquired) }
        }
        for attempt in 0..<120 {
            guard wantsTransport, !quiescing, generation == token else { throw CancellationError() }
            do {
                try await store.acquireTransportOwnership()
                do { try await delegate?.ownershipAcquired(store: store) } catch {
                    await releaseLease(store)
                    throw error
                }
                // Still held by the store: the quiesce that refused it here releases it.
                guard wantsTransport, !quiescing, generation == token else { throw CancellationError() }
                hasTransportOwnership = true
                acquired = true
                return
            } catch MessageStoreError.transportOwnedElsewhere {
                waited = true
                delegate?.leaseBusy()
                guard attempt < 119 else { throw MessageStoreError.transportOwnedElsewhere }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The store frees the kernel lock even when marking interrupted sends fails, so only a failed unlock keeps it;
    /// that is retried three times. Returns whether the lock is free.
    @discardableResult public func releaseLease(_ store: MessageStore) async -> Bool {
        hasTransportOwnership = false
        for attempt in 1...3 {
            do {
                try await store.releaseTransportOwnership()
                Self.lifecycleLog.notice("lease released")
            } catch {
                // Sends the release could not mark stay as they are; every owner recovers them after acquiring.
                if !Self.isNotHeld(error) {
                    Self.lifecycleLog.error("lease release failed, attempt \(attempt, privacy: .public): \(String(reflecting: error), privacy: .public)")
                }
            }
            guard await store.holdsTransportOwnership else {
                delegate?.leaseReleased(true)
                return true
            }
            // A cancelled pause still retries: the lock must not stay held for want of a sleep.
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        Self.lifecycleLog.fault("lease still held: the transport lock did not unlock")
        hasTransportOwnership = true
        delegate?.leaseReleased(false)
        return false
    }

    private static func isNotHeld(_ error: any Error) -> Bool {
        if case MessageStoreError.transportOwnershipRequired = error { return true }
        return false
    }

    /// Without giving up the lease: blocks new transport, crypto and setup work, disconnects, and joins every reader,
    /// consumer, sender and outside crypto operation. New work stays refused afterwards; `resumeForeground` lets it in.
    public func stopTransportWork() async {
        _ = await quiesce(deadline: nil, release: nil)
    }

    /// The bounded quiesce: refuses new work at once, resets the connection, then runs `TransportQuiesce` against
    /// `deadline` (a point on `clock`) and releases the lease with `release` when every join ended. Work still stuck
    /// after the hard close is logged by name, and the release then waits for it however long it takes: the lock stays
    /// held, and the background task with it, so the platform ends the process rather than suspend it holding the lock.
    public func quiesce(deadline: Duration?, release: (@MainActor () async -> Bool)?) async -> TransportQuiesce.Outcome {
        quiescing = true
        let start = clock.now()
        let events = eventTask, setup = setupTask, backfill = backfillTask, drain = drainTask
        let previous = resetConnection()
        // The farewell is bounded by the client's own write limits; the reader it joins is the transport's last user.
        let disconnect = previous.map { client in Task { await client.disconnectAndWait() } }
        let work = [TransportQuiesce.Work("disconnect", disconnect), TransportQuiesce.Work("event consumer", events),
                    TransportQuiesce.Work("setup", setup), TransportQuiesce.Work("backfill", backfill), TransportQuiesce.Work("outbox", drain)]
        let limit = QuiesceDeadline(at: deadline, clock: clock)
        activeDeadline = limit
        defer { if activeDeadline === limit { activeDeadline = nil } }
        let core = TransportQuiesce(gate: gate, work: work, abort: { [weak self] in
                                        previous?.abort()
                                        self?.delegate?.quiesceDeadlinePassed()
                                    }, release: release, clock: clock, deadline: limit, abortJoin: limits.abortJoin)
        var outcome = await core.run()
        if backfillTask == backfill { backfillTask = nil }
        let elapsed = Int((clock.now() - start) / .milliseconds(1))
        Self.lifecycleLog.notice("transport stopped after \(elapsed, privacy: .public) ms, hard close \(outcome.hardClosed, privacy: .public)")
        guard !outcome.stuck.isEmpty else { return outcome }
        let stuck = outcome.stuck.joined(separator: "; ")
        Self.lifecycleLog.fault("quiesce deadline passed with work still running, the lease stays held: \(stuck, privacy: .public)")
        delegate?.quiesceStuck(outcome.stuck)
        guard let release else { return outcome }
        for item in work { await item.task?.value }
        await gate.untilIdle()
        outcome.released = await release()
        return outcome
    }
}
