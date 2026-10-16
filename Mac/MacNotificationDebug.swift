#if DEBUG
import AppKit
import MessageStore
import MessagingCore
import Synchronization
import UserNotifications

/// `-haus-log-notifications` and `-haus-post-notifications`: the model's notifications, message requests and reply
/// notices alike, are logged (thread, category and which fields are set; never a title, and a body only when it is
/// fixed text), and with `-haus-post-notifications` also posted as usual. Either flag
/// lets a test session (`--fresh-store`) post, which it otherwise never does, so banner checks can leave the shared App
/// Group store alone. `-haus-log-notifications` posts nothing and asks for no permission (which would put a system
/// prompt on screen); `-haus-post-notifications` needs authorization, which `-haus-request-provisional` grants without
/// a prompt.
enum MacDebugNotificationLog {
    enum Mode { case log, post }

    static let mode: Mode? = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-haus-post-notifications") { return .post }
        return arguments.contains("-haus-log-notifications") ? .log : nil
    }()

    /// The poster the model uses in place of `system`; nil without either flag.
    static func poster(posting system: any NotificationPosting) -> (any NotificationPosting)? {
        switch mode {
        case .log?: LoggingPoster(forwarding: nil)
        case .post?: LoggingPoster(forwarding: system)
        case nil: nil
        }
    }

    /// A notice the model adds to the notification centre itself (a notification reply's outcome) rather than through
    /// `poster`: logged as the poster logs a request, and to be posted only with `-haus-post-notifications`. True when
    /// the caller should post it.
    static func shouldPost(notice request: UNNotificationRequest) -> Bool {
        guard let mode else { return true }
        let content = request.content
        write("notification posted: thread \(content.threadIdentifier) category \(content.categoryIdentifier), "
            + "title \(content.title.isEmpty ? "empty" : "set"), body \"\(content.body)\", sound \(content.sound == nil ? "no" : "yes")")
        return mode == .post
    }

    /// The newest `message` request of this run, for `MacNotificationDebug`'s actions when nothing is posted.
    static var newestMessage: PlannedNotification? { newest.withLock { $0 } }
    private static let newest = Mutex<PlannedNotification?>(nil)

    struct LoggingPoster: NotificationPosting {
        let forwarding: (any NotificationPosting)?

        func add(_ request: PlannedNotification) async throws {
            do { try await forwarding?.add(request) } catch {
                write("notification add FAILED: \(describe(request)), \(error)")
                throw error
            }
            if request.categoryIdentifier == NotificationIdentity.messageCategory { newest.withLock { $0 = request } }
            write("notification posted: \(describe(request))")
        }

        func deliveredNotifications() async -> [DeliveredNotification] { await forwarding?.deliveredNotifications() ?? [] }

        func removeDelivered(identifiers: [String]) async {
            await forwarding?.removeDelivered(identifiers: identifiers)
            if !identifiers.isEmpty { write("notification removed: \(identifiers.count)") }
        }

        func preparationAllowance(for request: PlannedNotification) -> Duration { forwarding?.preparationAllowance(for: request) ?? .zero }
    }

    /// Which fields are set. A body is quoted only when it is one of the fixed generic texts.
    private static func describe(_ request: PlannedNotification) -> String {
        let fixed = [NotificationPlanner.hiddenBody, NotificationPlanner.hiddenReactionBody, NotificationPlanner.fallbackBody]
        let body = request.body.isEmpty ? "empty" : fixed.contains(request.body) ? "\"\(request.body)\"" : "\(request.body.count) chars"
        let sender = request.communication.map { $0.sender.avatarHash == nil ? "sender without avatar" : "sender with avatar" } ?? "no sender"
        return "thread \(request.threadIdentifier) category \(request.categoryIdentifier), title \(request.title.isEmpty ? "empty" : "set"), "
            + "body \(body), \(sender), destination \(request.destination == nil ? "none" : "set"), sound \(request.playsSound ? "yes" : "no")"
    }

    /// As `MacDebugHooks.log`, from outside the main actor.
    private static func write(_ text: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SSS"
        FileHandle.standardOutput.write(Data("HAUS \(formatter.string(from: Date())) \(text)\n".utf8))
    }
}

/// `MacLifecycleDebug`'s `notify …` steps, for a lab account: what a click on a notification's Reply or Mark as Read
/// does, and the settings that change what is posted.
///
/// - `notify reply [<text>]`, `notify read`: the action on the newest message notification, handed to
///   `NotificationActionCenter` as the notification centre's delegate hands over a clicked one, and its outcome. With
///   `-haus-log-notifications` the newest logged request; otherwise the newest delivered one in Notification Center.
/// - `notify delivered`: what Notification Center holds for the app (see `MacPushProbe`).
/// - `notify state`: each chat's unread count and notification setting, the selected chat and the Dock badge.
/// - `notify messages <chat>`: the chat's read pointer and stored messages (ID prefix, direction and transport state,
///   time, body length, why unreadable), never their text.
/// - `notify previews on|off`, `notify reactions on|off`: the Settings switches.
/// - `notify mute <chat>` (for an hour), `notify unmute <chat>`, `notify mentions <chat>`, `notify all <chat>`: the
///   chat's notification menu.
@MainActor enum MacNotificationDebug {
    static func run(_ argument: String, model: AppModel, window: MacWindowState) async {
        let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = words.count > 1 ? words[1] : ""
        switch words.first ?? "" {
        case "reply": await act(NotificationActionIdentifier.reply, text: rest.isEmpty ? "Reply from a notification" : rest)
        case "read": await act(NotificationActionIdentifier.markRead, text: nil)
        case "delivered": await MacPushProbe.logDelivered()
        case "messages": log("notify messages: \(await model.debugMessageReport(rest))")
        case "state":
            let chats = model.chats.map { "\($0.id) unread \($0.unreadCount)\($0.notification == ChatNotificationSetting() ? "" : " (\($0.notification))")" }
            log("notify state: \(chats.isEmpty ? "no chats" : chats.joined(separator: ", ")); selected \(window.selection ?? "none"), "
                + "Dock badge \(NSApp.dockTile.badgeLabel ?? "none")")
        case "previews":
            await model.setNotificationPreviews(rest == "on")
            log("notify previews: \(model.notificationPreviewsEnabled ? "on" : "off")")
        case "reactions":
            await model.updatePreferences { $0.reactionNotifications = rest == "on" }
            log("notify reactions: \(model.accountPreferences.reactionNotifications ? "on" : "off")")
        case "mute": await model.muteChat(rest, for: .oneHour)
        case "unmute": await model.unmuteChat(rest)
        case "mentions": await model.setNotificationLevel(rest, .mentions)
        case "all": await model.setNotificationLevel(rest, .all)
        default: log("notify \(argument): unknown")
        }
    }

    /// Reply or Mark as Read, parsed from the request's user info and category as the delegate parses a response.
    private static func act(_ action: String, text: String?) async {
        let content: (userInfo: [AnyHashable: Any], category: String)?
        if MacDebugNotificationLog.mode == .log {
            content = MacDebugNotificationLog.newestMessage.map { ($0.userInfo as [AnyHashable: Any], $0.categoryIdentifier) }
        } else {
            content = await UNUserNotificationCenter.current().deliveredNotifications()
                .filter { $0.request.content.categoryIdentifier == NotificationIdentity.messageCategory }
                .max { $0.date < $1.date }
                .map { ($0.request.content.userInfo, $0.request.content.categoryIdentifier) }
        }
        guard let content else { log("notify \(action): no message notification"); return }
        guard let request = NotificationActionRequest(userInfo: content.userInfo, categoryIdentifier: content.category,
                                                      actionIdentifier: action, text: text) else {
            log("notify \(action): not an action request")
            return
        }
        let clock = ContinuousClock(), start = clock.now
        let outcome = await NotificationActionCenter.shared.perform(request)
        log("notify \(action): \(outcome.rawValue) after \(Int((clock.now - start) / .milliseconds(1))) ms")
    }

    private static func log(_ text: String) { MacDebugHooks.log(text) }
}
#endif
