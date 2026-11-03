import Foundation

/// XEP-0085 chat state. Never message content: it travels unencrypted on the outer stanza, as Conversations sends it,
/// and is never stored, acknowledged or replay-checked.
public struct XMPPChatState: Sendable, Equatable {
    public enum State: String, Sendable, Equatable, CaseIterable { case active, composing, paused, inactive, gone }
    public static let namespace = "http://jabber.org/protocol/chatstates"

    /// The peer's bare address, or the room's.
    public let chat: String
    /// Group only: the occupant's real address when the room exposed it, otherwise its nickname.
    public let participant: String?
    public let state: State
    /// Rode on a message with content rather than a bare state stanza.
    public let ridesOnMessage: Bool
    public init(chat: String, participant: String? = nil, state: State, ridesOnMessage: Bool = false) {
        self.chat = chat; self.participant = participant; self.state = state; self.ridesOnMessage = ridesOnMessage
    }

    // None or several (ambiguous) give nil.
    static func state(of node: XMLNode) -> State? {
        let states = node.children.filter { $0.namespace == namespace }
        guard states.count == 1, states[0].children.isEmpty else { return nil }
        return State(rawValue: states[0].name)
    }

    /// `no-store` keeps it out of archives, so offline catch-up never replays typing.
    public static func xml(_ state: State, to: String, id: String, groupchat: Bool = false) throws -> String {
        guard MessageContent.validAddress(to), MessageContent.validIdentifier(id) else { throw XMPPClientError.invalidConfiguration }
        return "<message to='\(xmlEscaped(to))' type='\(groupchat ? "groupchat" : "chat")' id='\(xmlEscaped(id))'><\(state.rawValue) xmlns='\(namespace)'/><no-store xmlns='urn:xmpp:hints'/></message>"
    }
}
