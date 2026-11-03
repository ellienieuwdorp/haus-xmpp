import Foundation
import CryptoKit

/// Notification identifiers shared by the extension, which posts, and the app, which removes. Every value is a digest
/// of account-scoped local identifiers: no address, name or body reaches the OS store.
public enum NotificationIdentity {
    public static func thread(accountID: String, chatID: String) -> String {
        hex(accountID + "\u{0}" + chatID)
    }

    /// Posting again replaces, never duplicates.
    public static func message(accountID: String, messageID: String) -> String {
        "m-" + hex("xmpp-notification-message-v1\u{0}" + accountID + "\u{0}" + messageID)
    }

    /// Fixed, so repeated failures replace one another and a later successful run can remove it.
    public static func fallback(accountID: String) -> String {
        "f-" + hex("xmpp-notification-fallback-v1\u{0}" + accountID)
    }

    /// The one summary for chats a run had no room for; a later run replaces or removes it.
    public static func overflow(accountID: String) -> String {
        "o-" + hex("xmpp-notification-overflow-v1\u{0}" + accountID)
    }

    /// One per actor and reacted-to message, so a replacement reaction replaces the delivered notification.
    public static func reaction(accountID: String, chatID: String, actorID: String, targetMessageID: String) -> String {
        "r-" + hex("xmpp-notification-reaction-v1\u{0}" + accountID + "\u{0}" + chatID + "\u{0}" + actorID + "\u{0}" + targetMessageID)
    }

    /// One per chat, so a later failure replaces it.
    public static func replyFailure(accountID: String, chatID: String) -> String {
        "e-" + hex("xmpp-notification-reply-failure-v1\u{0}" + accountID + "\u{0}" + chatID)
    }

    /// No actions: there is no incoming message to reply to or mark as read.
    public static let reactionCategory = "reaction"
    /// One authenticated incoming message; the only category with Reply and Mark as Read.
    public static let messageCategory = "message"
    /// Pending ciphertext, unreadable placeholders, the deferred-chats summary and failed replies. No actions.
    public static let noticeCategory = "notice"
    public static func isMessageRun(category: String) -> Bool { category == messageCategory || category == noticeCategory }
    /// Never carries message content.
    public static let fallbackCategory = "fallback"

    private static func hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
