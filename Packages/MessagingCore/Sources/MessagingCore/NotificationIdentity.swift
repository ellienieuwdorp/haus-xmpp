import Foundation
import CryptoKit

/// Stable, opaque identifiers shared by the extension (which posts notifications) and the app
/// (which removes them when a chat is read, muted or a message is retracted). Every value is a
/// digest of account-scoped local identifiers: no address, name or body reaches the OS store.
public enum NotificationIdentity {
    /// Groups a conversation's notifications. Unchanged from the single-preview design.
    public static func thread(accountID: String, chatID: String) -> String {
        hex(accountID + "\u{0}" + chatID)
    }

    /// One local request per stored incoming message. Posting again replaces, never duplicates.
    public static func message(accountID: String, messageID: String) -> String {
        "m-" + hex("xmpp-notification-message-v1\u{0}" + accountID + "\u{0}" + messageID)
    }

    /// The fixed request identifier for the extension's "could not check" fallback, so repeated
    /// failures replace one another and a later successful run can remove it.
    public static func fallback(accountID: String) -> String {
        "f-" + hex("xmpp-notification-fallback-v1\u{0}" + accountID)
    }

    /// The one summary request for chats a run had no room for (plan D4 cap). A later run replaces it with its own
    /// count, or removes it once nothing is deferred any more.
    public static func overflow(accountID: String) -> String {
        "o-" + hex("xmpp-notification-overflow-v1\u{0}" + accountID)
    }

    /// One request per person and reacted-to message of this account (plan D8): a replacement reaction reposts the same
    /// identifier, which replaces the delivered notification, and a withdrawn one is removed by it.
    public static func reaction(accountID: String, chatID: String, actorID: String, targetMessageID: String) -> String {
        "r-" + hex("xmpp-notification-reaction-v1\u{0}" + accountID + "\u{0}" + chatID + "\u{0}" + actorID + "\u{0}" + targetMessageID)
    }

    /// The "Couldn't send your reply" request of one chat (stream E): a later failure in the same chat replaces it,
    /// and opening the chat removes it with the rest of its thread.
    public static func replyFailure(accountID: String, chatID: String) -> String {
        "e-" + hex("xmpp-notification-reply-failure-v1\u{0}" + accountID + "\u{0}" + chatID)
    }

    /// Category of a reaction to one of this account's messages (plan D8). It has no message actions: there is no
    /// incoming message to reply to or mark as read, and a tap opens the reacted-to message's chat.
    public static let reactionCategory = "reaction"
    /// Category of every notification that names one authenticated incoming message (it carries a
    /// `NotificationDestination`). Only this category offers Reply and Mark as Read.
    public static let messageCategory = "message"
    /// Category of a notification that cannot be answered from the notification itself: retained ciphertext waiting for
    /// review, an unreadable placeholder, the deferred-chats summary and a failed reply. It has no actions.
    public static let noticeCategory = "notice"
    /// The categories whose requests belong to a message run (everything but the fallback), for cleanup.
    public static func isMessageRun(category: String) -> Bool { category == messageCategory || category == noticeCategory }
    /// Category of the generic fallback; never carries message content.
    public static let fallbackCategory = "fallback"

    private static func hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
