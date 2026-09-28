import Foundation
import MessageStore

/// One local notification request, ready for `NotificationPosting`. Only local authenticated state creates one.
/// iOS separately enforces its Show Previews setting; the category never opts into revealing hidden titles.
public struct PlannedNotification: Sendable, Equatable, CustomStringConvertible {
    public let identifier: String
    public let threadIdentifier: String
    public let categoryIdentifier: String
    public let title: String
    public let body: String
    /// Only the newest request of a run plays a sound.
    public let playsSound: Bool
    /// Tap routing, unchanged from the single-preview design; nil for placeholders and retained ciphertext.
    public let destination: NotificationDestination?
    /// The chat's verified avatar hash, attached only when previews are shown.
    public let avatarHash: String?
    /// Lets cleanup find placeholder and retained-ciphertext notifications, which have no destination (plan D5).
    public let reference: NotificationReference?

    public init(identifier: String, threadIdentifier: String, categoryIdentifier: String = NotificationIdentity.messageCategory,
                title: String, body: String, playsSound: Bool, destination: NotificationDestination?, avatarHash: String?,
                reference: NotificationReference? = nil) {
        self.identifier = identifier; self.threadIdentifier = threadIdentifier; self.categoryIdentifier = categoryIdentifier
        self.title = title; self.body = body; self.playsSound = playsSound; self.destination = destination; self.avatarHash = avatarHash
        self.reference = reference
    }

    /// The `userInfo` payload: the opaque destination or cleanup reference only, never an address or body.
    public var userInfo: [String: [String: String]] {
        var info: [String: [String: String]] = [:]
        if let destination { info[NotificationDestination.userInfoKey] = destination.payload }
        if let reference { info[NotificationReference.userInfoKey] = reference.payload }
        return info
    }

    func withSound() -> PlannedNotification {
        PlannedNotification(identifier: identifier, threadIdentifier: threadIdentifier, categoryIdentifier: categoryIdentifier, title: title,
                            body: body, playsSound: true, destination: destination, avatarHash: avatarHash, reference: reference)
    }
    public var description: String { "PlannedNotification(<redacted>)" }
}

/// What a settled run posts, and the candidate rows it may delete once every post completed.
public struct NotificationPlan: Sendable, Equatable {
    public let requests: [PlannedNotification]
    public let claimed: [NotificationCandidateKey]
    /// True when `requests` includes the summary for chats beyond the run's cap; a settled run without one removes a
    /// delivered summary, whose chats have since been posted or dismissed.
    public let summarizesDeferredChats: Bool
}

/// Pure: store snapshot in, ordered requests out (plan D1, D3–D5). Oldest first, so the newest is added last and sits on top.
public enum NotificationPlanner {
    /// The visible alert whenever a run cannot settle (plan D2). It never carries message content.
    public static let fallbackBody = "You may have new messages"
    /// Retained ciphertext waiting for trust or keys: the wording plan D5 fixes. The app's chat list says "Encrypted
    /// message needs attention" for the same state; the two are not the same string.
    public static let reviewBody = "Sent an encrypted message. Open the chat to review."
    /// An incoming placeholder this device cannot read (plan D5).
    public static let unreadableBody = "Sent a message this device can't read"
    /// Every body when previews are off.
    public static let hiddenBody = "New message"

    /// The summary for chats a run had no room for (plan D4): a count only, so it is the same with previews off.
    public static func overflowBody(chats: Int) -> String {
        chats == 1 ? "New messages in 1 more chat" : "New messages in \(chats) more chats"
    }

    /// `accountID` names the account for the deferred-chats summary; it defaults to the batch's own candidates.
    public static func plan(_ batch: MessageNotification, accountID: String? = nil) -> NotificationPlan {
        var requests: [PlannedNotification] = []
        // Chats beyond the cap are older than every selected message, so their summary goes first and never takes the
        // sound from a newer message. Settling without it would hide that those chats have news (plan D2).
        let account = accountID ?? batch.candidates.first?.accountID
        var summarizes = false
        if batch.deferredChatCount > 0, let account, !account.isEmpty {
            let identifier = NotificationIdentity.overflow(accountID: account)
            requests.append(PlannedNotification(identifier: identifier, threadIdentifier: identifier, title: "",
                                                body: overflowBody(chats: batch.deferredChatCount), playsSound: false,
                                                destination: nil, avatarHash: nil))
            summarizes = true
        }
        // An unsent message is skipped; an "and N more" it carried moves to the chat's next shown message.
        var carried: [String: Int] = [:]
        for candidate in batch.candidates {
            guard let text = text(for: candidate) else {
                if candidate.earlierCount > 0 { carried[candidate.chatID, default: 0] += candidate.earlierCount }
                continue
            }
            let previews = batch.previewsEnabled
            let earlier = candidate.earlierCount + (carried.removeValue(forKey: candidate.chatID) ?? 0)
            var body = previews ? (candidate.isGroup ? senderName(candidate) + ": " + text : text) : hiddenBody
            if earlier > 0 { body += "\nand \(earlier) more" }
            let destination: NotificationDestination?, reference: NotificationReference?
            switch candidate.content {
            case let .message(message):
                destination = NotificationDestination(accountID: candidate.accountID, messageID: message.id); reference = nil
            case let .unreadable(messageID):
                destination = nil; reference = .placeholder(accountID: candidate.accountID, messageID: messageID)
            case .pendingEncrypted:
                destination = nil; reference = .retained(accountID: candidate.accountID)
            }
            requests.append(PlannedNotification(
                identifier: identifier(for: candidate),
                threadIdentifier: NotificationIdentity.thread(accountID: candidate.accountID, chatID: candidate.chatID),
                title: previews ? clean(displayName(candidate.chatID, title: candidate.chatTitle), limit: 80, maximumBytes: 320) : "",
                body: body, playsSound: false, destination: destination,
                avatarHash: previews ? candidate.chatAvatarHash : nil, reference: reference))
        }
        if let newest = requests.popLast() { requests.append(newest.withSound()) }
        return NotificationPlan(requests: requests, claimed: batch.claimed, summarizesDeferredChats: summarizes)
    }

    /// Stable per message, so posting again replaces rather than duplicates (plan D3). Retained ciphertext has no
    /// message row yet; its identity is derived from its ciphertext key instead, inside the same opaque digest.
    public static func identifier(for candidate: NotificationCandidate) -> String {
        identifier(accountID: candidate.accountID, key: candidate.key)
    }

    static func identifier(accountID: String, key: NotificationCandidateKey) -> String {
        switch key {
        case let .message(id): NotificationIdentity.message(accountID: accountID, messageID: id)
        case let .pending(sender, digest): NotificationIdentity.message(accountID: accountID, messageID: "pending\u{0}\(sender)\u{0}\(digest)")
        }
    }

    /// Nil for a message its sender has since unsent: it is claimed, never shown.
    private static func text(for candidate: NotificationCandidate) -> String? {
        switch candidate.content {
        case let .message(message):
            guard !message.isRetracted else { return nil }
            // Metadata only: the extension never downloads a shared file.
            let text = clean(message.body, limit: 240)
            return text.isEmpty ? (message.attachment?.kindLabel ?? hiddenBody) : text
        case .unreadable: return unreadableBody
        case .pendingEncrypted: return reviewBody
        }
    }

    private static func senderName(_ candidate: NotificationCandidate) -> String {
        clean(displayName(candidate.senderID, title: candidate.senderTitle), limit: 40, maximumBytes: 160)
    }

    /// A stored title, unless it is just the address; then the local part reads as the name (as in the app).
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
