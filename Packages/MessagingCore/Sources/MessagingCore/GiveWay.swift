import Foundation

/// Saved by the app in the App Group while it waits for the transport lease the notification extension holds. One
/// nonce per lease wait; the app refreshes `sentAt` while it keeps waiting, so a request goes stale soon after it stops.
public struct GiveWayRequest: Codable, Sendable, Equatable {
    public let nonce: String
    public let sentAt: Date

    public init(nonce: String = UUID().uuidString, sentAt: Date = Date()) {
        self.nonce = nonce; self.sentAt = sentAt
    }
}

/// Saved by the app once it holds the lease it asked for, echoing that wait's nonce. It also ends the request.
public struct GiveWayTakeover: Codable, Sendable, Equatable {
    public let nonce: String
    public let takenAt: Date

    public init(nonce: String, takenAt: Date = Date()) {
        self.nonce = nonce; self.takenAt = takenAt
    }
}

/// How the extension reads what the app saved; nil when absent or unreadable.
public protocol GiveWayChannel: Sendable {
    func latestRequest() -> GiveWayRequest?
    func latestTakeover() -> GiveWayTakeover?
}

/// Anyone may post the ring, so it only makes the extension read the App Group, which only this build writes. The
/// extension stops early only for a fresh request no takeover answered yet, and suppresses its push only when the app
/// then confirms, with that request's nonce, that it holds the lease. Anything else falls back.
public enum GiveWayHandshake {
    /// A request older than this is from an app that stopped waiting.
    public static let requestLifetime: TimeInterval = 2
    /// How often a waiting app rewrites its request, well inside `requestLifetime`.
    public static let refreshInterval: TimeInterval = 1
    /// How long the extension, having released the lease, waits for the app's takeover. The app polls the lease every
    /// 250 ms.
    public static let takeoverWindow: Duration = .seconds(3)
    // Both processes read one wall clock; this only absorbs the rounding of the timestamps they write.
    static let clockTolerance: TimeInterval = 0.25

    static func isPending(_ request: GiveWayRequest, answeredBy takeover: GiveWayTakeover?, now: Date) -> Bool {
        guard !request.nonce.isEmpty, takeover?.nonce != request.nonce else { return false }
        let age = now.timeIntervalSince(request.sentAt)
        return age >= -clockTolerance && age <= requestLifetime
    }

    static func confirms(_ takeover: GiveWayTakeover?, of request: GiveWayRequest, now: Date) -> Bool {
        guard let takeover, !request.nonce.isEmpty, takeover.nonce == request.nonce else { return false }
        return takeover.takenAt >= request.sentAt.addingTimeInterval(-clockTolerance)
            && takeover.takenAt <= now.addingTimeInterval(clockTolerance)
    }
}

/// One extension run's stop signal. `check` rereads the App Group; the extension calls it on every ring. Once it sees
/// a pending request the run stops at its next safe point, unless its final presentation already began.
public final class GiveWaySwitch: @unchecked Sendable {
    // Guards every var below.
    private let lock = NSLock()
    private let channel: (any GiveWayChannel)?
    private let now: @Sendable () -> Date
    private var granted: GiveWayRequest?
    private var closed = false
    private var shieldedRuns = 0
    private var waiters: [UUID: CheckedContinuation<GiveWayRequest, any Error>] = [:]

    public init(channel: any GiveWayChannel, now: @escaping @Sendable () -> Date = Date.init) {
        self.channel = channel; self.now = now
    }

    // Never stops: a run nobody can ask to give way.
    init() { channel = nil; now = Date.init }

    public func check() {
        guard let channel, let request = channel.latestRequest(),
              GiveWayHandshake.isPending(request, answeredBy: channel.latestTakeover(), now: now()) else { return }
        let ready = lock.withLock { () -> [CheckedContinuation<GiveWayRequest, any Error>] in
            guard !closed, granted == nil else { return [] }
            granted = request
            return shieldedRuns == 0 ? takeWaiters() : []
        }
        ready.forEach { $0.resume(returning: request) }
    }

    /// The request this run gives way to; nil while it carries on.
    public var request: GiveWayRequest? { lock.withLock { granted } }

    // The final presentation is starting: the run ends on its own soon, and a stop now could only repeat banners.
    func close() { lock.withLock { closed = true } }

    // Work a stop waits for instead of interrupting, such as a presentation that is posting. Skipped once a stop is due.
    func shielded(_ operation: () async throws -> Void) async rethrows {
        guard lock.withLock({ () -> Bool in
            guard granted == nil else { return false }
            shieldedRuns += 1
            return true
        }) else { return }
        defer { leaveShield() }
        try await operation()
    }

    private func leaveShield() {
        let (ready, request) = lock.withLock { () -> ([CheckedContinuation<GiveWayRequest, any Error>], GiveWayRequest?) in
            shieldedRuns -= 1
            guard shieldedRuns == 0, let granted else { return ([], nil) }
            return (takeWaiters(), granted)
        }
        if let request { ready.forEach { $0.resume(returning: request) } }
    }

    // Returns the request once one is granted and no shielded work runs; throws CancellationError when cancelled first.
    func untilStop() async throws -> GiveWayRequest {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<GiveWayRequest, any Error>) in
                let early = lock.withLock { () -> Result<GiveWayRequest, any Error>? in
                    if let granted, shieldedRuns == 0 { return .success(granted) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    waiters[id] = waiter
                    return nil
                }
                if let early { waiter.resume(with: early) }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    // After the lease was released: true once the app confirms it took over `request`, false at the takeover window.
    func takeover<C: Clock<Duration>>(of request: GiveWayRequest, clock: C, poll: Duration = .milliseconds(50)) async throws -> Bool {
        let end = clock.now.advanced(by: GiveWayHandshake.takeoverWindow)
        while true {
            if GiveWayHandshake.confirms(channel?.latestTakeover(), of: request, now: now()) { return true }
            let left = clock.now.duration(to: end)
            guard left > .zero else { return false }
            try await clock.sleep(for: min(poll, left))
        }
    }

    private func takeWaiters() -> [CheckedContinuation<GiveWayRequest, any Error>] {
        defer { waiters = [:] }
        return Array(waiters.values)
    }
}

// Thrown inside the run to stop it; `BackgroundSynchronizer` turns it into the handed-off outcome or a fallback.
struct GiveWayStop: Error {
    let request: GiveWayRequest
}
