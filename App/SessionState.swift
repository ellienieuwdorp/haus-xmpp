import Foundation

// Chat-level trust is separate: it comes from stored device trust.
enum SessionState: Equatable {
    case offline(reason: String?)
    case connecting(step: String)
    case connected(settingUp: String)
    case ready
    case needsAttention(step: String, detail: String)

    var isConnected: Bool { if case .connected = self { true } else { self == .ready } }
    var isConnecting: Bool { if case .connecting = self { true } else { false } }
    var isReady: Bool { self == .ready }
    var isConnectable: Bool {
        switch self {
        case .offline, .needsAttention: true
        case .connecting, .connected, .ready: false
        }
    }

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

// A connection forgives earlier failures only once setup settled and it stayed up for `stableUptime`: `.ready` comes
// before the walk and rejoins, so a server that drops the stream right after login would otherwise be retried at once
// and alert on every cycle.
struct ReconnectPolicy {
    static let stableUptime: Duration = .seconds(60)
    private(set) var attempt = 0
    private var alerted: String?
    private var onlineSince: ContinuousClock.Instant?
    private var settled = false

    static func delay(attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }
        let base = min(60.0, pow(2.0, Double(attempt - 1)))
        return .seconds(base * Double.random(in: 1.0...1.25))
    }

    var nextDelay: Duration { Self.delay(attempt: attempt) }

    mutating func attemptStarted() { attempt += 1 }

    mutating func online(at now: ContinuousClock.Instant = .now) {
        onlineSince = now
        settled = false
    }

    mutating func observe(_ event: ConnectionSetup.Event) {
        if event == .settled { settled = true }
    }

    mutating func ended(at now: ContinuousClock.Instant = .now) {
        forgiveIfHealthy(now)
        onlineSince = nil
        settled = false
    }

    mutating func retryNow() { attempt = 0 }

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
