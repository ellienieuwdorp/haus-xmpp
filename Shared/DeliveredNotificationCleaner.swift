import Foundation
import UserNotifications
import MessageStore
import MessagingCore

/// Removes notifications for messages that have been read, here or on another device, so Notification Center only
/// holds what is still unread. Compiled into the app and the notification extension. Identifiers come only from
/// `NotificationIdentity`; a delivered request that predates it is matched by the message its
/// `NotificationDestination` names. Removal never touches another account's requests.
enum DeliveredNotificationCleaner {
    /// What removal needs to know about one delivered request, read off `UNNotification` (kept apart so the choice is testable).
    struct Delivered: Sendable, Equatable {
        let identifier: String
        let threadIdentifier: String
        /// The message a `NotificationDestination` names, when the request carries one for this account, or the
        /// placeholder row an unreadable message's cleanup `NotificationReference` names (plan D5).
        let messageID: String?

        init(identifier: String, threadIdentifier: String, messageID: String?) {
            self.identifier = identifier; self.threadIdentifier = threadIdentifier; self.messageID = messageID
        }

        init(_ request: UNNotificationRequest, accountID: String) {
            identifier = request.identifier
            threadIdentifier = request.content.threadIdentifier
            let destination = (request.content.userInfo[NotificationDestination.userInfoKey] as? [String: String]).flatMap(NotificationDestination.init(payload:))
            // Scope first: the payload names a message only within the account it was posted for.
            let scope = NotificationDestination(accountID: accountID, messageID: UUID().uuidString)?.accountScope
            // A reaction's destination names this account's own reacted-to message, which says nothing about reading.
            let reference = (request.content.userInfo[NotificationReference.userInfoKey] as? [String: String]).flatMap(NotificationReference.init(payload:))
            messageID = destination.flatMap { $0.accountScope == scope && $0.kind == .message ? $0.messageID : nil }
                // "Sent a message this device can't read" is a message row too: read here or elsewhere, it goes with the rest.
                ?? reference.flatMap { $0.accountScope == scope && $0.kind == .placeholder ? $0.messageID : nil }
        }
    }

    /// The request identifiers to remove once `readMessageIDs` are read: each message's own identifier (delivered or
    /// still pending), and any delivered request that names one of them.
    static func identifiers(accountID: String, readMessageIDs: Set<String>, delivered: [Delivered]) -> [String] {
        let own = readMessageIDs.map { NotificationIdentity.message(accountID: accountID, messageID: $0) }
        let named = delivered.filter { $0.messageID.map(readMessageIDs.contains) ?? false }.map(\.identifier)
        return Array(Set(own + named)).sorted()
    }

    /// Every delivered request in one chat's thread: the chat was opened, so all of it is on screen.
    static func threadIdentifiers(accountID: String, chatID: String, delivered: [Delivered]) -> [String] {
        let thread = NotificationIdentity.thread(accountID: accountID, chatID: chatID)
        return delivered.filter { $0.threadIdentifier == thread }.map(\.identifier)
    }

    /// Removes the requests of these stored messages, delivered or pending.
    static func removeMessages(accountID: String, messageIDs: Set<String>, center: UNUserNotificationCenter = .current()) async {
        guard !messageIDs.isEmpty else { return }
        let delivered = await deliveredRequests(accountID: accountID, center: center)
        remove(identifiers(accountID: accountID, readMessageIDs: messageIDs, delivered: delivered), center: center)
    }

    /// Removes every delivered request of one chat. Called when the chat opens.
    static func removeThread(accountID: String, chatID: String, center: UNUserNotificationCenter = .current()) async {
        let delivered = await deliveredRequests(accountID: accountID, center: center)
        remove(threadIdentifiers(accountID: accountID, chatID: chatID, delivered: delivered), center: center)
    }

    /// Asks the store which delivered messages are now at or below their chat's read pointer and removes them. For the
    /// app after any pointer moved (a local read, another device's marker, an XEP-0490 item), and for the extension at
    /// the end of a run.
    /// Reaction notifications go the same way: a pointer that moved after they were posted means the chat was seen
    /// (`ReactionNotificationCleanup`, which also drops ones withdrawn in part or whole).
    static func removeRead(accountID: String, store: MessageStore, center: UNUserNotificationCenter = .current()) async throws {
        let notifications = await center.deliveredNotifications()
        let delivered = notifications.map { Delivered($0.request, accountID: accountID) }
        let named = Set(delivered.compactMap(\.messageID))
        var stale: [String] = []
        if !named.isEmpty {
            // The store bounds one question to 1,000 ids; Notification Center holds far fewer.
            let read = try await store.readNotificationMessageIDs(accountID: accountID, messageIDs: Set(named.sorted().prefix(1_000)))
            stale = identifiers(accountID: accountID, readMessageIDs: read, delivered: delivered)
        }
        stale += try await ReactionNotificationCleanup.staleIdentifiers(store: store, accountID: accountID,
                                                                         delivered: notifications.map { DeliveredNotification($0.request) })
        remove(Array(Set(stale)).sorted(), center: center)
    }

    /// After a completed catch-up the "You may have new messages" fallback and the deferred-chats summary are answered:
    /// the messages they stood for are in the app now.
    static func removeCatchUpPlaceholders(accountID: String, center: UNUserNotificationCenter = .current()) async {
        let overflow = NotificationIdentity.overflow(accountID: accountID)
        let stale = await center.deliveredNotifications()
            .filter { $0.request.content.categoryIdentifier == NotificationIdentity.fallbackCategory || $0.request.identifier == overflow }
            .map(\.request.identifier)
        remove(stale, center: center)
    }

    private static func deliveredRequests(accountID: String, center: UNUserNotificationCenter) async -> [Delivered] {
        await center.deliveredNotifications().map { Delivered($0.request, accountID: accountID) }
    }

    private static func remove(_ identifiers: [String], center: UNUserNotificationCenter) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
