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
        if outcome.suppressesRemoteAlert {
            // Every local add already completed: empty content suppresses the remote alert (no title, body or sound).
            callback(UNNotificationContent())
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
        callback(content)
    }
}

/// One run in this process: load the protected account, catch up under the lease, post, settle, and record counts.
private enum ExtensionRun {
    static func run(_ progress: NotificationRunProgress) async -> NotificationRunOutcome {
        var directory: URL?
        let outcome: NotificationRunOutcome
        do {
            guard let account = try NotificationAccount.load(), account.push != nil else { throw NotificationRunError.noAccount }
            let key: Data
            do {
                directory = try await SharedStorage.directory(migrate: false)
                key = try EncryptionKeychain.load(storageID: "primary", allowCreation: false)
            } catch { throw NotificationRunError.protectedDataUnavailable }
            guard let root = directory else { throw NotificationRunError.protectedDataUnavailable }
            let accountID = account.accountID
            let presenter = NotificationPresenter(posting: UserNotificationPoster(avatarCopy: { hash, identifier in
                // The app's verified avatar file, copied because iOS takes ownership of an attachment.
                let cached = AvatarStore.url(root: root, account: accountID, hash: hash)
                let copy = FileManager.default.temporaryDirectory.appending(path: "avatar-\(identifier).png")
                try? FileManager.default.removeItem(at: copy)
                guard AvatarStore.image(at: cached) != nil, (try? FileManager.default.copyItem(at: cached, to: copy)) != nil else { return nil }
                return copy
            }))
            try await BackgroundSynchronizer().synchronize(databaseURL: root.appending(path: "messages.sqlite"), wrappingKey: key,
                account: BackgroundAccount(host: account.host, port: account.port, domain: account.domain,
                                           username: account.username, password: account.password),
                progress: progress, presentation: { store in
                    // Keep the transport lease through presentation. Preferences cannot change under this lease;
                    // logout authorization is reread after the network work.
                    try await presenter.present(store: store, accountID: accountID, progress: progress, authorize: {
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
