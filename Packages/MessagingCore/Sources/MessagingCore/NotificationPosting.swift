import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(Intents)
import Intents
#endif

/// Reduced to what cleanup needs: no title or body.
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

/// The only seam between delivery logic and the system notification store.
public protocol NotificationPosting: Sendable {
    /// Adding an existing identifier replaces it.
    func add(_ request: PlannedNotification) async throws
    func deliveredNotifications() async -> [DeliveredNotification]
    func removeDelivered(identifiers: [String]) async
    /// Time `add` may spend before handing the request to the system (an intent donation), on top of the presenter's
    /// limit for the system add.
    func preparationAllowance(for request: PlannedNotification) -> Duration
}

extension NotificationPosting {
    public func preparationAllowance(for request: PlannedNotification) -> Duration { .zero }
}

final class DonationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Duration
    init(_ total: Duration) { remaining = total }
    func next(maximum: Duration) -> Duration? {
        lock.withLock { remaining > .milliseconds(200) ? min(maximum, remaining) : nil }
    }
    func spend(_ elapsed: Duration) { lock.withLock { remaining -= elapsed } }
}

#if canImport(UserNotifications)
extension DeliveredNotification {
    /// Never reads a title or body.
    public init(_ request: UNNotificationRequest) {
        let content = request.content
        let payload = content.userInfo[NotificationDestination.userInfoKey] as? [String: String]
        let reference = content.userInfo[NotificationReference.userInfoKey] as? [String: String]
        self.init(identifier: request.identifier, categoryIdentifier: content.categoryIdentifier,
                  destination: payload.flatMap(NotificationDestination.init(payload:)),
                  reference: reference.flatMap(NotificationReference.init(payload:)))
    }
}

/// `UNUserNotificationCenter` behind `NotificationPosting`. Never requests authorization: the app owns that.
public struct UserNotificationPoster: NotificationPosting, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    // Pre-scaled avatar bytes, never decoded here: the extension's memory budget is small.
    private let avatarData: @Sendable (_ hash: String) -> Data?
    // Read per request: a run that waited for the lease must use the setting saved when it posts.
    private let donates: @Sendable () -> Bool
    // A cold Intents service takes seconds. Once one run's budget is spent, requests post plain rather than risk the
    // extension's time limit.
    private let donationBudget: DonationBudget

    /// Granted by `preparationAllowance`, so it never eats into the system add's limit.
    public static let donationLimit: Duration = .milliseconds(2500)

    public init(center: UNUserNotificationCenter = .current(), donates: @escaping @Sendable () -> Bool = { true }, donationBudget: Duration = .seconds(6),
                avatarData: @escaping @Sendable (_ hash: String) -> Data? = { _ in nil }) {
        self.center = center; self.avatarData = avatarData; self.donates = donates
        self.donationBudget = DonationBudget(donationBudget)
    }

    public func preparationAllowance(for request: PlannedNotification) -> Duration { Self.allowance(for: request, donates: donates()) }

    static func allowance(for request: PlannedNotification, donates: Bool) -> Duration {
        request.communication == nil || !donates ? .zero : donationLimit
    }

    public func add(_ request: PlannedNotification) async throws {
        let plain = Self.content(for: request)
        var content: UNNotificationContent = plain
        #if canImport(Intents)
        if let communication = request.communication {
            let intent = CommunicationNotification.intent(communication, avatar: avatarData)
            let limit = donates() ? donationBudget.next(maximum: Self.donationLimit) : nil
            let donate: CommunicationNotification.Donate? = limit == nil ? nil : CommunicationNotification.systemDonate
            let started = ContinuousClock.now
            let communicated: UNNotificationContent? = await CommunicationNotification.content(
                Self.content(for: request, body: communication.body), intent: intent, donate: donate, donationTimeout: limit ?? .zero)
            content = communicated ?? plain
            if limit != nil { donationBudget.spend(ContinuousClock.now - started) }
        }
        #endif
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    // Set everything before the intent update: the updated content must not be mutated afterwards.
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
        await center.deliveredNotifications().map { DeliveredNotification($0.request) }
    }

    public func removeDelivered(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
#endif
