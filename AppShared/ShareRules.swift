import Foundation
import MessageStore
import MessagingCore

enum ShareRules {
    // More than five is a broadcast, not a share (WhatsApp forwards to five at most).
    static let maximumRecipients = 5
    static let recentChats = 30

    struct Chat: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let isGroup: Bool
        let isPinned: Bool
        let avatarHash: String?
        let lastActivity: Date?
        let encryption: ChatCapabilities.Encryption
        var displayTitle: String { ContactName.display(for: id, title: title) }
    }

    // A linked contact's name and photo come first (`ContactLink`); rooms are never linked.
    static func chat(id: String, storedTitle: String, isGroup: Bool, isPinned: Bool, verifiedAvatarHash: String?, lastActivity: Date?,
                     link: ContactLink?) -> Chat {
        let link = isGroup ? nil : link
        return Chat(id: id, title: link?.name ?? storedTitle, isGroup: isGroup, isPinned: isPinned,
                    avatarHash: ContactLink.avatarHash(verified: verifiedAvatarHash, link: link), lastActivity: lastActivity, encryption: .pending)
    }

    static func unavailableReason(_ chat: Chat, hasFiles: Bool, filesAccepted: Bool?, isBlocked: Bool) -> String? {
        if isBlocked { return "Blocked" }
        if case .unavailable(let reason) = chat.encryption { return reason }
        guard hasFiles else { return nil }
        // The composer refuses files in groups for now; text and links go to groups.
        if chat.isGroup { return "Files can't be sent to groups yet" }
        switch filesAccepted {
        case false?: return "Your server doesn't accept files"
        case nil: return "Haus XMPP hasn't checked this server for files yet"
        case true?: return nil
        }
    }

    // Without a search only pinned and the most recent chats show; a search lists every chat.
    static func listed(_ chats: [Chat], search: String) -> [Chat] {
        let ordered = chats.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastActivity ?? .distantPast, $1.id) > ($1.lastActivity ?? .distantPast, $0.id)
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else {
            return ordered.filter { $0.displayTitle.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
        }
        let pinned = ordered.filter(\.isPinned)
        return pinned + ordered.filter { !$0.isPinned }.prefix(recentChats)
    }

    // The identifier is account-scoped, so another account's suggestion matches nothing and shows the picker.
    static func suggestedChat(conversationIdentifier: String?, accountID: String, chats: [Chat]) -> Chat? {
        guard let conversationIdentifier, !conversationIdentifier.isEmpty else { return nil }
        return chats.first { NotificationIdentity.thread(accountID: accountID, chatID: $0.id) == conversationIdentifier }
    }

    static func initialText(from items: [SharedItem]) -> String {
        var seen: Set<String> = []
        var parts: [String] = []
        for item in items where !item.isFile {
            guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, seen.insert(text).inserted else { continue }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    // A file that could not be prepared blocks Send until the user removes it, so nothing they still see is left out.
    static func canSend(files: Int, unsendableFiles: Int, text: String, recipients: Int) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return recipients > 0 && recipients <= maximumRecipients && unsendableFiles == 0 && (files > 0 || hasText)
            && text.utf8.count <= OutgoingEnqueue.maximumTextBytes
    }

    enum Delivery: Equatable, Sendable { case queued, sending, sent, failed, incomplete }

    // Sent only once the server acknowledged every message; otherwise it stays queued for the app's next connection.
    static func delivery(_ states: [ShareItemState], finished: Bool) -> Delivery {
        if states.contains(.failed) { return .failed }
        if !states.isEmpty, states.allSatisfy({ $0 == .sent }) { return .sent }
        return finished ? .queued : .sending
    }

    // An unsaved item has no row anywhere, so the app can neither send nor retry it: the note says so whatever happened
    // to the rest.
    static func outcome(_ states: [String: [ShareItemState]], unsaved: Set<String>) -> (deliveries: [String: Delivery], note: String?) {
        var deliveries: [String: Delivery] = [:]
        for (chat, values) in states {
            deliveries[chat] = values.isEmpty ? .failed : unsaved.contains(chat) ? .incomplete : delivery(values, finished: true)
        }
        let saved = states.values.flatMap { $0 }
        var notes: [String] = []
        if !unsaved.isEmpty { notes.append(saved.isEmpty ? "Nothing could be saved. Share it again." : "Some of this couldn't be saved. Share what's missing again.") }
        if saved.contains(.failed) { notes.append("Some of this wasn't sent. Open Haus XMPP to retry it.") }
        if saved.contains(where: { $0 == .queued || $0 == .sending }) {
            notes.append("Haus XMPP will finish sending. Open it if a device needs your review.")
        }
        return (deliveries, notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    // Mirrors the extensions' `NSExtensionActivationRule`; Safari sends the page and its preview as two items.
    static let activationRule = """
        SUBQUERY(extensionItems, $item, $item.attachments.@count <= 10 AND SUBQUERY($item.attachments, $attachment, \
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.image" OR \
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.movie" OR \
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.file-url" OR \
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url" OR \
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.plain-text" OR \
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.data").@count >= 1).@count >= 1 \
        AND extensionItems.@count <= 2
        """
}
