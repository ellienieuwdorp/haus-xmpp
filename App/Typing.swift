import Foundation
import XMPPProtocol

struct TypingTracker {
    // Senders refresh `composing` about every 10 s, so 15 s of silence means they stopped.
    static let composingLifetime: TimeInterval = 15
    static let settleLifetime: TimeInterval = 2

    private struct Key: Hashable { let chat: String; let participant: String }
    private var expiries: [Key: Date] = [:]
    private var settling: Set<Key> = []

    var typing: [String: [String]] {
        Dictionary(grouping: expiries.keys, by: \.chat).mapValues { $0.map(\.participant).sorted() }
    }
    var nextExpiry: Date? { expiries.values.min() }

    // `settles`: the state rode on a real message, so the indicator gives way to it rather than vanishing first.
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

    mutating func messageArrived(chat: String, participant: String, now: Date) { settle(Key(chat: chat, participant: participant), now: now) }

    private mutating func settle(_ key: Key, now: Date) {
        guard let expiry = expiries[key] else { return }
        expiries[key] = min(expiry, now.addingTimeInterval(Self.settleLifetime))
        settling.insert(key)
    }

    mutating func clear(chat: String) {
        for key in expiries.keys where key.chat == chat { expiries[key] = nil }
        settling = settling.filter { $0.chat != chat }
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

    static func description(_ participants: [String], isGroup: Bool = true) -> String {
        guard isGroup else { return "typing…" }
        let names = participants.map { ContactName.display(for: $0, title: nil) }
        if names.count > 3 { return "\(names.count) people are typing…" }
        return names.formatted(.list(type: .and)) + (names.count == 1 ? " is typing…" : " are typing…")
    }
}

struct TypingSender {
    static let pauseAfter: TimeInterval = 5
    static let composingInterval: TimeInterval = 10

    private(set) var sent: XMPPChatState.State?
    private var composingAt: Date?

    mutating func draftChanged(isEmpty: Bool, now: Date) -> XMPPChatState.State? {
        if isEmpty { return sent == .composing || sent == .paused ? record(.active) : nil }
        if sent == .composing, let composingAt, now.timeIntervalSince(composingAt) < Self.composingInterval { return nil }
        composingAt = now
        return record(.composing)
    }

    mutating func idle() -> XMPPChatState.State? { sent == .composing ? record(.paused) : nil }

    mutating func left() -> XMPPChatState.State? {
        defer { self = TypingSender() }
        return sent == .composing || sent == .paused ? .inactive : nil
    }

    private mutating func record(_ state: XMPPChatState.State) -> XMPPChatState.State {
        sent = state
        return state
    }
}
