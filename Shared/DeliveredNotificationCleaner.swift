import Foundation
import UserNotifications
import MessageStore
import MessagingCore

// Identifiers come only from `NotificationIdentity`; an older delivered request is matched by the message its
// `NotificationDestination` names. Removal never touches another account's requests.
enum DeliveredNotificationCleaner {
    struct Delivered: Sendable, Equatable {
        let identifier: String
        let threadIdentifier: String
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
                ?? reference.flatMap { $0.accountScope == scope && $0.kind == .placeholder ? $0.messageID : nil }
        }
    }

    static func identifiers(accountID: String, readMessageIDs: Set<String>, delivered: [Delivered]) -> [String] {
        let own = readMessageIDs.map { NotificationIdentity.message(accountID: accountID, messageID: $0) }
        let named = delivered.filter { $0.messageID.map(readMessageIDs.contains) ?? false }.map(\.identifier)
        return Array(Set(own + named)).sorted()
    }

    static func threadIdentifiers(accountID: String, chatID: String, delivered: [Delivered]) -> [String] {
        let thread = NotificationIdentity.thread(accountID: accountID, chatID: chatID)
        return delivered.filter { $0.threadIdentifier == thread }.map(\.identifier)
    }

    static func removeMessages(accountID: String, messageIDs: Set<String>, center: UNUserNotificationCenter = .current()) async {
        guard !messageIDs.isEmpty else { return }
        let delivered = await deliveredRequests(accountID: accountID, center: center)
        remove(identifiers(accountID: accountID, readMessageIDs: messageIDs, delivered: delivered), center: center)
    }

    static func removeThread(accountID: String, chatID: String, center: UNUserNotificationCenter = .current()) async {
        let delivered = await deliveredRequests(accountID: accountID, center: center)
        remove(threadIdentifiers(accountID: accountID, chatID: chatID, delivered: delivered), center: center)
    }

    // Reaction notifications go once the read pointer moved after they posted (`ReactionNotificationCleanup`), review
    // notifications once their ciphertext is no longer retained (`RetainedNotificationCleanup`).
    static func removeRead(accountID: String, store: MessageStore, center: UNUserNotificationCenter = .current()) async throws {
        let notifications = await center.deliveredNotifications()
        let delivered = notifications.map { Delivered($0.request, accountID: accountID) }
        let current = notifications.map { DeliveredNotification($0.request) }
        let named = Set(delivered.compactMap(\.messageID))
        var stale: [String] = []
        if !named.isEmpty {
            // The store bounds one question to 1,000 ids; Notification Center holds far fewer.
            let read = try await store.readNotificationMessageIDs(accountID: accountID, messageIDs: Set(named.sorted().prefix(1_000)))
            stale = identifiers(accountID: accountID, readMessageIDs: read, delivered: delivered)
        }
        stale += try await ReactionNotificationCleanup.staleIdentifiers(store: store, accountID: accountID, delivered: current)
        stale += try await RetainedNotificationCleanup.staleIdentifiers(store: store, accountID: accountID, delivered: current)
        remove(Array(Set(stale)).sorted(), center: center)
    }

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
