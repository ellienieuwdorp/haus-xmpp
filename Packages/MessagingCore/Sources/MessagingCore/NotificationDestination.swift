import Foundation
import CryptoKit
import MessageStore

/// Local notification navigation contains no address, URL, sender name or message body.
/// This is a lookup hint, never authorization to load another account or connect a server.
public struct NotificationDestination: Sendable, Equatable, CustomStringConvertible {
    public static let userInfoKey = "xmpp_local_destination"
    /// What `messageID` names: an incoming message (every message notification), or this account's own message that
    /// someone reacted to (plan D8). Only `.message` stands for something unread; read-state cleanup and message
    /// actions ignore `.reaction`.
    public enum Kind: String, Sendable { case message, reaction }
    public let accountScope: String
    public let messageID: String
    public let kind: Kind

    public init?(accountID: String, messageID: String, kind: Kind = .message) {
        guard !accountID.isEmpty, UUID(uuidString: messageID) != nil else { return nil }
        self.accountScope = Self.scope(for: accountID)
        self.messageID = messageID
        self.kind = kind
    }

    /// The message payload is unchanged from the single-preview design; a reaction adds `kind`.
    public init?(payload: [String: String]) {
        let kind: Kind
        switch Set(payload.keys) {
        case ["version", "account", "message"]: kind = .message
        case ["version", "account", "message", "kind"] where payload["kind"] == Kind.reaction.rawValue: kind = .reaction
        default: return nil
        }
        guard payload["version"] == "1",
              let account = payload["account"], account.utf8.count == 64,
              account.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let message = payload["message"], message.utf8.count == 36, UUID(uuidString: message) != nil else { return nil }
        accountScope = account; messageID = message; self.kind = kind
    }

    public var payload: [String: String] {
        var payload = ["version": "1", "account": accountScope, "message": messageID]
        if kind == .reaction { payload["kind"] = kind.rawValue }
        return payload
    }
    public var description: String { "NotificationDestination(<redacted>)" }

    /// The stored message a tap may open the chat of: an incoming encrypted message, or for a reaction this account's
    /// own message in the same account. Never another account's.
    public func resolve(accountID: String, active: Bool, store: MessageStore) async throws -> StoredMessage? {
        guard active, !accountID.isEmpty, Self.scope(for: accountID) == accountScope,
              let message = try await store.message(accountID: accountID, messageID: messageID),
              message.accountID == accountID else { return nil }
        switch kind {
        case .message:
            guard !message.isOutgoing, message.senderID != accountID,
                  ["legacy", "modern"].contains(message.encryptionProfile ?? "") else { return nil }
        case .reaction:
            guard message.isOutgoing || message.senderID == accountID else { return nil }
        }
        return message
    }

    /// Whether this destination was issued for `accountID`; says nothing about the message itself.
    public func belongs(to accountID: String) -> Bool { !accountID.isEmpty && Self.scope(for: accountID) == accountScope }

    static func scope(for account: String) -> String {
        SHA256.hash(data: Data(("xmpp-notification-account-v1\u{0}" + account).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Cleanup-only marker for a notification that has no tap destination (plan D5): an unreadable placeholder, which
/// is named by its opaque `unreadable-<digest>` row ID, retained ciphertext, which carries no ID at all (cleanup
/// recomputes the identifiers of what is still retained), or a reaction to one of this account's messages (plan D8),
/// named by the reacted-to message's local UUID. It never routes a tap and holds no address or content.
public struct NotificationReference: Sendable, Equatable, CustomStringConvertible {
    public static let userInfoKey = "xmpp_local_reference"
    public enum Kind: String, Sendable { case placeholder, retained, reaction }
    public let accountScope: String
    public let kind: Kind
    /// The placeholder's message row ID, or a reaction's target message ID; nil for retained ciphertext.
    public let messageID: String?

    public static func placeholder(accountID: String, messageID: String) -> NotificationReference? {
        guard !accountID.isEmpty, isPlaceholderID(messageID) else { return nil }
        return NotificationReference(accountScope: NotificationDestination.scope(for: accountID), kind: .placeholder, messageID: messageID)
    }

    public static func reaction(accountID: String, targetMessageID: String) -> NotificationReference? {
        guard !accountID.isEmpty, UUID(uuidString: targetMessageID) != nil else { return nil }
        return NotificationReference(accountScope: NotificationDestination.scope(for: accountID), kind: .reaction, messageID: targetMessageID)
    }

    public static func retained(accountID: String) -> NotificationReference? {
        guard !accountID.isEmpty else { return nil }
        return NotificationReference(accountScope: NotificationDestination.scope(for: accountID), kind: .retained, messageID: nil)
    }

    private init(accountScope: String, kind: Kind, messageID: String?) {
        self.accountScope = accountScope; self.kind = kind; self.messageID = messageID
    }

    public init?(payload: [String: String]) {
        guard payload["version"] == "1", let account = payload["account"], account.utf8.count == 64,
              account.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let kind = payload["kind"].flatMap(Kind.init(rawValue:)) else { return nil }
        switch kind {
        case .placeholder:
            guard Set(payload.keys) == ["version", "account", "kind", "message"], let message = payload["message"],
                  Self.isPlaceholderID(message) else { return nil }
            messageID = message
        case .reaction:
            guard Set(payload.keys) == ["version", "account", "kind", "message"], let message = payload["message"],
                  message.utf8.count == 36, UUID(uuidString: message) != nil else { return nil }
            messageID = message
        case .retained:
            guard Set(payload.keys) == ["version", "account", "kind"] else { return nil }
            messageID = nil
        }
        accountScope = account; self.kind = kind
    }

    public var payload: [String: String] {
        var payload = ["version": "1", "account": accountScope, "kind": kind.rawValue]
        if let messageID { payload["message"] = messageID }
        return payload
    }

    public func belongs(to accountID: String) -> Bool { !accountID.isEmpty && NotificationDestination.scope(for: accountID) == accountScope }
    public var description: String { "NotificationReference(<redacted>)" }

    /// `unreadable-` and 64 lowercase hex digits: the store's placeholder ID, a digest that names no address.
    private static func isPlaceholderID(_ id: String) -> Bool {
        let prefix = "unreadable-"
        guard id.hasPrefix(prefix) else { return false }
        let hex = id.utf8.dropFirst(prefix.utf8.count)
        return hex.count == 64 && hex.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
