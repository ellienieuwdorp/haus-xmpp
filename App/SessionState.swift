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

    /// Under the Chats title; empty when there is nothing to say.
    var chatsSubtitle: String {
        switch self {
        case .ready: ""
        case .offline: "Offline"
        case .connecting: "Connecting…"
        case .connected: "Setting up…"
        case .needsAttention: "Encryption needs attention"
        }
    }
}
