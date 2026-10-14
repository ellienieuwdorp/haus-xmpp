import Foundation

/// Identifies one row a notification run may delete once its request has been posted.
public enum NotificationCandidateKey: Hashable, Sendable {
    /// An incoming message row: authenticated content or an unreadable placeholder.
    case message(String)
    /// Retained ciphertext still waiting for trust or keys; it has no message row yet.
    case pending(sender: String, digest: String)
    /// Another person's authenticated reaction to one of this account's messages. The sequence names exactly
    /// the version that was claimed: a replacement that arrives later is a new row and stays for the next run.
    case reaction(sequence: Int)
}

/// Someone this account talks to, as a notification may name them. Local, authenticated state only.
public struct NotificationParticipant: Sendable, Equatable, CustomStringConvertible {
    /// The bare JID.
    public let id: String
    /// The stored title of their direct chat, when there is one.
    public let title: String?
    /// Their direct chat's verified avatar hash, when one is cached.
    public let avatarHash: String?
    public init(id: String, title: String?, avatarHash: String?) { self.id = id; self.title = title; self.avatarHash = avatarHash }
    public var description: String { "NotificationParticipant(<redacted>)" }
}

/// Another person reacted to one of this account's messages, through the authenticated (SCE) path only.
/// One per actor and target message; never serialize this into gateway traffic or logs.
public struct ReactionNotificationCandidate: Sendable, Equatable, CustomStringConvertible {
    public let key: NotificationCandidateKey
    public let accountID: String
    public let chatID: String
    public let chatTitle: String?
    public let chatAvatarHash: String?
    public let actor: NotificationParticipant
    /// A room reaction: the chat is the room and the actor is a member.
    public let isGroup: Bool
    /// The reacted-to message of this account, projected through its corrections.
    public let target: StoredMessage
    /// The emoji this actor added and still has on the target, in their stored (sorted) order.
    public let reactions: [String]
    public let reactedAt: Date
    /// Other known room members, for a group's communication notification; empty for a direct chat.
    public let groupMembers: [NotificationParticipant]

    public init(key: NotificationCandidateKey, accountID: String, chatID: String, chatTitle: String?, chatAvatarHash: String? = nil,
                actor: NotificationParticipant, isGroup: Bool, target: StoredMessage, reactions: [String], reactedAt: Date,
                groupMembers: [NotificationParticipant] = []) {
        self.key = key; self.accountID = accountID; self.chatID = chatID; self.chatTitle = chatTitle; self.chatAvatarHash = chatAvatarHash
        self.actor = actor; self.isGroup = isGroup; self.target = target; self.reactions = reactions; self.reactedAt = reactedAt
        self.groupMembers = groupMembers
    }
    public var description: String { "ReactionNotificationCandidate(<redacted>)" }
}

/// A delivered reaction notification is still current while its actor's latest reaction on the target is not empty.
public struct LiveReactionNotification: Sendable, Hashable {
    public let chatID: String
    public let actorID: String
    public let targetMessageID: String
    public init(chatID: String, actorID: String, targetMessageID: String) {
        self.chatID = chatID; self.actorID = actorID; self.targetMessageID = targetMessageID
    }
}

/// Where an incoming ciphertext that is being retained would appear, so that waiting for trust or
/// keys can still alert. Never carries content: the ciphertext is unreadable until then.
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
    /// The sender's direct chat's verified avatar hash; for a direct chat it is the chat's own.
    public let senderAvatarHash: String?
    /// Other known room members, for a group's communication notification; empty for a direct chat.
    public let groupMembers: [NotificationParticipant]
    /// A room message: the chat is the room and the author is a member.
    public let isGroup: Bool
    public let sentAt: Date
    public let content: Content
    /// Older candidates of this chat that this run represents with an "and N more" line instead of their own request.
    /// Set on the chat's oldest selected candidate only.
    public let earlierCount: Int

    public init(key: NotificationCandidateKey, accountID: String, chatID: String, chatTitle: String?, chatAvatarHash: String? = nil,
                senderID: String, senderTitle: String? = nil, senderAvatarHash: String? = nil, isGroup: Bool, sentAt: Date, content: Content,
                earlierCount: Int = 0, groupMembers: [NotificationParticipant] = []) {
        self.key = key; self.accountID = accountID; self.chatID = chatID; self.chatTitle = chatTitle; self.chatAvatarHash = chatAvatarHash
        self.senderID = senderID; self.senderTitle = senderTitle; self.senderAvatarHash = senderAvatarHash ?? (isGroup ? nil : chatAvatarHash)
        self.isGroup = isGroup; self.sentAt = sentAt; self.content = content; self.earlierCount = earlierCount; self.groupMembers = groupMembers
    }
    public var description: String { "NotificationCandidate(<redacted>)" }

    /// A message its sender has since unsent: claimed, never shown.
    public var isRetracted: Bool { if case let .message(message) = content { message.isRetracted } else { false } }

    func withEarlierCount(_ count: Int) -> NotificationCandidate {
        NotificationCandidate(key: key, accountID: accountID, chatID: chatID, chatTitle: chatTitle, chatAvatarHash: chatAvatarHash,
                              senderID: senderID, senderTitle: senderTitle, senderAvatarHash: senderAvatarHash, isGroup: isGroup, sentAt: sentAt,
                              content: content, earlierCount: count, groupMembers: groupMembers)
    }
}

/// A bounded, per-message claim: at most `perChat` newest candidates per chat and `total` overall,
/// oldest first. Nothing is deleted by reading it; the run deletes `claimed` after its posts completed.
public struct MessageNotification: Sendable, Equatable, CustomStringConvertible {
    /// Selected candidates, oldest first. The store leaves out retracted messages (it claims them silently); the
    /// planner still skips any it is given.
    public let candidates: [NotificationCandidate]
    /// Every row this batch represents: the selected ones, silently claimed retracted ones, and the older ones folded
    /// into "and N more".
    public let claimed: [NotificationCandidateKey]
    /// Candidates of chats that got no request because the total cap was reached; left for a later run.
    public let deferredCount: Int
    /// The chats those deferred candidates belong to. Nonzero means the run must still show something for them.
    public let deferredChatCount: Int
    public let previewsEnabled: Bool
    /// Others' reactions to this account's messages, oldest first, at most `MessageStore.reactionNotificationsPerRun`.
    /// Their keys are in `claimed`, as are older reaction rows the run drops without a request.
    public let reactions: [ReactionNotificationCandidate]

    public init(candidates: [NotificationCandidate], claimed: [NotificationCandidateKey], deferredCount: Int = 0,
                deferredChatCount: Int = 0, previewsEnabled: Bool, reactions: [ReactionNotificationCandidate] = []) {
        self.candidates = candidates; self.claimed = claimed; self.deferredCount = deferredCount
        self.deferredChatCount = deferredChatCount; self.previewsEnabled = previewsEnabled; self.reactions = reactions
    }
    public var description: String { "MessageNotification(<redacted>)" }
}
