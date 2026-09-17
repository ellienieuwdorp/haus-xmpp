import Foundation
import MessageStore
import CryptoKit

/// Only local authenticated state may create a preview. iOS separately enforces its Show
/// Previews setting; the notification category never opts into revealing hidden titles.
public struct NotificationPreview: Sendable, Equatable {
    public let title: String
    public let body: String
    public let threadIdentifier: String
    public let hasNewMessage: Bool
    public let includesMessageText: Bool
    public let destination: NotificationDestination?

    public init(_ batch: MessageNotification) {
        hasNewMessage = batch.messageCount > 0 && batch.latest != nil
        includesMessageText = hasNewMessage && batch.previewsEnabled && batch.conversationCount == 1
        destination = hasNewMessage && batch.conversationCount == 1
            ? batch.latest.flatMap { NotificationDestination(accountID: $0.accountID, messageID: $0.id) } : nil
        guard hasNewMessage, let latest = batch.latest else {
            title = "XMPP"; body = "New encrypted activity"; threadIdentifier = ""
            return
        }
        let digest = SHA256.hash(data: Data((latest.accountID + "\u{0}" + latest.chatID).utf8))
        threadIdentifier = batch.conversationCount == 1 ? digest.map { String(format: "%02x", $0) }.joined() : ""
        guard batch.previewsEnabled else {
            title = "XMPP"; body = batch.messageCount == 1 ? "New message" : "\(batch.messageCount) new messages"
            return
        }
        if batch.conversationCount > 1 {
            title = "\(batch.messageCount) new messages"
            body = "In \(batch.conversationCount) conversations"
        } else {
            title = Self.clean(batch.chatTitle ?? latest.chatID, limit: 80, maximumBytes: 320)
            let text = Self.clean(latest.body, limit: 240)
            // Metadata only: the extension never downloads a shared file.
            body = text.isEmpty ? (latest.attachment?.kindLabel ?? "New message") : text
        }
    }

    private static func clean(_ text: String, limit: Int, maximumBytes: Int = 1024) -> String {
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
