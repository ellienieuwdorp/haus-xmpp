import Foundation
import MessageStore
import os
import XMPPProtocol

/// Between the foreground and a released lease. Each step refuses new setup, backfill, acquisition and UI crypto
/// mutations (the gate is closed from the request on); only `.grace` lets the outbox drain run, retries included, on
/// the stream that is already up. Nothing re-acquires the lease until `resumeForeground`.
public enum BackgroundPhase: Sendable, Equatable {
    case foreground
    /// Outbox only: the stream, the lease, the consumer and the drain stay; everything else is refused.
    case grace
    /// A return to the foreground cancelled the grace; the stream is kept for `resumeForeground`.
    case returning
    case quiescing
    /// Quiesced and released.
    case background
}

/// The background budget. The grace ends at the first of idle, `grace`, or what the platform grants less `margin` and
/// `quiesceReserve`; the quiesce must finish `margin` before the platform's limit, and after a hard close each join
/// gets `abortJoin` more.
public struct BackgroundLimits: Sendable, Equatable {
    public var grace: Duration = .seconds(20)
    public var margin: Duration = .seconds(5)
    public var quiesceReserve: Duration = .seconds(4)
    public var abortJoin: Duration = .seconds(1)
    public init() {}
}

/// Why a grace ended.
public enum GraceEnd: Sendable, Equatable {
    /// Nothing sendable is left and the server acknowledged everything written.
    case idle
    case deadline
    /// The platform's background time ran out.
    case expired
    /// The app came back; the stream stays.
    case foreground
    /// The stream ended, so nothing more can go out before the next connection.
    case streamLost
    /// No stream holding the lease to send on.
    case noSession
}

public struct BackgroundOutcome: Sendable, Equatable {
    /// nil when no grace was asked for.
    public var grace: GraceEnd?
    public var graceDuration: Duration = .zero
    /// nil when a return to the foreground cancelled the grace before any quiesce.
    public var quiesce: TransportQuiesce.Outcome?
    /// Messages were still queued, uploading or unacknowledged when the transport went away.
    public var unsent = false
    public init() {}
}

extension SessionEngine {
    // The current connection may keep working: in front, or in a grace for the outbox and the setup it runs on.
    var transportWorkAllowed: Bool { backgroundPhase == .grace || (wantsTransport && !quiescing) }

    /// Seconds of grace left, or nil outside one.
    public var graceTimeLeft: Duration? {
        guard backgroundPhase == .grace, let graceEndsAt else { return nil }
        return max(.zero, graceEndsAt - clock.now())
    }

    /// A background transition was asked for: from here no new setup, backfill, acquisition or UI crypto work starts.
    /// With `grace`, the outbox drain on the current stream may still run until `enterBackground` decides.
    public func backgroundRequested(grace: Bool = false) {
        quiescing = true
        backgroundExpired = false
        backgroundPhase = grace ? .grace : .quiescing
        Self.lifecycleLog.notice("background requested, grace allowed \(grace, privacy: .public)")
    }

    /// A return to the foreground was asked for: a grace in progress ends at once and keeps its stream. Everything else
    /// waits for `resumeForeground`, which runs after the background transition finished.
    public func foregroundRequested() {
        guard backgroundPhase == .grace else { return }
        backgroundPhase = .returning
        graceWakeup.signal()
    }

    /// The platform's background time is about to run out: a grace ends now, and a quiesce hard-closes at once.
    public func backgroundTimeExpiring() {
        guard backgroundPhase != .foreground else { return }
        Self.lifecycleLog.notice("background time expiring in phase \(String(describing: self.backgroundPhase), privacy: .public)")
        backgroundExpired = true
        graceWakeup.signal()
        graceDeadline?.fire()
        activeDeadline?.fire()
    }

    /// Something a grace waits on may have changed: the delegate's own work (`holdsGrace`), uploads, a liveness probe.
    public func graceWorkChanged() { graceWakeup.signal() }

    /// The transport goes to the background: a grace first, when one was asked for and work is pending, then the
    /// bounded quiesce and `release` (by default this engine's store). New work stays refused until `resumeForeground`.
    public func enterBackground(release: (@MainActor () async -> Bool)? = nil) async -> BackgroundOutcome {
        var outcome = BackgroundOutcome()
        if backgroundPhase == .grace {
            let start = clock.now()
            let end = await holdGrace()
            outcome.grace = end
            outcome.graceDuration = clock.now() - start
            let elapsed = Int(outcome.graceDuration / .milliseconds(1))
            Self.lifecycleLog.notice("grace ended: \(String(describing: end), privacy: .public) after \(elapsed, privacy: .public) ms")
            if end == .foreground { return outcome }
        }
        guard backgroundPhase != .returning else { return outcome }
        outcome.unsent = await hasUnsentMessages()
        backgroundPhase = .quiescing
        let store = store
        let release = release ?? { [weak self] in
            guard let self, let store else { return true }
            return await self.releaseLease(store)
        }
        outcome.quiesce = await quiesce(deadline: quiesceDeadline(), release: release)
        if backgroundPhase == .quiescing { backgroundPhase = .background }
        if outcome.unsent { delegate?.unsentNotice(true) }
        return outcome
    }

    /// The foreground is back, after any background transition finished: new work is let in again. True when a
    /// cancelled grace kept a stream that is still up and holds the lease, so nothing needs to reconnect.
    @discardableResult public func resumeForeground() -> Bool {
        let returning = backgroundPhase == .returning
        guard backgroundPhase != .foreground else { return false }
        backgroundPhase = .foreground
        quiescing = false
        backgroundExpired = false
        delegate?.unsentNotice(false)
        return returning && streamOnline && hasTransportOwnership && client != nil
    }

    /// Waits until nothing is sendable and everything written is acknowledged, at most `limit`, starting a pass first.
    /// For a termination the platform announced; true when the outbox emptied in time.
    public func flushOutbox(within limit: Duration) async -> Bool {
        guard hasTransportOwnership, streamOnline, client != nil else { return false }
        let deadline = QuiesceDeadline(at: clock.now() + limit, clock: clock)
        defer { deadline.cancel() }
        startOutbox()
        while !deadline.passed {
            guard let client, streamOnline else { return false }
            if await isIdle(client) { return true }
            await deadline.wait(for: graceWakeup)
        }
        return false
    }

    private func holdGrace() async -> GraceEnd {
        guard hasTransportOwnership, streamOnline, let client else { return .noSession }
        var limit = limits.grace
        if let remaining = backgroundTimeRemaining() { limit = min(limit, remaining - limits.margin - limits.quiesceReserve) }
        guard limit > .zero else { return .deadline }
        let deadline = QuiesceDeadline(at: clock.now() + limit, clock: clock)
        graceDeadline = deadline
        graceEndsAt = clock.now() + limit
        defer { deadline.cancel(); graceDeadline = nil; graceEndsAt = nil }
        // An idle app holds no grace: nothing queued to send, no pass, nothing unacknowledged.
        let pending = await hasUnsentMessages()
        if !pending, await isIdle(client) { return .idle }
        guard backgroundPhase == .grace else { return .foreground }
        delegate?.graceStarted()
        // A queued message whose pass was never asked for (the share extension queued it) goes too.
        if pending { startOutbox() }
        var end = GraceEnd.deadline
        while true {
            if backgroundPhase != .grace { end = .foreground; break }
            if backgroundExpired { end = .expired; break }
            if deadline.passed { end = .deadline; break }
            guard streamOnline, self.client === client else { end = .streamLost; break }
            if await isIdle(client) { end = .idle; break }
            await deadline.wait(for: graceWakeup)
        }
        // Whatever arrived during the grace is presented under the lease before the quiesce takes it.
        await delegate?.graceEnding(end)
        return backgroundPhase == .returning ? .foreground : end
    }

    // Nothing runs or waits to run, the delegate holds nothing, and every message written was acknowledged. Queued rows
    // a pass left behind wait for the user (trust, a group problem, an upload not yet done) and do not count.
    func isIdle(_ client: XMPPClient) async -> Bool {
        guard outboxIdle, !(delegate?.holdsGrace ?? false) else { return false }
        return await !client.awaitsAcknowledgement()
    }

    private func quiesceDeadline() -> Duration? {
        if backgroundExpired { return clock.now() }
        guard let remaining = backgroundTimeRemaining() else { return nil }
        return clock.now() + max(.zero, remaining - limits.margin)
    }

    // Queued or uploading messages outside the chats the last pass held, or anything written and not yet acknowledged.
    private func hasUnsentMessages() async -> Bool {
        if let client, await client.awaitsAcknowledgement() { return true }
        guard let store, !account.isEmpty else { return false }
        let account = account, held = heldChats
        let ready = (try? await store.queuedOutgoing(accountID: account)) ?? []
        let uploading = (try? await store.attachmentsAwaitingUpload(accountID: account)) ?? []
        return (ready + uploading).contains { !held.contains($0.chatID) }
    }
}
