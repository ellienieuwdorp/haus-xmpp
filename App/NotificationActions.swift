import Foundation
import UserNotifications
import MessageStore
import MessagingCore

/// Reply and Mark as Read on a message notification (wave 2, stream E; docs/development/notification-actions.md).
enum NotificationActionIdentifier {
    static let reply = "reply"
    static let markRead = "mark-read"
}

/// Copy the notification actions post and show.
enum NotificationActionCopy {
    static let replyFailed = "Couldn't send your reply. Open the chat to review."
}

enum NotificationCategories {
    /// `message` names one authenticated incoming message and offers Reply and Mark as Read. Neither asks for
    /// authentication, as in Messages: iOS's own "Allow access when locked" settings decide whether they appear on the
    /// lock screen. Sending needs only after-first-unlock data (keychain and store), so it works on a locked phone that
    /// was unlocked once since boot; before that the reply is reported as not sent. `notice` (review, placeholder,
    /// summary, failed reply) and `fallback` have no actions.
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
        let fallback = UNNotificationCategory(identifier: NotificationIdentity.fallbackCategory, actions: [], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: NotificationPlanner.fallbackBody, options: [])
        return [message, notice, fallback]
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
}

/// Where a reply stands once the session tried to deliver it.
enum ReplyDelivery: Sendable, Equatable { case sent, held }

/// The steps an action needs, so the decision logic is testable with fakes. The app implements it on `AppModel`.
@MainActor protocol NotificationActionEnvironment: AnyObject {
    /// The account the protected saved credentials, the session and the selected account all agree on; nil when
    /// signed out, switching, or in a test session.
    func authorizedNotificationAccount() -> String?
    /// Tap routing's resolution: an existing incoming encrypted message of `account`.
    func resolveNotificationMessage(_ destination: NotificationDestination, account: String) async -> StoredMessage?
    /// Takes the transport for this action: the live foreground session, or the lease plus a background connection.
    /// Without either (the lease stayed busy, no network) the action still reads and queues locally. False only when
    /// there is no storage; nothing has changed then.
    func beginNotificationAction(account: String, chatID: String) async -> Bool
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
    /// Leaves the transport as it found it: disconnected and the lease released if the app is still in the background.
    func endNotificationAction() async
}

/// The decision logic of Reply and Mark as Read. The account is checked before anything is touched, and again
/// before the reply is saved; a reply that is not sent is never retried as plaintext and always reported.
enum NotificationActionHandler {
    @MainActor static func perform(_ request: NotificationActionRequest, in environment: some NotificationActionEnvironment) async -> NotificationActionOutcome {
        guard let account = environment.authorizedNotificationAccount(), request.destination.belongs(to: account),
              let message = await environment.resolveNotificationMessage(request.destination, account: account),
              environment.authorizedNotificationAccount() == account else { return .rejected }
        guard await environment.beginNotificationAction(account: account, chatID: message.chatID) else {
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
}

/// Lets the delegate reach the model, which may still be starting after a background launch. The latest model to
/// register handles actions, one at a time.
@MainActor final class NotificationActionCenter {
    static let shared = NotificationActionCenter()
    var handler: (@MainActor (NotificationActionRequest) async -> NotificationActionOutcome)?
    private var queue: Task<NotificationActionOutcome, Never>?

    @discardableResult
    func perform(_ request: NotificationActionRequest, waitingForHandler limit: Duration = .seconds(5)) async -> NotificationActionOutcome {
        let previous = queue
        let task = Task { @MainActor in
            _ = await previous?.value
            let clock = ContinuousClock(), start = clock.now
            while handler == nil, clock.now - start < limit { try? await Task.sleep(for: .milliseconds(50)) }
            guard let handler else { return NotificationActionOutcome.rejected }
            return await handler(request)
        }
        queue = task
        return await task.value
    }
}

/// Which foreground notifications show (wave 2, stream E). Only local requests the app or the extension posted for
/// this account's messages, and never for the chat that is open; a remote request (the gateway's placeholder or the
/// extension's fallback) and anything unknown stays hidden, as before.
enum ForegroundPresentation {
    struct Request: Sendable, Equatable {
        var isRemote: Bool
        var categoryIdentifier: String
        var threadIdentifier: String
        var playsSound: Bool
        /// The account scope the request names (destination, cleanup reference or failed-reply destination).
        var accountScope: String?
    }

    /// `openChatID` is the conversation on screen; nil on the chat list.
    static func options(for request: Request, accountID: String, openChatID: String?) -> UNNotificationPresentationOptions {
        guard !request.isRemote, NotificationIdentity.isMessageRun(category: request.categoryIdentifier), !accountID.isEmpty,
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
        return Request(isRemote: notification.request.trigger is UNPushNotificationTrigger, categoryIdentifier: content.categoryIdentifier,
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
