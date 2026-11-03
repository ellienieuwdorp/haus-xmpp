#if os(iOS)
import UIKit
#endif
import UserNotifications
import MessagingCore

@MainActor
final class PushRegistration: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushRegistration()
    // A token received before the model subscribes stays buffered; newer unsolicited callbacks supersede it.
    private let unsolicited = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1))
    // Ordering guard only. Never return this cached value instead of requesting APNs.
    private var latestCallbackToken: Data?
    private var waiters: [UUID: CheckedContinuation<Data, any Error>] = [:]
    enum Failure: Error { case unavailable, denied }

    func installNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(NotificationCategories.all)
        #if DEBUG && os(iOS)
        NotificationHarness.install()
        #endif
    }

    static func request() async throws -> Data {
        #if os(macOS)
        // The caller has read the authorization, and asked for it where it may (`AppModel.reconcilePush`). Asking
        // here would put the prompt for banners on screen over the quiet delivery macOS grants without one.
        guard PushService.isOffered else { throw Failure.unavailable }
        #else
        guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else { throw Failure.denied }
        #endif
        // Register on every launch/request: APNs tokens may change. Never infer a token size.
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                shared.waiters[id] = continuation
                PlatformApplication.registerForRemoteNotifications()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(15))
                    shared.waiters.removeValue(forKey: id)?.resume(throwing: Failure.unavailable)
                }
            }
        } onCancel: {
            // Sign-out joins a push setup: it must not wait out the APNs timeout. Runs after the waiter was added,
            // since both hop to the main actor in order.
            Task { @MainActor in shared.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    static func refreshIfAuthorized() async throws -> Data? {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return nil }
        return try await request()
    }

    static func unsolicitedTokens() -> AsyncStream<Data> { shared.unsolicited.stream }
    static func isLatestToken(_ token: Data) -> Bool { shared.latestCallbackToken == token }

    func received(_ deviceToken: Data) {
        Self.shared.latestCallbackToken = deviceToken
        let pending = Self.shared.waiters
        Self.shared.waiters.removeAll()
        if pending.isEmpty { Self.shared.unsolicited.continuation.yield(deviceToken) }
        for waiter in pending.values { waiter.resume(returning: deviceToken) }
    }
    func registrationFailed() {
        let pending = Self.shared.waiters
        Self.shared.waiters.removeAll()
        for waiter in pending.values { waiter.resume(throwing: Failure.unavailable) }
    }
    // Completion-handler form: UIKit requires the handler on the main thread, which the async form does not guarantee.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let request = ForegroundPresentation.request(notification)
        let completion = MainThreadCompletion(completionHandler)
        Task { @MainActor in
            let state = ForegroundNotificationState.shared
            completion.call(ForegroundPresentation.options(for: request, accountID: state.accountID, openChatID: state.openChatID))
        }
    }

    // May run with the app launched into the background; the handler is called once the action's work settled.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let completion = MainThreadCompletion<Void>({ _ in completionHandler() })
        switch response.actionIdentifier {
        case NotificationActionIdentifier.reply, NotificationActionIdentifier.markRead:
            guard let request = NotificationActionRequest(userInfo: content.userInfo, categoryIdentifier: content.categoryIdentifier,
                                                          actionIdentifier: response.actionIdentifier,
                                                          text: (response as? UNTextInputNotificationResponse)?.userText) else {
                // Typed text that cannot become a request (over the composer's limit, or no destination) is not sent:
                // say so, naming nothing. A blank reply had nothing to send.
                let typed = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Task { @MainActor in
                    if !typed.isEmpty { await NotificationActionCenter.postRejectedReply() }
                    completion.call(())
                }
                return
            }
            Task { @MainActor in
                await NotificationActionCenter.shared.perform(request)
                completion.call(())
            }
        default:
            let destination = NotificationNavigation.destination(userInfo: content.userInfo, actionIdentifier: response.actionIdentifier)
            Task { @MainActor in
                if let destination { NotificationNavigation.shared.receive(destination) }
                completion.call(())
            }
        }
    }
}

#if os(iOS)
extension PushRegistration: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        installNotificationDelegate()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        received(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        registrationFailed()
    }
}
#endif

// Unchecked: the handler is only called on the main actor, as UIKit requires.
private struct MainThreadCompletion<Value>: @unchecked Sendable {
    private let handler: (Value) -> Void
    init(_ handler: @escaping (Value) -> Void) { self.handler = handler }
    @MainActor func call(_ value: Value) { handler(value) }
}
