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

    public init(identifier: String, threadIdentifier: String, categoryIdentifier: String = NotificationIdentity.messageCategory,
                title: String, body: String, playsSound: Bool, destination: NotificationDestination?, avatarHash: String?) {
        self.identifier = identifier; self.threadIdentifier = threadIdentifier; self.categoryIdentifier = categoryIdentifier
        self.title = title; self.body = body; self.playsSound = playsSound; self.destination = destination; self.avatarHash = avatarHash
    }

    /// The `userInfo` payload: the opaque destination only, never an address or body.
    public var userInfo: [String: [String: String]] {
        destination.map { [NotificationDestination.userInfoKey: $0.payload] } ?? [:]
    }
    public var description: String { "PlannedNotification(<redacted>)" }
}

/// What a settled run posts, and the candidate rows it may delete once every post completed.
public struct NotificationPlan: Sendable, Equatable {
    public let requests: [PlannedNotification]
    public let claimed: [NotificationCandidateKey]
}

/// Pure: store snapshot in, ordered requests out (plan D1, D3–D5). Oldest first, so the newest is added last and sits on top.
public enum NotificationPlanner {
    /// The visible alert whenever a run cannot settle (plan D2). It never carries message content.
    public static let fallbackBody = "You may have new messages"
    /// Retained ciphertext waiting for trust or keys (plan D5); matches the app's review wording.
    public static let reviewBody = "Sent an encrypted message. Open the chat to review."
    /// An incoming placeholder this device cannot read (plan D5).
    public static let unreadableBody = "Sent a message this device can't read"
    /// Every body when previews are off.
    public static let hiddenBody = "New message"

    public static func plan(_ batch: MessageNotification) -> NotificationPlan {
        var requests: [PlannedNotification] = []
        for candidate in batch.candidates {
            guard let text = text(for: candidate) else { continue }
            let previews = batch.previewsEnabled
            var body = previews ? (candidate.isGroup ? senderName(candidate) + ": " + text : text) : hiddenBody
            if candidate.earlierCount > 0 { body += "\nand \(candidate.earlierCount) more" }
            let destination: NotificationDestination?
            if case let .message(message) = candidate.content {
                destination = NotificationDestination(accountID: candidate.accountID, messageID: message.id)
            } else { destination = nil }
            requests.append(PlannedNotification(
                identifier: identifier(for: candidate),
                threadIdentifier: NotificationIdentity.thread(accountID: candidate.accountID, chatID: candidate.chatID),
                title: previews ? clean(displayName(candidate.chatID, title: candidate.chatTitle), limit: 80, maximumBytes: 320) : "",
                body: body, playsSound: false, destination: destination,
                avatarHash: previews ? candidate.chatAvatarHash : nil))
        }
        if let newest = requests.popLast() {
            requests.append(PlannedNotification(identifier: newest.identifier, threadIdentifier: newest.threadIdentifier,
                categoryIdentifier: newest.categoryIdentifier, title: newest.title, body: newest.body, playsSound: true,
                destination: newest.destination, avatarHash: newest.avatarHash))
        }
        return NotificationPlan(requests: requests, claimed: batch.claimed)
    }

    /// Stable per message, so posting again replaces rather than duplicates (plan D3). Retained ciphertext has no
    /// message row yet; its identity is derived from its ciphertext key instead, inside the same opaque digest.
    public static func identifier(for candidate: NotificationCandidate) -> String {
        switch candidate.key {
        case let .message(id): NotificationIdentity.message(accountID: candidate.accountID, messageID: id)
        case let .pending(sender, digest): NotificationIdentity.message(accountID: candidate.accountID, messageID: "pending\u{0}\(sender)\u{0}\(digest)")
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
