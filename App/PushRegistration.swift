import UIKit
import UserNotifications
import MessagingCore

@MainActor
final class PushRegistration: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = PushRegistration()
    // One primary AppModel consumes this stream. A token received before subscription
    // remains buffered; newer unsolicited callbacks supersede older buffered values.
    private let unsolicited = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1))
    // Ordering guard only. Never return this cached value instead of requesting APNs.
    private var latestCallbackToken: Data?
    private var waiters: [UUID: CheckedContinuation<Data, any Error>] = [:]
    enum Failure: Error { case unavailable, denied }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // One category per message notification, one for reactions to own messages (no message actions) and one for the
        // extension's generic fallback (plan D2, D3, D8).
        let message = UNNotificationCategory(identifier: NotificationIdentity.messageCategory, actions: [], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "New message", options: [])
        let reaction = UNNotificationCategory(identifier: NotificationIdentity.reactionCategory, actions: [], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: NotificationPlanner.hiddenReactionBody, options: [])
        let fallback = UNNotificationCategory(identifier: NotificationIdentity.fallbackCategory, actions: [], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: NotificationPlanner.fallbackBody, options: [])
        UNUserNotificationCenter.current().setNotificationCategories([message, reaction, fallback])
        #if DEBUG
        NotificationHarness.install()
        #endif
        return true
    }

    static func request() async throws -> Data {
        guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else { throw Failure.denied }
        // Register on every launch/request: APNs tokens may change. Never infer a token size.
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            shared.waiters[id] = continuation
            UIApplication.shared.registerForRemoteNotifications()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                shared.waiters.removeValue(forKey: id)?.resume(throwing: Failure.unavailable)
            }
        }
    }

    static func refreshIfAuthorized() async throws -> Data? {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return nil }
        return try await request()
    }

    static func unsolicitedTokens() -> AsyncStream<Data> { shared.unsolicited.stream }
    static func isLatestToken(_ token: Data) -> Bool { shared.latestCallbackToken == token }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.shared.latestCallbackToken = deviceToken
        let pending = Self.shared.waiters
        Self.shared.waiters.removeAll()
        if pending.isEmpty { Self.shared.unsolicited.continuation.yield(deviceToken) }
        for waiter in pending.values { waiter.resume(returning: deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        let pending = Self.shared.waiters
        Self.shared.waiters.removeAll()
        for waiter in pending.values { waiter.resume(throwing: Failure.unavailable) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Foreground conversation UI already presents durable messages. No duplicate banner.
        []
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let destination = NotificationNavigation.destination(userInfo: response.notification.request.content.userInfo,
                                                                   actionIdentifier: response.actionIdentifier) else { return }
        await NotificationNavigation.shared.receive(destination)
    }
}
