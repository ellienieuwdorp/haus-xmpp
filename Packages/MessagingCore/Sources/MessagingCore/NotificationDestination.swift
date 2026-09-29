import Foundation
import CryptoKit
import MessageStore

/// Local notification navigation contains no address, URL, sender name or message body.
/// This is a lookup hint, never authorization to load another account or connect a server.
public struct NotificationDestination: Sendable, Equatable, CustomStringConvertible {
    public static let userInfoKey = "xmpp_local_destination"
    public let accountScope: String
    public let messageID: String

    public init?(accountID: String, messageID: String) {
        guard !accountID.isEmpty, UUID(uuidString: messageID) != nil else { return nil }
        self.accountScope = Self.scope(for: accountID)
        self.messageID = messageID
    }

    public init?(payload: [String: String]) {
        guard Set(payload.keys) == ["version", "account", "message"], payload["version"] == "1",
              let account = payload["account"], account.utf8.count == 64,
              account.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let message = payload["message"], message.utf8.count == 36, UUID(uuidString: message) != nil else { return nil }
        accountScope = account; messageID = message
    }

    public var payload: [String: String] { ["version": "1", "account": accountScope, "message": messageID] }
    public var description: String { "NotificationDestination(<redacted>)" }

    public func resolve(accountID: String, store: MessageStore) async throws -> StoredMessage? {
        guard !accountID.isEmpty, Self.scope(for: accountID) == accountScope,
              let message = try await store.message(accountID: accountID, messageID: messageID),
              message.accountID == accountID, !message.isOutgoing, message.senderID != accountID,
              ["legacy", "modern"].contains(message.encryptionProfile ?? "") else { return nil }
        return message
    }

    private static func scope(for account: String) -> String {
        SHA256.hash(data: Data(("xmpp-notification-account-v1\u{0}" + account).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
