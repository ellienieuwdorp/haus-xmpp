import Foundation
import MessageStore

/// Only local authenticated state creates one. iOS separately enforces its Show Previews setting; the category never
/// opts into revealing hidden titles.
public struct PlannedNotification: Sendable, Equatable, CustomStringConvertible {
    public let identifier: String
    public let threadIdentifier: String
    public let categoryIdentifier: String
    public let title: String
    public let body: String
    /// Only the newest request of a run plays a sound.
    public let playsSound: Bool
    /// Nil for placeholders and retained ciphertext.
    public let destination: NotificationDestination?
    /// Nil with previews off: then no name or avatar reaches the system.
    public let communication: NotificationCommunication?
    public let reference: NotificationReference?
    public let badge: Int?

    public init(identifier: String, threadIdentifier: String, categoryIdentifier: String = NotificationIdentity.messageCategory,
                title: String, body: String, playsSound: Bool, destination: NotificationDestination?,
                communication: NotificationCommunication? = nil, reference: NotificationReference? = nil, badge: Int? = nil) {
        self.identifier = identifier; self.threadIdentifier = threadIdentifier; self.categoryIdentifier = categoryIdentifier
        self.title = title; self.body = body; self.playsSound = playsSound; self.destination = destination; self.communication = communication
        self.reference = reference; self.badge = badge
    }

    /// Opaque references only, never an address or body.
    public var userInfo: [String: [String: String]] {
        var info: [String: [String: String]] = [:]
        if let destination { info[NotificationDestination.userInfoKey] = destination.payload }
        if let reference { info[NotificationReference.userInfoKey] = reference.payload }
        return info
    }

    func withSound() -> PlannedNotification {
        PlannedNotification(identifier: identifier, threadIdentifier: threadIdentifier, categoryIdentifier: categoryIdentifier, title: title,
                            body: body, playsSound: true, destination: destination, communication: communication, reference: reference, badge: badge)
    }
    public var description: String { "PlannedNotification(<redacted>)" }
}

/// The people behind a communication notification. Local, authenticated state only; never serialized into
/// `userInfo`, gateway traffic or logs.
public struct NotificationCommunication: Sendable, Equatable, CustomStringConvertible {
    public struct Person: Sendable, Equatable {
        /// The bare JID.
        public let handle: String
        public let displayName: String
        /// A verified avatar hash, or a linked contact's photo.
        public let avatarHash: String?
        /// `CNContact.identifier`, only while the app can read it.
        public let contactIdentifier: String?
        public init(handle: String, displayName: String, avatarHash: String?, contactIdentifier: String? = nil) {
            self.handle = handle; self.displayName = displayName; self.avatarHash = avatarHash; self.contactIdentifier = contactIdentifier
        }
    }
    public let sender: Person
    /// `NotificationIdentity.thread`.
    public let conversationIdentifier: String
    public let account: Person
    /// Nil for a direct chat.
    public let groupName: String?
    public let groupAvatarHash: String?
    /// Never the sender or the account.
    public let otherRecipients: [Person]
    /// Without the plain body's "Bob: " prefix: the system already names the sender.
    public let body: String

    public init(sender: Person, conversationIdentifier: String, account: Person, groupName: String? = nil, groupAvatarHash: String? = nil,
                otherRecipients: [Person] = [], body: String) {
        self.sender = sender; self.conversationIdentifier = conversationIdentifier; self.account = account; self.groupName = groupName
        self.groupAvatarHash = groupAvatarHash; self.otherRecipients = otherRecipients; self.body = body
    }
    public var isGroup: Bool { groupName != nil }
    public var description: String { "NotificationCommunication(<redacted>)" }
}

/// `claimed` may be deleted once every post completed.
public struct NotificationPlan: Sendable, Equatable {
    public let requests: [PlannedNotification]
    public let claimed: [NotificationCandidateKey]
    /// A settled run without the summary removes a delivered one.
    public let summarizesDeferredChats: Bool
}

/// Pure: store snapshot in, requests out oldest first, so the newest is added last and sits on top.
public enum NotificationPlanner {
    /// Shown whenever a run cannot settle. Never carries message content.
    public static let fallbackBody = "You may have new messages"
    /// Retained ciphertext waiting for trust or keys.
    public static let reviewBody = "Sent an encrypted message. Open the chat to review."
    public static let unreadableBody = "Sent a message this device can't read"
    /// Every body when previews are off.
    public static let hiddenBody = "New message"

    /// A count only, so it is the same with previews off.
    public static func overflowBody(chats: Int) -> String {
        chats == 1 ? "New messages in 1 more chat" : "New messages in \(chats) more chats"
    }

    public static let hiddenReactionBody = "Reacted to your message"

    /// `accountID` names the deferred-chats summary's account; it defaults to the batch's. A nil `badge` leaves the
    /// icon badge as it is. Pass `playsSound: false` when the run already played its sound.
    public static func plan(_ batch: MessageNotification, accountID: String? = nil, badge: Int? = nil, playsSound: Bool = true) -> NotificationPlan {
        var requests: [PlannedNotification] = []
        // Chats beyond the cap are older than every selected message, so their summary goes first and never takes the
        // sound from a newer message. Settling without it would hide that those chats have news.
        let account = accountID ?? batch.candidates.first?.accountID ?? batch.reactions.first?.accountID
        var summarizes = false
        if batch.deferredChatCount > 0, let account, !account.isEmpty {
            let identifier = NotificationIdentity.overflow(accountID: account)
            requests.append(PlannedNotification(identifier: identifier, threadIdentifier: identifier,
                                                categoryIdentifier: NotificationIdentity.noticeCategory, title: "",
                                                body: overflowBody(chats: batch.deferredChatCount), playsSound: false,
                                                destination: nil, badge: badge))
            summarizes = true
        }
        let previews = batch.previewsEnabled
        var timed: [(at: Date, request: PlannedNotification)] = []
        // An unsent message is skipped; an "and N more" it carried moves to the chat's next shown message.
        var carried: [String: Int] = [:]
        for candidate in batch.candidates {
            guard let text = text(for: candidate) else {
                if candidate.earlierCount > 0 { carried[candidate.chatID, default: 0] += candidate.earlierCount }
                continue
            }
            let earlier = candidate.earlierCount + (carried.removeValue(forKey: candidate.chatID) ?? 0)
            let more = earlier > 0 ? "\nand \(earlier) more" : ""
            let body = (previews ? (candidate.isGroup ? senderName(candidate) + ": " + text : text) : hiddenBody) + more
            let destination: NotificationDestination?, reference: NotificationReference?
            // Only an authenticated message makes its sender a communication partner: the system must not learn an
            // unauthenticated sender for suggestions or priority.
            let authenticated: Bool
            switch candidate.content {
            case let .message(message):
                destination = NotificationDestination(accountID: candidate.accountID, messageID: message.id); reference = nil; authenticated = true
            case let .unreadable(messageID):
                destination = nil; reference = .placeholder(accountID: candidate.accountID, messageID: messageID); authenticated = false
            case .pendingEncrypted:
                destination = nil; reference = .retained(accountID: candidate.accountID); authenticated = false
            }
            let thread = NotificationIdentity.thread(accountID: candidate.accountID, chatID: candidate.chatID)
            let chatName = clean(displayName(candidate.chatID, title: candidate.chatTitle), limit: 80, maximumBytes: 320)
            timed.append((candidate.sentAt, PlannedNotification(
                identifier: identifier(for: candidate), threadIdentifier: thread,
                categoryIdentifier: destination == nil ? NotificationIdentity.noticeCategory : NotificationIdentity.messageCategory,
                title: previews ? chatName : "", body: body, playsSound: false, destination: destination,
                communication: previews && authenticated ? communication(accountID: candidate.accountID, thread: thread, chatName: chatName, chatAvatarHash: candidate.chatAvatarHash,
                                                        isGroup: candidate.isGroup, sender: NotificationParticipant(id: candidate.senderID, title: candidate.senderTitle,
                                                                                                                    avatarHash: candidate.senderAvatarHash,
                                                                                                                    contactIdentifier: candidate.senderContactIdentifier),
                                                        members: candidate.groupMembers, body: text + more) : nil,
                reference: reference, badge: badge)))
        }
        for reaction in batch.reactions {
            let thread = NotificationIdentity.thread(accountID: reaction.accountID, chatID: reaction.chatID)
            let chatName = clean(displayName(reaction.chatID, title: reaction.chatTitle), limit: 80, maximumBytes: 320)
            timed.append((reaction.reactedAt, PlannedNotification(
                identifier: NotificationIdentity.reaction(accountID: reaction.accountID, chatID: reaction.chatID, actorID: reaction.actor.id,
                                                          targetMessageID: reaction.target.id),
                threadIdentifier: thread, categoryIdentifier: NotificationIdentity.reactionCategory,
                title: previews ? chatName : "", body: previews ? reactionBody(reaction) : hiddenReactionBody, playsSound: false,
                destination: NotificationDestination(accountID: reaction.accountID, messageID: reaction.target.id, kind: .reaction),
                communication: previews ? communication(accountID: reaction.accountID, thread: thread, chatName: chatName, chatAvatarHash: reaction.chatAvatarHash,
                                                        isGroup: reaction.isGroup, sender: reaction.actor, members: reaction.groupMembers,
                                                        body: reactionBody(reaction, namingActor: false)) : nil,
                reference: .reaction(accountID: reaction.accountID, targetMessageID: reaction.target.id), badge: badge)))
        }
        requests += timed.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element.request)
        if playsSound, let newest = requests.popLast() { requests.append(newest.withSound()) }
        return NotificationPlan(requests: requests, claimed: batch.claimed, summarizesDeferredChats: summarizes)
    }

    // "Reacted 👍 to “Lunch?”", or "Bob reacted 👍 to “Lunch?”" in a room unless the system already names the actor.
    static func reactionBody(_ reaction: ReactionNotificationCandidate, namingActor: Bool = true) -> String {
        let emoji = clean(reaction.reactions.joined(), limit: 24, maximumBytes: 128)
        let text = clean(reaction.target.body, limit: 240)
        let object = text.isEmpty ? "your " + (reaction.target.attachment?.kindLabel.lowercased() ?? "message") : "“" + text + "”"
        let verb = "eacted \(emoji) to \(object)"
        guard reaction.isGroup, namingActor else { return "R" + verb }
        return clean(displayName(reaction.actor.id, title: reaction.actor.title), limit: 40, maximumBytes: 160) + " r" + verb
    }

    // A direct chat's sender is the chat itself, named like the title.
    private static func communication(accountID: String, thread: String, chatName: String, chatAvatarHash: String?, isGroup: Bool,
                                      sender: NotificationParticipant, members: [NotificationParticipant], body: String) -> NotificationCommunication {
        func person(_ participant: NotificationParticipant) -> NotificationCommunication.Person {
            .init(handle: participant.id, displayName: clean(displayName(participant.id, title: participant.title), limit: 40, maximumBytes: 160),
                  avatarHash: participant.avatarHash, contactIdentifier: participant.contactIdentifier)
        }
        let me = NotificationCommunication.Person(handle: accountID, displayName: displayName(accountID, title: nil), avatarHash: nil)
        guard isGroup else {
            return NotificationCommunication(sender: .init(handle: sender.id, displayName: chatName, avatarHash: sender.avatarHash ?? chatAvatarHash,
                                                           contactIdentifier: sender.contactIdentifier),
                                             conversationIdentifier: thread, account: me, body: body)
        }
        return NotificationCommunication(sender: person(sender), conversationIdentifier: thread, account: me, groupName: chatName,
                                         groupAvatarHash: chatAvatarHash,
                                         otherRecipients: members.filter { $0.id != sender.id && $0.id != accountID }.prefix(8).map(person), body: body)
    }

    /// Stable per message, so posting again replaces. Retained ciphertext has no message row yet, so its ciphertext
    /// key is digested instead.
    public static func identifier(for candidate: NotificationCandidate) -> String {
        identifier(accountID: candidate.accountID, key: candidate.key)
    }

    static func identifier(accountID: String, key: NotificationCandidateKey) -> String {
        switch key {
        case let .message(id): NotificationIdentity.message(accountID: accountID, messageID: id)
        case let .pending(sender, digest): NotificationIdentity.message(accountID: accountID, messageID: "pending\u{0}\(sender)\u{0}\(digest)")
        // Never posted under this identifier: a reaction request uses `NotificationIdentity.reaction`.
        case let .reaction(sequence): NotificationIdentity.message(accountID: accountID, messageID: "reaction\u{0}\(sequence)")
        }
    }

    // Nil for an unsent message: it is claimed, never shown.
    private static func text(for candidate: NotificationCandidate) -> String? {
        switch candidate.content {
        case let .message(message):
            guard !message.isRetracted else { return nil }
            let text = clean(message.body, limit: 240)
            return text.isEmpty ? (message.attachment?.kindLabel ?? hiddenBody) : text
        case .unreadable: return unreadableBody
        case .pendingEncrypted: return reviewBody
        }
    }

    private static func senderName(_ candidate: NotificationCandidate) -> String {
        clean(displayName(candidate.senderID, title: candidate.senderTitle), limit: 40, maximumBytes: 160)
    }

    // A title equal to the address falls back to the local part.
    static func displayName(_ address: String, title: String?) -> String {
        if let title, !title.isEmpty, title != address { return title }
        return address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address
    }

    static func clean(_ text: String, limit: Int, maximumBytes: Int = 1024) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
        let scalars = flattened.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
                && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
        }
        let value = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit || value.utf8.count > maximumBytes else { return value }
        var result = "", characters = 0, bytes = 0
        for character in value {
            let part = String(character)
            guard characters < limit, bytes + part.utf8.count <= maximumBytes - 3 else { break }
            result += part
            characters += 1
            bytes += part.utf8.count
        }
        return result + "…"
    }
}
