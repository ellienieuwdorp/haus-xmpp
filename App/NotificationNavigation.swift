import Foundation
import UserNotifications
import MessagingCore

/// Created before app-model setup; the latest tap remains buffered during a cold launch.
@MainActor final class NotificationNavigation {
    static let shared = NotificationNavigation()
    private let events = AsyncStream<NotificationDestination>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var taps: AsyncStream<NotificationDestination> { events.stream }

    func receive(userInfo: [AnyHashable: Any], actionIdentifier: String) {
        guard let destination = Self.destination(userInfo: userInfo, actionIdentifier: actionIdentifier) else { return }
        receive(destination)
    }

    /// The "Couldn't send your reply" notice names the message that was answered under this key, not the usual one, so
    /// read-state cleanup (which removes notifications naming read messages) leaves it until the chat is opened.
    nonisolated static let replyFailureKey = "xmpp_local_reply_failure"

    /// Only a tap on the notification body routes; a dismissal or an action button never opens a chat.
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
