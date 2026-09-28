import Foundation

/// Identifies one row a notification run may delete once its request has been posted.
public enum NotificationCandidateKey: Hashable, Sendable {
    /// An incoming message row: authenticated content or an unreadable placeholder.
    case message(String)
    /// Retained ciphertext still waiting for trust or keys; it has no message row yet.
    case pending(sender: String, digest: String)
}

/// Where an incoming ciphertext that is being retained would appear, so that waiting for trust or
/// keys can still alert (plan D5). Never carries content: the ciphertext is unreadable until then.
public struct PendingNotificationContext: Sendable, Equatable {
    public let chatID: String
    public let sentAt: Date
    public init(chatID: String, sentAt: Date) { self.chatID = chatID; self.sentAt = sentAt }
}

/// One claimed candidate with the local, authenticated state needed to present it.
/// Never serialize this into gateway traffic or logs.
public struct NotificationCandidate: Sendable, Equatable, CustomStringConvertible {
    public enum Content: Sendable, Equatable {
        /// Authenticated content, already projected through the sender's corrections.
        case message(StoredMessage)
        /// A stored placeholder for an incoming message this device cannot read.
        case unreadable(messageID: String)
        /// Retained ciphertext waiting for a trust decision or the sender's keys.
        case pendingEncrypted
    }
    public let key: NotificationCandidateKey
    public let accountID: String
    public let chatID: String
    public let chatTitle: String?
    /// The chat's verified avatar hash, for the extension to find the cached file.
    public let chatAvatarHash: String?
    public let senderID: String
    /// The stored title of the sender's own direct chat, when there is one; groups prefix the body with it.
    public let senderTitle: String?
    /// A room message: the chat is the room and the author is a member.
    public let isGroup: Bool
    public let sentAt: Date
    public let content: Content
    /// Older candidates of this chat that this run represents with an "and N more" line instead of their own request.
    /// Set on the chat's oldest selected candidate only.
    public let earlierCount: Int

    public init(key: NotificationCandidateKey, accountID: String, chatID: String, chatTitle: String?, chatAvatarHash: String? = nil,
                senderID: String, senderTitle: String? = nil, isGroup: Bool, sentAt: Date, content: Content, earlierCount: Int = 0) {
        self.key = key; self.accountID = accountID; self.chatID = chatID; self.chatTitle = chatTitle; self.chatAvatarHash = chatAvatarHash
        self.senderID = senderID; self.senderTitle = senderTitle; self.isGroup = isGroup; self.sentAt = sentAt
        self.content = content; self.earlierCount = earlierCount
    }
    public var description: String { "NotificationCandidate(<redacted>)" }
}

/// A bounded, per-message claim (plan D4): at most `perChat` newest candidates per chat and `total` overall,
/// oldest first. Nothing is deleted by reading it; the run deletes `claimed` after its posts completed.
public struct MessageNotification: Sendable, Equatable, CustomStringConvertible {
    /// Selected candidates, oldest first. Includes retracted messages, which the planner skips but still claims.
    public let candidates: [NotificationCandidate]
    /// Every row this batch represents: the selected ones and the older ones folded into "and N more".
    public let claimed: [NotificationCandidateKey]
    /// Candidates of chats that got no request because the total cap was reached; left for a later run.
    public let deferredCount: Int
    public let previewsEnabled: Bool

    public init(candidates: [NotificationCandidate], claimed: [NotificationCandidateKey], deferredCount: Int = 0, previewsEnabled: Bool) {
        self.candidates = candidates; self.claimed = claimed; self.deferredCount = deferredCount; self.previewsEnabled = previewsEnabled
    }
    public var description: String { "MessageNotification(<redacted>)" }
}
