import Foundation
#if os(iOS)
import UIKit
#endif
import UserNotifications
import MessageStore
import MessagingCore

/// Reply and Mark as Read on a message notification.
enum NotificationActionIdentifier {
    static let reply = "reply"
    static let markRead = "mark-read"
}

/// Copy the notification actions post and show.
enum NotificationActionCopy {
    static let replyFailed = "Couldn't send your reply. Open the chat to review."
    /// A reply the app could not attribute to the current account (signed out, switched, keychain locked before the
    /// first unlock, message gone): no chat, no account, nothing to route to.
    static let replyRejected = "Couldn't send your reply."
    /// A reply typed while this version waited to upgrade the previous version's data: kept, and queued once the app
    /// finished updating in front. Shown under the rejected notice's identifier, which it replaces.
    static let replySavedForUpgrade = "Open Haus XMPP to finish updating; your reply was saved."
    /// A saved reply found more than a day after it was typed: dropped instead of sent late.
    static let savedReplyExpired = "A reply you typed before the update was not sent because it is more than a day old."
    /// One content-free notice for every rejected reply; posting again replaces it.
    static let replyRejectedIdentifier = "e-rejected"
}

enum NotificationCategories {
    /// `message` names one authenticated incoming message and offers Reply and Mark as Read. Neither asks for
    /// authentication, as in Messages: iOS's own "Allow access when locked" settings decide whether they appear on the
    /// lock screen. Sending needs only after-first-unlock data (keychain and store), so it works on a locked phone that
    /// was unlocked once since boot. Before that the account cannot be read: the reply is rejected and only the
    /// content-free "Couldn't send your reply." notice is posted (`NotificationActionCenter`). `notice` (review,
    /// placeholder, summary, failed reply), `reaction` and `fallback` have no actions.
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

/// One action on one notification, parsed before leaving the delegate callback. Holds the opaque destination and,
/// for a reply, the typed text; never an address.
struct NotificationActionRequest: Sendable, Equatable, CustomStringConvertible {
    enum Kind: Sendable, Equatable { case markRead, reply(String) }
    let destination: NotificationDestination
    let kind: Kind

    /// Nil unless the request is in the `message` category, names one message, and (for Reply) carries text the
    /// composer would accept.
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

/// What happened to one action. Only the outcome is logged; never text or addresses.
enum NotificationActionOutcome: String, Sendable, Equatable {
    /// Not the current authorized account, signed out, or no such incoming encrypted message: nothing was done.
    case rejected
    /// No storage, or the read could not be saved; nothing was sent.
    case unavailable
    case markedRead
    /// Written to the server on an encrypted session (acknowledged or still unconfirmed); never plaintext.
    case replySent
    /// Saved and queued, not sent: the chat needs a trust decision or keys, or no session was ready. Stays queued
    /// exactly as the composer leaves it; the user was told.
    case replyHeld
    /// Could not be saved at all; the user was told.
    case replyFailed
    /// Kept for after the upgrade the app has not run yet (launched into the background); nothing was sent.
    case replySavedForUpgrade
}

/// Where a reply stands once the session tried to deliver it.
enum ReplyDelivery: Sendable, Equatable { case sent, held }

/// The time one action may use, measured from the moment the delegate handed it over: before the model finished
/// starting, before an action queued ahead of it and before `prepare()`. The network work ends at `deadline`; the
/// teardown (disconnect, consumer join, presenting what arrived, releasing the lease) has `teardown` after it, so the
/// lease is back well before the system's background time runs out.
struct NotificationActionBudget: Sendable, Equatable {
    /// The network part never runs longer than the extension's own budget.
    static let cap: Duration = .seconds(20)
    /// Kept free after `deadline` for the teardown.
    static let teardown: Duration = .seconds(9)
    /// How long the action waits for the lifecycle slot and the store's lease together, as the extension waits for the app.
    static let leaseWait: Duration = .seconds(6)
    /// How long presenting what arrived on the action's connection may take.
    static let presentation: Duration = .seconds(4)

    let start: ContinuousClock.Instant
    /// Everything that needs the network stops here: the watchdog closes the connection at this instant.
    let deadline: ContinuousClock.Instant

    /// `backgroundTimeRemaining` is UIKit's value right after the action's background task began. In front of the app
    /// it is effectively unlimited (`greatestFiniteMagnitude`) and only the cap applies.
    init(start: ContinuousClock.Instant, backgroundTimeRemaining: TimeInterval) {
        self.start = start
        var network = Self.cap
        if backgroundTimeRemaining.isFinite, backgroundTimeRemaining < 3_600 {
            network = max(.zero, min(network, .seconds(max(0, backgroundTimeRemaining)) - Self.teardown))
        }
        deadline = start + network
    }

    /// When the waits before connecting give up: `leaseWait` after `now`, never past the deadline.
    func leaseDeadline(from now: ContinuousClock.Instant) -> ContinuousClock.Instant { min(now + Self.leaseWait, deadline) }
    /// How long a step that must end by the deadline may still take (zero once it passed).
    func remaining(at now: ContinuousClock.Instant, atMost limit: Duration) -> Duration { max(.zero, min(limit, deadline - now)) }
    /// Presentation after the connection closed: at most `presentation`, ending 2 s before the reserved teardown does.
    func presentationTimeout(at now: ContinuousClock.Instant) -> Duration {
        max(.zero, min(Self.presentation, deadline + Self.teardown - .seconds(2) - now))
    }
}

/// The steps an action needs, so the decision logic is testable with fakes. The app implements it on `AppModel`.
@MainActor protocol NotificationActionEnvironment: AnyObject {
    /// The account the protected saved credentials, the session and the selected account all agree on; nil when
    /// signed out, switching, or in a test session.
    func authorizedNotificationAccount() -> String?
    /// Tap routing's resolution: an existing incoming encrypted message of `account`.
    func resolveNotificationMessage(_ destination: NotificationDestination, account: String) async -> StoredMessage?
    /// Takes the transport for this action: the live foreground session, or the lease plus a background connection.
    /// Without either (the lease stayed busy, no network, the budget was spent) the action still reads and queues
    /// locally. False only when there is no storage; nothing has changed then. Nothing network-bound outlasts
    /// `budget.deadline`.
    func beginNotificationAction(account: String, chatID: String, budget: NotificationActionBudget) async -> Bool
    /// Moves the read pointer through `message`, publishes XEP-0490 and queues the XEP-0333 marker when the
    /// read-receipts switch allows (the store enforces it).
    func markNotificationMessageRead(_ message: StoredMessage) async throws
    /// Removes delivered notifications that are now read, and this message's own.
    func clearReadNotifications(for message: StoredMessage) async
    /// Queues the reply through the composer's outbox; returns its message ID. Throws when it could not be saved.
    func enqueueNotificationReply(_ text: String, to message: StoredMessage) async throws -> String
    /// Seals and sends what the outbox holds while the session lasts, and reports where the reply stands.
    func deliverNotificationReply(_ messageID: String, account: String) async -> ReplyDelivery
    /// Delivers the queued marker and read state when there is no reply.
    func flushNotificationAction(account: String) async
    /// Posts the one "Couldn't send your reply" notice of the chat, or removes a stale one after a sent reply.
    func reportNotificationReply(failed: Bool, for message: StoredMessage) async
    /// Leaves the transport as it found it: disconnected, what arrived on the action's connection presented as the
    /// extension would, and the lease released if the app is still in the background.
    func endNotificationAction() async
}

/// The decision logic of Reply and Mark as Read. The account is checked before anything is touched, and again
/// before the reply is saved; a reply that is not sent is never retried as plaintext and always reported (a rejected
/// one by `NotificationActionCenter`, which knows no chat to name).
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

    /// The outbox row a notification reply becomes: a plain answer in the chat of `message`, queued unencrypted for
    /// the drain to seal (not an XEP-0461 reply).
    static func replyMessage(_ text: String, id: String, to message: StoredMessage) -> StoredMessage {
        StoredMessage(id: id, accountID: message.accountID, chatID: message.chatID, senderID: message.accountID, body: text,
                      isOutgoing: true, encryptionProfile: "pending")
    }
}

#if os(iOS)
typealias BackgroundTaskID = UIBackgroundTaskIdentifier
#else
/// The Mac has no background tasks; an action there runs in a process that keeps running, under a `ProcessInfo`
/// activity so App Nap does not slow it.
struct BackgroundTaskID: Equatable {
    let rawValue: Int
    static let invalid = BackgroundTaskID(rawValue: 0)
}
#endif

/// The system's background time, behind a seam so the center's task handling is testable.
@MainActor protocol NotificationActionBackgroundTime: AnyObject {
    /// Begins a background task. The system calls `expiration` on the main thread when the time runs out; a task
    /// still not ended when it returns gets the process terminated.
    func begin(expiration: @escaping @MainActor () -> Void) -> BackgroundTaskID
    func end(_ task: BackgroundTaskID)
    /// `UIApplication.backgroundTimeRemaining`: effectively unlimited in front of the app.
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
/// A Mac action never expires: its own budget's cap bounds it, and the activity keeps App Nap away meanwhile.
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

/// Lets the delegate reach the model, which may still be starting after a background launch. The latest model to
/// register handles actions, one at a time. Each request runs inside its own background task, begun the moment the
/// delegate hands it over; the action's budget is measured from there.
@MainActor final class NotificationActionCenter {
    #if os(iOS)
    static let shared = NotificationActionCenter(time: UIKitBackgroundTime(), reportRejectedReply: postRejectedReply)
    #else
    static let shared = NotificationActionCenter(time: ProcessActivityBackgroundTime(), reportRejectedReply: postRejectedReply)
    #endif
    var handler: (@MainActor (NotificationActionRequest, NotificationActionBudget) async -> NotificationActionOutcome)?
    /// The system is ending the background time: closes the running action's connection and answers whether the action
    /// still holds, or is acquiring, the store's transport lease.
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
            // Termination releases the kernel lease; a suspended owner keeps it, and every extension run would wait
            // and fall back until the app ran again. So while the action holds the lease the task is left to expire and
            // the system ends the process, as for the app's own quiesce. Otherwise the connection is closed and the
            // task ends here.
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

    /// The content-free notice of a rejected reply: no title, no chat, no destination; one at a time.
    static func postRejectedReply() async { await postReplyNotice(NotificationActionCopy.replyRejected) }

    /// The same notice, for a reply kept until the upgrade.
    static func postSavedReply() async { await postReplyNotice(NotificationActionCopy.replySavedForUpgrade) }

    /// The same notice, for saved replies dropped as too old.
    static func postExpiredSavedReply() async { await postReplyNotice(NotificationActionCopy.savedReplyExpired) }

    private static func postReplyNotice(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.body = body
        content.categoryIdentifier = NotificationIdentity.noticeCategory
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: NotificationActionCopy.replyRejectedIdentifier, content: content, trigger: nil))
    }
}

/// Ends one background task exactly once, from the expiration handler or when the action returned.
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

/// Which foreground notifications show. Only local requests the app or the extension posted for
/// this account's messages, and never for the chat that is open; a remote request (the gateway's placeholder or the
/// extension's fallback) and anything unknown stays hidden, as before.
enum ForegroundPresentation {
    struct Request: Sendable, Equatable {
        var identifier = ""
        var isRemote: Bool
        var categoryIdentifier: String
        var threadIdentifier: String
        var playsSound: Bool
        /// The account scope the request names (destination, cleanup reference or failed-reply destination).
        var accountScope: String?
    }

    /// `openChatID` is the conversation on screen; nil on the chat list.
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

/// What the foreground presentation rule reads: the selected account and the open conversation. Kept by `AppModel`.
@MainActor final class ForegroundNotificationState {
    static let shared = ForegroundNotificationState()
    var accountID = ""
    var openChatID: String?
}
