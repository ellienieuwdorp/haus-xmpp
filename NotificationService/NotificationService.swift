import Foundation
import UserNotifications
import MessagingCore

/// Thin shell: every remote request joins the process's run (`NotificationRunCoordinator`) and finishes with its outcome.
/// A settled run posted one local request per new message, so the remote alert is suppressed with empty content
/// (the filtering entitlement). Anything else shows the generic fallback; unknown is never suppressed.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    /// One per process: `didReceive` may arrive concurrently for coalesced pushes, on this or another instance.
    private static let coordinator = NotificationRunCoordinator { progress in await ExtensionRun.run(progress) }

    private let lock = NSLock()
    private var deliveries: [UUID: RemoteDelivery] = [:]

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let ticket = UUID()
        let delivery = RemoteDelivery(request: request, handler: contentHandler)
        lock.withLock { deliveries[ticket] = delivery }
        Task {
            #if DEBUG && os(macOS)
            // The Mac extension's storage probe (NotificationServiceMac/MacExtensionProbe.swift), only when the app armed
            // it; never in a release build. The delivery is registered first, so an expiry during the probe still answers.
            if let arm = MacExtensionProbe.takeArm() {
                if await MacExtensionProbe.record(delivery.probedRequest, arm: arm) == .suppress { delivery.suppress() }
                guard !delivery.isFinished else {
                    _ = lock.withLock { deliveries.removeValue(forKey: ticket) }
                    return
                }
            }
            #endif
            let outcome = await Self.coordinator.deliver(ticket: ticket)
            delivery.finish(outcome)
            _ = lock.withLock { deliveries.removeValue(forKey: ticket) }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        let pending = lock.withLock {
            defer { deliveries.removeAll() }
            return deliveries
        }
        for (ticket, delivery) in pending { delivery.finish(Self.coordinator.expire(ticket: ticket)) }
    }
}

/// Calls the system's content handler exactly once per remote request.
private final class RemoteDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let request: UNNotificationRequest
    private var handler: ((UNNotificationContent) -> Void)?

    init(request: UNNotificationRequest, handler: @escaping (UNNotificationContent) -> Void) {
        self.request = request; self.handler = handler
    }

    func finish(_ outcome: NotificationRunOutcome) {
        guard let callback = lock.withLock({ () -> ((UNNotificationContent) -> Void)? in
            defer { handler = nil }
            return handler
        }) else { return }
        if case let .settled(report) = outcome {
            // Every local add already completed: empty content suppresses the remote alert (no title, body or sound).
            // The badge is the one field it may carry: unread outside muted chats, when the run knew it.
            let content = UNMutableNotificationContent()
            content.badge = report.badge.map { NSNumber(value: $0) }
            callback(content)
            return
        }
        // Plan D2: generic, no message content, the fallback category, and the identifier the system gave this request
        // (the gateway's per-registration collapse ID), so repeated fallbacks replace each other.
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.title = ""
        content.subtitle = ""
        content.body = NotificationPlanner.fallbackBody
        content.categoryIdentifier = NotificationIdentity.fallbackCategory
        content.threadIdentifier = ""
        content.userInfo = [:]
        content.attachments = []
        // Unknown: leave the icon badge as it is.
        content.badge = nil
        callback(content)
    }
}

#if DEBUG && os(macOS)
/// For the Mac extension's storage probe only.
extension RemoteDelivery {
    var probedRequest: UNNotificationRequest { request }
    var isFinished: Bool { lock.withLock { handler == nil } }

    /// Empty content, so the filtering entitlement hides the remote alert.
    func suppress() {
        guard let callback = lock.withLock({ () -> ((UNNotificationContent) -> Void)? in
            defer { handler = nil }
            return handler
        }) else { return }
        callback(UNMutableNotificationContent())
    }
}
#endif

/// One run in this process: load the protected account, catch up under the lease, post, settle, and record counts.
private enum ExtensionRun {
    static func run(_ progress: NotificationRunProgress) async -> NotificationRunOutcome {
        var directory: URL?
        let outcome: NotificationRunOutcome
        do {
            // The shared directory first, so that even a run without an account leaves a diagnostic record.
            let root: URL
            do { root = try await SharedStorage.directory(migrate: false) } catch { throw NotificationRunError.protectedDataUnavailable }
            directory = root
            // A restore of the previous version's data is under way or done: that data is the app's alone.
            guard !PreUpgradeHold.isHeld(groupRoot: root.deletingLastPathComponent()) else { throw NotificationRunError.upgradePending }
            guard let account = try NotificationAccount.load(), account.push != nil else { throw NotificationRunError.noAccount }
            let key: Data
            do { key = try EncryptionKeychain.load(storageID: "primary", allowCreation: false) }
            catch { throw NotificationRunError.protectedDataUnavailable }
            let accountID = account.accountID
            let presenter = NotificationPresenter(posting: UserNotificationPoster(avatarData: { hash in
                // The app's pre-scaled copy of a verified avatar, read as bytes: nothing is decoded in the extension.
                AvatarStore.notificationImageData(root: root, account: accountID, hash: hash)
            }))
            try await BackgroundSynchronizer().synchronize(databaseURL: root.appending(path: "messages.sqlite"), wrappingKey: key,
                account: BackgroundAccount(route: account.route, domain: account.domain, username: account.username,
                                           password: account.password, requiresSCRAM: account.requiresSCRAM,
                                           resource: SharedSession.resource(accountID: accountID),
                                           push: PushRegistrationState.sessionSubscription(
                                               saved: account.push, state: try? PushRegistrationState.load(accountID: accountID)),
                                           leftForeground: SharedSession.leftForeground()),
                progress: progress, presentation: { store, stage in
                    // Keep the transport lease through presentation. Preferences cannot change under this lease;
                    // logout authorization is reread before each presentation (direct messages first, then the rest).
                    // The block list is the app's copy of what the server last reported; nothing from it alerts.
                    try await presenter.present(store: store, accountID: accountID, progress: progress, stage: stage,
                                                blocklist: BlockedAddresses.load(accountID: accountID), authorize: {
                        guard try NotificationAccount.load() == account else { throw CancellationError() }
                    })
                })
            outcome = .settled(progress.report)
        } catch {
            // A committed run already posted and deleted its claims; a failure closing the store afterwards is not a
            // reason to show the fallback on top of the real notifications.
            outcome = progress.isCommitted ? .settled(progress.report) : .fallback(NotificationFallbackReason(error))
        }
        #if DEBUG
        // Synthetic staging diagnostics: timestamps, phase and counts only; no account, token, body or key data.
        if let directory { try? NotificationOutcomeLog.append(NotificationOutcomeRecord(progress: progress, outcome: outcome), directory: directory) }
        #endif
        return outcome
    }
}
