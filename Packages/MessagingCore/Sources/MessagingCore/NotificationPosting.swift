import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// A notification the system is currently showing, reduced to what cleanup needs: no title or body.
public struct DeliveredNotification: Sendable, Equatable {
    public let identifier: String
    public let categoryIdentifier: String
    public let destination: NotificationDestination?
    /// Set on placeholder and retained-ciphertext notifications, which have no destination.
    public let reference: NotificationReference?
    public init(identifier: String, categoryIdentifier: String, destination: NotificationDestination?, reference: NotificationReference? = nil) {
        self.identifier = identifier; self.categoryIdentifier = categoryIdentifier; self.destination = destination; self.reference = reference
    }
}

/// The only seam between delivery logic and the operating system's notification store.
public protocol NotificationPosting: Sendable {
    /// Returns once the system accepted the request (or throws). Adding an existing identifier replaces it.
    func add(_ request: PlannedNotification) async throws
    func deliveredNotifications() async -> [DeliveredNotification]
    func removeDelivered(identifiers: [String]) async
}

#if canImport(UserNotifications)
/// `UNUserNotificationCenter` behind `NotificationPosting`. Never requests authorization: the app owns that.
public struct UserNotificationPoster: NotificationPosting, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    /// A fresh file URL the system may take ownership of, for a verified cached avatar; nil when there is none.
    private let avatarCopy: @Sendable (_ hash: String, _ requestIdentifier: String) -> URL?

    public init(center: UNUserNotificationCenter = .current(),
                avatarCopy: @escaping @Sendable (_ hash: String, _ requestIdentifier: String) -> URL? = { _, _ in nil }) {
        self.center = center; self.avatarCopy = avatarCopy
    }

    public func add(_ request: PlannedNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadIdentifier
        content.categoryIdentifier = request.categoryIdentifier
        content.userInfo = request.userInfo
        content.sound = request.playsSound ? .default : nil
        if let hash = request.avatarHash, let url = avatarCopy(hash, request.identifier),
           let attachment = try? UNNotificationAttachment(identifier: "avatar", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]) {
            content.attachments = [attachment]
        }
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    public func deliveredNotifications() async -> [DeliveredNotification] {
        await center.deliveredNotifications().map { notification in
            let content = notification.request.content
            let payload = content.userInfo[NotificationDestination.userInfoKey] as? [String: String]
            let reference = content.userInfo[NotificationReference.userInfoKey] as? [String: String]
            return DeliveredNotification(identifier: notification.request.identifier, categoryIdentifier: content.categoryIdentifier,
                                         destination: payload.flatMap(NotificationDestination.init(payload:)),
                                         reference: reference.flatMap(NotificationReference.init(payload:)))
        }
    }

    public func removeDelivered(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
#endif
