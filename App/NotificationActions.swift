import Foundation
#if os(iOS)
import UIKit
#endif
import UserNotifications
import MessageStore
import MessagingCore

enum NotificationActionIdentifier {
    static let reply = "reply"
    static let markRead = "mark-read"
}

enum NotificationActionCopy {
    static let replyFailed = "Couldn't send your reply. Open the chat to review."
    static let replyRejected = "Couldn't send your reply."
    // Shown under the rejected notice's identifier, which it replaces.
    static let replySavedForUpgrade = "Open Haus XMPP to finish updating; your reply was saved."
    static let savedReplyExpired = "A reply you typed before the update was not sent because it is more than a day old."
    static let replyRejectedIdentifier = "e-rejected"
}

enum NotificationCategories {
    // Neither action asks for authentication; iOS's "Allow access when locked" decides lock-screen visibility. Sending
    // needs only after-first-unlock data, so before the first unlock the reply is rejected with the content-free
    // notice.
    static var all: Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(identifier: NotificationActionIdentifier.reply, title: "Reply", options: [],
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let markRead = UNNotificationAction(identifier: NotificationActionIdentifier.markRead, title: "Mark as Read", options: [],
                                            icon: UNNotificationActionIcon(systemImageName: "envelope.open"))
        let message = UNNotificationCategory(identifier: NotificationIdentity.messageCategory, actions: [reply, markRead], intentIdentifiers: [],
                                             hiddenPreviewsBodyPlaceholder: NotificationPlanner.hiddenBody, options: [])
        let notice = UNNotificationCategory(identifier: NotificationIdentity.noticeCategory, actions: [], intentIdentifiers: [],
                                            hiddenPreviewsBodyPlaceholder: NotificationPlanner.hiddenBody, options: [])
        let reaction = UNNotificationCategory(identifier: NotificationIdentity.reactionCategory, actions: [], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: NotificationPlanner.hiddenReactionBody, options: [])
        let fallback = UNNotificationCategory(identifier: NotificationIdentity.fallbackCategory, actions: [], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: NotificationPlanner.fallbackBody, options: [])
        return [message, notice, reaction, fallback]
    }
}

// Holds the opaque destination and, for a reply, the typed text; never an address.
struct NotificationActionRequest: Sendable, Equatable, CustomStringConvertible {
    enum Kind: Sendable, Equatable { case markRead, reply(String) }
    let destination: NotificationDestination
    let kind: Kind

    init?(userInfo: [AnyHashable: Any], categoryIdentifier: String, actionIdentifier: String, text: String?) {
        guard categoryIdentifier == NotificationIdentity.messageCategory,
              let payload = userInfo[NotificationDestination.userInfoKey] as? [String: String],
              let destination = NotificationDestination(payload: payload) else { return nil }
        switch actionIdentifier {
        case NotificationActionIdentifier.markRead: kind = .markRead
        case NotificationActionIdentifier.reply:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_384 else { return nil }
            kind = .reply(text)
        default: return nil
        }
        self.destination = destination
    }

    init(destination: NotificationDestination, kind: Kind) { self.destination = destination; self.kind = kind }
    var description: String { "NotificationActionRequest(<redacted>)" }
}

// Only the outcome is logged; never text or addresses.
enum NotificationActionOutcome: String, Sendable, Equatable {
    case rejected
    case unavailable
    case markedRead
    // Written on an encrypted session (acknowledged or still unconfirmed); never plaintext.
    case replySent
    case replyHeld
    case replyFailed
    case replySavedForUpgrade
}

enum ReplyDelivery: Sendable, Equatable { case sent, held }

// Measured from the delegate handover, before model start-up and queued actions. Network work ends at `deadline`; the
// teardown (disconnect, consumer join, presentation, lease release) gets `teardown` after it, so the lease is back
// before the system's background time runs out.
struct NotificationActionBudget: Sendable, Equatable {
    static let cap: Duration = .seconds(20)
    static let teardown: Duration = .seconds(9)
    static let leaseWait: Duration = .seconds(6)
    static let presentation: Duration = .seconds(4)

    let start: ContinuousClock.Instant
    // The watchdog closes the connection at this instant.
    let deadline: ContinuousClock.Instant

    init(start: ContinuousClock.Instant, backgroundTimeRemaining: TimeInterval) {
        self.start = start
        var network = Self.cap
        // In the foreground UIKit reports `greatestFiniteMagnitude`, which is finite; the 3600 s bound leaves only
        // the cap.
        if backgroundTimeRemaining.isFinite, backgroundTimeRemaining < 3_600 {
            network = max(.zero, min(network, .seconds(max(0, backgroundTimeRemaining)) - Self.teardown))
        }
        deadline = start + network
    }

    func leaseDeadline(from now: ContinuousClock.Instant) -> ContinuousClock.Instant { min(now + Self.leaseWait, deadline) }
    func remaining(at now: ContinuousClock.Instant, atMost limit: Duration) -> Duration { max(.zero, min(limit, deadline - now)) }
    func presentationTimeout(at now: ContinuousClock.Instant) -> Duration {
        max(.zero, min(Self.presentation, deadline + Self.teardown - .seconds(2) - now))
    }
}

@MainActor protocol NotificationActionEnvironment: AnyObject {
    func authorizedNotificationAccount() -> String?
    func resolveNotificationMessage(_ destination: NotificationDestination, account: String) async -> StoredMessage?
    // Without the live session or the lease the action still reads and queues locally. False only when there is no
    // storage. Nothing network-bound outlasts `budget.deadline`.
    func beginNotificationAction(account: String, chatID: String, budget: NotificationActionBudget) async -> Bool
    func markNotificationMessageRead(_ message: StoredMessage) async throws
    func clearReadNotifications(for message: StoredMessage) async
    func enqueueNotificationReply(_ text: String, to message: StoredMessage) async throws -> String
    func deliverNotificationReply(_ messageID: String, account: String) async -> ReplyDelivery
    func flushNotificationAction(account: String) async
    func reportNotificationReply(failed: Bool, for message: StoredMessage) async
    func endNotificationAction() async
}

// The account is checked before anything is touched and again before the reply is saved. A reply that is not sent is
// never retried as plaintext and is always reported.
enum NotificationActionHandler {
    @MainActor static func perform(_ request: NotificationActionRequest, budget: NotificationActionBudget,
                                   in environment: some NotificationActionEnvironment) async -> NotificationActionOutcome {
        guard let account = environment.authorizedNotificationAccount(), request.destination.belongs(to: account),
              let message = await environment.resolveNotificationMessage(request.destination, account: account),
              environment.authorizedNotificationAccount() == account else { return .rejected }
        guard await environment.beginNotificationAction(account: account, chatID: message.chatID, budget: budget) else {
            if case .reply = request.kind { await environment.reportNotificationReply(failed: true, for: message) }
            return .unavailable
        }
        let outcome = await act(request.kind, on: message, account: account, in: environment)
        await environment.endNotificationAction()
        return outcome
    }

    @MainActor private static func act(_ kind: NotificationActionRequest.Kind, on message: StoredMessage, account: String,
                                       in environment: some NotificationActionEnvironment) async -> NotificationActionOutcome {
        // Reading is local-first: a failure to save it does not stop a reply.
        let read = (try? await environment.markNotificationMessageRead(message)) != nil
        if read { await environment.clearReadNotifications(for: message) }
        guard case let .reply(text) = kind else {
            await environment.flushNotificationAction(account: account)
            return read ? .markedRead : .unavailable
        }
        // Signed out or switched accounts while the transport was taken: nothing is saved for the old account.
        guard environment.authorizedNotificationAccount() == account else { return .rejected }
        let id: String
        do { id = try await environment.enqueueNotificationReply(text, to: message) }
        catch {
            await environment.reportNotificationReply(failed: true, for: message)
            return .replyFailed
        }
        let delivery = await environment.deliverNotificationReply(id, account: account)
        await environment.reportNotificationReply(failed: delivery != .sent, for: message)
        return delivery == .sent ? .replySent : .replyHeld
    }

    // Queued unencrypted for the drain to seal; a plain answer, not an XEP-0461 reply.
    static func replyMessage(_ text: String, id: String, to message: StoredMessage) -> StoredMessage {
        StoredMessage(id: id, accountID: message.accountID, chatID: message.chatID, senderID: message.accountID, body: text,
                      isOutgoing: true, encryptionProfile: "pending")
    }
}

#if os(iOS)
typealias BackgroundTaskID = UIBackgroundTaskIdentifier
#else
struct BackgroundTaskID: Equatable {
    let rawValue: Int
    static let invalid = BackgroundTaskID(rawValue: 0)
}
#endif

@MainActor protocol NotificationActionBackgroundTime: AnyObject {
    // A task still not ended when `expiration` returns gets the process terminated.
    func begin(expiration: @escaping @MainActor () -> Void) -> BackgroundTaskID
    func end(_ task: BackgroundTaskID)
    var remaining: TimeInterval { get }
}

#if os(iOS)
@MainActor final class UIKitBackgroundTime: NotificationActionBackgroundTime {
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "Notification action") { MainActor.assumeIsolated { expiration() } }
    }
    func end(_ task: UIBackgroundTaskIdentifier) { UIApplication.shared.endBackgroundTask(task) }
    var remaining: TimeInterval { UIApplication.shared.backgroundTimeRemaining }
}
#else
@MainActor final class ProcessActivityBackgroundTime: NotificationActionBackgroundTime {
    private var activities: [Int: BackgroundActivity] = [:]
    private var next = 1

    func begin(expiration: @escaping @MainActor () -> Void) -> BackgroundTaskID {
        let id = next
        next += 1
        activities[id] = BackgroundActivity("Notification action")
        return BackgroundTaskID(rawValue: id)
    }
    func end(_ task: BackgroundTaskID) { activities.removeValue(forKey: task.rawValue)?.end() }
    var remaining: TimeInterval { .greatestFiniteMagnitude }
}
#endif

@MainActor final class NotificationActionCenter {
    #if os(iOS)
    static let shared = NotificationActionCenter(time: UIKitBackgroundTime(), reportRejectedReply: postRejectedReply)
    #else
    static let shared = NotificationActionCenter(time: ProcessActivityBackgroundTime(), reportRejectedReply: postRejectedReply)
    #endif
    var handler: (@MainActor (NotificationActionRequest, NotificationActionBudget) async -> NotificationActionOutcome)?
    var abort: (@MainActor () -> Bool)?
    private let time: any NotificationActionBackgroundTime
    private let reportRejectedReply: @MainActor () async -> Void
    private var queue: Task<NotificationActionOutcome, Never>?

    init(time: any NotificationActionBackgroundTime, reportRejectedReply: @escaping @MainActor () async -> Void) {
        self.time = time
        self.reportRejectedReply = reportRejectedReply
    }

    @discardableResult
    func perform(_ request: NotificationActionRequest, waitingForHandler limit: Duration = .seconds(5)) async -> NotificationActionOutcome {
        let task = ActionBackgroundTask(time: time)
        task.begin { [weak self] in
            // Termination releases the kernel lease but a suspended owner keeps it, stalling every extension run. So
            // while the action holds the lease the task is left to expire and the system ends the process; otherwise
            // the connection closes and the task ends here.
            if self?.abort?() == true { return }
            task.end()
        }
        let budget = NotificationActionBudget(start: .now, backgroundTimeRemaining: time.remaining)
        let previous = queue
        let run = Task { @MainActor [weak self] () -> NotificationActionOutcome in
            _ = await previous?.value
            guard let self else { return .rejected }
            let clock = ContinuousClock(), waitEnd = min(clock.now + limit, budget.deadline)
            while self.handler == nil, clock.now < waitEnd { try? await Task.sleep(for: .milliseconds(50)) }
            let outcome = await self.handler?(request, budget) ?? .rejected
            // Rejected means nothing was saved: the typed text is gone, so the user hears about it, without naming a
            // chat or an account the app could not attribute.
            if outcome == .rejected, case .reply = request.kind { await self.reportRejectedReply() }
            return outcome
        }
        queue = run
        let outcome = await run.value
        task.end()
        return outcome
    }

    static func postRejectedReply() async { await postReplyNotice(NotificationActionCopy.replyRejected) }

    static func postSavedReply() async { await postReplyNotice(NotificationActionCopy.replySavedForUpgrade) }

    static func postExpiredSavedReply() async { await postReplyNotice(NotificationActionCopy.savedReplyExpired) }

    private static func postReplyNotice(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.body = body
        content.categoryIdentifier = NotificationIdentity.noticeCategory
        content.sound = .default
        let request = UNNotificationRequest(identifier: NotificationActionCopy.replyRejectedIdentifier, content: content, trigger: nil)
        #if DEBUG && os(macOS)
        guard MacDebugNotificationLog.shouldPost(notice: request) else { return }
        #endif
        try? await UNUserNotificationCenter.current().add(request)
    }
}

@MainActor private final class ActionBackgroundTask {
    private let time: any NotificationActionBackgroundTime
    private var id = BackgroundTaskID.invalid
    init(time: any NotificationActionBackgroundTime) { self.time = time }
    func begin(expiration: @escaping @MainActor () -> Void) { id = time.begin(expiration: expiration) }
    func end() {
        guard id != .invalid else { return }
        time.end(id)
        id = .invalid
    }
}

// Only local requests for this account's messages show, never for the open chat; remote requests (gateway placeholder,
// extension fallback) stay hidden.
enum ForegroundPresentation {
    struct Request: Sendable, Equatable {
        var identifier = ""
        var isRemote: Bool
        var categoryIdentifier: String
        var threadIdentifier: String
        var playsSound: Bool
        var accountScope: String?
    }

    static func options(for request: Request, accountID: String, openChatID: String?) -> UNNotificationPresentationOptions {
        // The rejected-reply notice names no account; it answers something the user just did, so it shows.
        if !request.isRemote, request.identifier == NotificationActionCopy.replyRejectedIdentifier,
           request.categoryIdentifier == NotificationIdentity.noticeCategory { return [.banner, .list, .sound] }
        guard !request.isRemote, !accountID.isEmpty,
              NotificationIdentity.isMessageRun(category: request.categoryIdentifier) || request.categoryIdentifier == NotificationIdentity.reactionCategory,
              let scope = request.accountScope,
              NotificationDestination(accountID: accountID, messageID: UUID().uuidString)?.accountScope == scope else { return [] }
        if let openChatID, request.threadIdentifier == NotificationIdentity.thread(accountID: accountID, chatID: openChatID) { return [] }
        return request.playsSound ? [.banner, .list, .sound] : [.banner, .list]
    }

    static func request(_ notification: UNNotification) -> Request {
        let content = notification.request.content
        let destination = (content.userInfo[NotificationDestination.userInfoKey] as? [String: String]).flatMap(NotificationDestination.init(payload:))
        let reference = (content.userInfo[NotificationReference.userInfoKey] as? [String: String]).flatMap(NotificationReference.init(payload:))
        let failed = (content.userInfo[NotificationNavigation.replyFailureKey] as? [String: String]).flatMap(NotificationDestination.init(payload:))
        return Request(identifier: notification.request.identifier, isRemote: notification.request.trigger is UNPushNotificationTrigger, categoryIdentifier: content.categoryIdentifier,
                       threadIdentifier: content.threadIdentifier, playsSound: content.sound != nil,
                       accountScope: destination?.accountScope ?? reference?.accountScope ?? failed?.accountScope)
    }
}

@MainActor final class ForegroundNotificationState {
    static let shared = ForegroundNotificationState()
    var accountID = ""
    var openChatID: String?
}
