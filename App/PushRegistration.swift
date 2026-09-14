import UIKit
import UserNotifications

@MainActor
final class PushRegistration: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = PushRegistration()
    private var currentToken: Data?
    private var waiters: [UUID: CheckedContinuation<Data, any Error>] = [:]
    enum Failure: Error { case unavailable, denied }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.shared.currentToken = deviceToken
        let pending = Self.shared.waiters
        Self.shared.waiters.removeAll()
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
}
