import Foundation
import MessageStore
import MessagingCore

/// The share screen's decisions, free of views and the store, so tests state them directly.
enum ShareRules {
    /// Chats one share may go to. WhatsApp forwards to five at most; more than that is a broadcast, not a share.
    static let maximumRecipients = 5
    /// Recent chats the picker lists before a search; pinned ones come first and always show.
    static let recentChats = 30

    /// One chat as the picker shows it.
    struct Chat: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let isGroup: Bool
        let isPinned: Bool
        let avatarHash: String?
        let lastActivity: Date?
        /// The stored encryption state, as the chat's header shows it. `.pending` draws no pill.
        let encryption: ChatCapabilities.Encryption
        var displayTitle: String { ContactName.display(for: id, title: title) }
    }

    /// A stored chat as the picker lists it, named and pictured as the app and its notifications show it: a linked
    /// contact's name and photo first (`ContactLink`). Rooms are never linked. The encryption state comes later.
    static func chat(id: String, storedTitle: String, isGroup: Bool, isPinned: Bool, verifiedAvatarHash: String?, lastActivity: Date?,
                     link: ContactLink?) -> Chat {
        let link = isGroup ? nil : link
        return Chat(id: id, title: link?.name ?? storedTitle, isGroup: isGroup, isPinned: isPinned,
                    avatarHash: ContactLink.avatarHash(verified: verifiedAvatarHash, link: link), lastActivity: lastActivity, encryption: .pending)
    }

    /// Why a chat cannot take this share; nil when it can.
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

    /// The picker's order: pinned chats, then by last activity, newest first. A search matches the name or address and
    /// lists every chat; without one, only pinned chats and the most recent show.
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

    /// The chat a share-sheet suggestion names, by its conversation identifier (`NotificationIdentity.thread`). The
    /// identifier is scoped to the account, so another account's suggestion matches nothing and shows the picker.
    static func suggestedChat(conversationIdentifier: String?, accountID: String, chats: [Chat]) -> Chat? {
        guard let conversationIdentifier, !conversationIdentifier.isEmpty else { return nil }
        return chats.first { NotificationIdentity.thread(accountID: accountID, chatID: $0.id) == conversationIdentifier }
    }

    /// The message text the screen starts with: the shared links and text, each once, in share order.
    static func initialText(from items: [SharedItem]) -> String {
        var seen: Set<String> = []
        var parts: [String] = []
        for item in items where !item.isFile {
            guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, seen.insert(text).inserted else { continue }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    /// Whether Send can go: something to send, at least one chat, text within the composer's limit, and no file left on
    /// the review card that could not be prepared. The user removes such a file first, so nothing they still see is
    /// left out of the share without their say.
    static func canSend(files: Int, unsendableFiles: Int, text: String, recipients: Int) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return recipients > 0 && recipients <= maximumRecipients && unsendableFiles == 0 && (files > 0 || hasText)
            && text.utf8.count <= OutgoingEnqueue.maximumTextBytes
    }

    /// How one chat's part of a share ended up. `incomplete`: some of it could not be saved, whatever became of the rest.
    enum Delivery: Equatable, Sendable { case queued, sending, sent, failed, incomplete }

    /// One chat's part of the share: sent only when the server acknowledged every message of it. Still unacknowledged
    /// when the share ends, it is queued: the app's next connection sends it, or reconciles it from the archive.
    static func delivery(_ states: [ShareItemState], finished: Bool) -> Delivery {
        if states.contains(.failed) { return .failed }
        if !states.isEmpty, states.allSatisfy({ $0 == .sent }) { return .sent }
        return finished ? .queued : .sending
    }

    /// Each chat's result and the line under the results once the share ended. `states` lists, for every chosen chat,
    /// the states of the messages saved for it; `unsaved` holds the chats for which an item could not be saved. Such an
    /// item has no row anywhere, so the app can neither send nor retry it: the line says so whatever happened to the
    /// rest, and never promises that the app finishes it.
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

    /// What the share sheet offers Haus XMPP for, as the extensions' Info.plist states it (`NSExtensionActivationRule`):
    /// one or two extension items (Safari sends the page and its preview), at most `SharedItemIntake.maximumFiles`
    /// attachments in each, and at least one attachment of a kind the screen can send.
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
