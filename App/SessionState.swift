import Foundation

/// The one connection state every screen reads. Chat-level trust is separate (stored device trust).
enum SessionState: Equatable {
    case offline(reason: String?)
    case connecting(step: String)
    case connected(settingUp: String)
    case ready
    case needsAttention(step: String, detail: String)

    var isConnected: Bool { if case .connected = self { true } else { self == .ready } }
    var isConnecting: Bool { if case .connecting = self { true } else { false } }
    var isReady: Bool { self == .ready }
    /// The reconciler may start a new attempt from here.
    var isConnectable: Bool {
        switch self {
        case .offline, .needsAttention: true
        case .connecting, .connected, .ready: false
        }
    }

    /// One line for Settings and the sign-in sheet.
    var label: String {
        switch self {
        case .offline(let reason): reason ?? "Offline"
        case .connecting(let step): step
        case .connected(let step): "Connected · \(step)…"
        case .ready: "Connected"
        case .needsAttention(let step, _): "Encryption setup needs attention (\(step))"
        }
    }
}

/// When the reconciler reconnects, and when a setup failure is worth an alert. A connection forgives earlier failures
/// only once its setup settled (`ConnectionSetup.Event.settled`) and it stayed up for `stableUptime`. `.ready` alone
/// comes before the walk and the rejoins, and on a quiet account setup settles within a second, so a server that drops
/// the stream right after login (a kick, a rate limit, a walk that fails the same way each time) would otherwise be
/// retried with no delay and alert on every cycle.
struct ReconnectPolicy {
    static let stableUptime: Duration = .seconds(60)
    /// Consecutive attempts since the last healthy session or user action.
    private(set) var attempt = 0
    /// The failure already shown since the last healthy session.
    private var alerted: String?
    /// When the current connection went online, and whether its setup settled.
    private var onlineSince: ContinuousClock.Instant?
    private var settled = false

    /// Reconnect delay for the given consecutive failure count: immediate, then 1, 2, 4 … 60 s with jitter.
    static func delay(attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }
        let base = min(60.0, pow(2.0, Double(attempt - 1)))
        return .seconds(base * Double.random(in: 1.0...1.25))
    }

    /// The wait before the next attempt.
    var nextDelay: Duration { Self.delay(attempt: attempt) }

    /// An attempt starts after its delay.
    mutating func attemptStarted() { attempt += 1 }

    mutating func online(at now: ContinuousClock.Instant = .now) {
        onlineSince = now
        settled = false
    }

    mutating func observe(_ event: ConnectionSetup.Event) {
        if event == .settled { settled = true }
    }

    /// The connection ended; call before asking for `nextDelay`.
    mutating func ended(at now: ContinuousClock.Instant = .now) {
        forgiveIfHealthy(now)
        onlineSince = nil
        settled = false
    }

    /// The app returned to the foreground or the network came back: retry at once. A failure that then repeats is not
    /// shown again. A sign-in starts from a new policy instead.
    mutating func retryNow() { attempt = 0 }

    /// True the first time this failure is seen since the last healthy session.
    mutating func shouldAlert(_ detail: String, at now: ContinuousClock.Instant = .now) -> Bool {
        forgiveIfHealthy(now)
        guard alerted != detail else { return false }
        alerted = detail
        return true
    }

    private mutating func forgiveIfHealthy(_ now: ContinuousClock.Instant) {
        guard settled, let onlineSince, now - onlineSince >= Self.stableUptime else { return }
        attempt = 0
        alerted = nil
    }
}
