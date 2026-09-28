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

/// What is left of a run's time for intent donations.
final class DonationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Duration
    init(_ total: Duration) { remaining = total }
    /// The limit for the next donation, or nil once the budget is spent.
    func next(maximum: Duration) -> Duration? {
        lock.withLock { remaining > .milliseconds(200) ? min(maximum, remaining) : nil }
    }
    func spend(_ elapsed: Duration) { lock.withLock { remaining -= elapsed } }
}

#if canImport(UserNotifications)
/// `UNUserNotificationCenter` behind `NotificationPosting`. Never requests authorization: the app owns that.
public struct UserNotificationPoster: NotificationPosting, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    /// The bytes of the app's pre-scaled copy of a verified avatar (at most 256 px); nil when there is none. Read, never
    /// decoded here: the extension's memory budget is small.
    private let avatarData: @Sendable (_ hash: String) -> Data?
    private let donates: Bool
    /// Donations are slow on a cold Intents service (seconds on the simulator). Each is bounded, and so is their total
    /// per poster (one extension run): once spent, requests post plain rather than risk the extension's time limit.
    private let donationBudget: DonationBudget

    public init(center: UNUserNotificationCenter = .current(), donates: Bool = true, donationBudget: Duration = .seconds(6),
                avatarData: @escaping @Sendable (_ hash: String) -> Data? = { _ in nil }) {
        self.center = center; self.avatarData = avatarData; self.donates = donates
        self.donationBudget = DonationBudget(donationBudget)
    }

    public func add(_ request: PlannedNotification) async throws {
        let plain = Self.content(for: request)
        var content: UNNotificationContent = plain
        #if canImport(Intents)
        // Previews on: a communication notification with the sender's name and avatar. A failed donation or update
        // posts the plain request, never the gateway's generic alert.
        if let communication = request.communication, let limit = donationBudget.next(maximum: .milliseconds(2500)) {
            let intent = CommunicationNotification.intent(communication, avatar: avatarData)
            let started = ContinuousClock.now
            content = await CommunicationNotification.content(Self.content(for: request, body: communication.body), intent: intent,
                                                              donate: donates, donationTimeout: limit) ?? plain
            donationBudget.spend(ContinuousClock.now - started)
        }
        #endif
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    /// Everything the request carries, set before any intent update (the updated content is not mutated afterwards).
    static func content(for request: PlannedNotification, body: String? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = body ?? request.body
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
