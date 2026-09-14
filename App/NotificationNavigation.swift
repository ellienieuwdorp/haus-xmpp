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

    nonisolated static func destination(userInfo: [AnyHashable: Any], actionIdentifier: String) -> NotificationDestination? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let payload = userInfo[NotificationDestination.userInfoKey] as? [String: String],
              let destination = NotificationDestination(payload: payload) else { return nil }
        return destination
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
