import Foundation
import UserNotifications
import MessagingCore

// Created before app-model setup, so a tap during a cold launch stays buffered.
@MainActor final class NotificationNavigation {
    static let shared = NotificationNavigation()
    private let events = AsyncStream<NotificationDestination>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var taps: AsyncStream<NotificationDestination> { events.stream }

    func receive(userInfo: [AnyHashable: Any], actionIdentifier: String) {
        guard let destination = Self.destination(userInfo: userInfo, actionIdentifier: actionIdentifier) else { return }
        receive(destination)
    }

    // A separate key keeps read-state cleanup from removing this notice before the chat is opened.
    nonisolated static let replyFailureKey = "xmpp_local_reply_failure"

    // Only a tap on the body routes; a dismissal or action button never opens a chat.
    nonisolated static func destination(userInfo: [AnyHashable: Any], actionIdentifier: String) -> NotificationDestination? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        for key in [NotificationDestination.userInfoKey, replyFailureKey] {
            if let payload = userInfo[key] as? [String: String], let destination = NotificationDestination(payload: payload) { return destination }
        }
        return nil
    }

    func receive(_ destination: NotificationDestination) {
        events.continuation.yield(destination)
    }
}

struct NotificationChatRoute: Equatable {
    let id = UUID()
    let accountID: String
    let chatID: String
}
