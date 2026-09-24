import Foundation
import XMPPProtocol

/// Who is typing where, from XEP-0085 states. In memory only: never stored, never a message.
/// A participant is the peer's address in a direct chat, a member's address (or nickname) in a group.
struct TypingTracker {
    /// Senders refresh `composing` about every 10 s (as this app does), so 15 s of silence means they stopped.
    static let composingLifetime: TimeInterval = 15
    /// A stop that rode on a message waits for that message to reach the screen, at most this long.
    static let settleLifetime: TimeInterval = 2

    private struct Key: Hashable { let chat: String; let participant: String }
    private var expiries: [Key: Date] = [:]
    /// Stopped, but still shown until the message that stopped it is loaded; `flushSettled` drops them.
    private var settling: Set<Key> = []

    /// Chat → participants typing there, sorted.
    var typing: [String: [String]] {
        Dictionary(grouping: expiries.keys, by: \.chat).mapValues { $0.map(\.participant).sorted() }
    }
    var nextExpiry: Date? { expiries.values.min() }

    /// `settles`: the state rode on a real message, so the indicator gives way to it rather than vanishing first.
    mutating func apply(_ state: XMPPChatState.State, chat: String, participant: String, settles: Bool = false, now: Date) {
        let key = Key(chat: chat, participant: participant)
        if state == .composing {
            expiries[key] = now.addingTimeInterval(Self.composingLifetime)
            settling.remove(key)
        } else if settles {
            settle(key, now: now)
        } else {
            expiries[key] = nil
            settling.remove(key)
        }
    }

    /// A real message from this participant: they have stopped typing it.
    mutating func messageArrived(chat: String, participant: String, now: Date) { settle(Key(chat: chat, participant: participant), now: now) }

    private mutating func settle(_ key: Key, now: Date) {
        guard let expiry = expiries[key] else { return }
        expiries[key] = min(expiry, now.addingTimeInterval(Self.settleLifetime))
        settling.insert(key)
    }

    mutating func flushSettled() {
        for key in settling { expiries[key] = nil }
        settling = []
    }

    mutating func expire(now: Date) {
        for (key, expiry) in expiries where expiry <= now {
            expiries[key] = nil
            settling.remove(key)
        }
    }

    /// "Maya is typing…", "Maya and Sam are typing…"; the list row of a direct chat says only "typing…".
    static func description(_ participants: [String], isGroup: Bool = true) -> String {
        guard isGroup else { return "typing…" }
        let names = participants.map { AppModel.displayName(for: $0, title: nil) }
        if names.count > 3 { return "\(names.count) people are typing…" }
        return names.formatted(.list(type: .and)) + (names.count == 1 ? " is typing…" : " are typing…")
    }
}

/// What this device last told the open chat's peer, and so what the composer's next change should send.
struct TypingSender {
    /// Silence in the composer after which the peer hears `paused`.
    static let pauseAfter: TimeInterval = 5
    /// While typing continues, `composing` is repeated no more often than this.
    static let composingInterval: TimeInterval = 10

    private(set) var sent: XMPPChatState.State?
    private var composingAt: Date?

    mutating func draftChanged(isEmpty: Bool, now: Date) -> XMPPChatState.State? {
        if isEmpty { return sent == .composing || sent == .paused ? record(.active) : nil }
        if sent == .composing, let composingAt, now.timeIntervalSince(composingAt) < Self.composingInterval { return nil }
        composingAt = now
        return record(.composing)
    }

    /// The composer went quiet for `pauseAfter`.
    mutating func idle() -> XMPPChatState.State? { sent == .composing ? record(.paused) : nil }

    /// The chat is closing; a peer who saw us typing hears that we left.
    mutating func left() -> XMPPChatState.State? {
        defer { self = TypingSender() }
        return sent == .composing || sent == .paused ? .inactive : nil
    }

    private mutating func record(_ state: XMPPChatState.State) -> XMPPChatState.State {
        sent = state
        return state
    }
}
