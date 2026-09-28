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
    /// The bytes of the app's pre-scaled copy of a verified avatar (at most 256 px); nil when there is none. Read, never
    /// decoded here: the extension's memory budget is small.
    private let avatarData: @Sendable (_ hash: String) -> Data?
    private let donates: Bool

    public init(center: UNUserNotificationCenter = .current(), donates: Bool = true,
                avatarData: @escaping @Sendable (_ hash: String) -> Data? = { _ in nil }) {
        self.center = center; self.avatarData = avatarData; self.donates = donates
    }

    public func add(_ request: PlannedNotification) async throws {
        let plain = Self.content(for: request)
        var content: UNNotificationContent = plain
        #if canImport(Intents)
        // Previews on: a communication notification with the sender's name and avatar. A failed donation or update
        // posts the plain request, never the gateway's generic alert.
        if let communication = request.communication {
            let intent = CommunicationNotification.intent(communication, avatar: avatarData)
            content = await CommunicationNotification.content(plain, intent: intent, donate: donates) ?? plain
        }
        #endif
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    /// Everything the request carries, set before any intent update (the updated content is not mutated afterwards).
    static func content(for request: PlannedNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadIdentifier
        content.categoryIdentifier = request.categoryIdentifier
        content.userInfo = request.userInfo
        content.sound = request.playsSound ? .default : nil
        content.badge = request.badge.map { NSNumber(value: $0) }
        return content
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
