import Foundation
import UserNotifications
import MessagingCore

// A settled or handed-off run suppresses the remote alert: empty content with the filtering entitlement, a quiet
// stand-in without it. Anything else shows the generic fallback; unknown is never suppressed.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    // `didReceive` may arrive concurrently for coalesced pushes, on this or another instance.
    private static let coordinator = NotificationRunCoordinator { progress in await ExtensionRun.run(progress) }

    private let lock = NSLock()
    private var deliveries: [UUID: RemoteDelivery] = [:]

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let ticket = UUID()
        let delivery = RemoteDelivery(request: request, handler: contentHandler)
        lock.withLock { deliveries[ticket] = delivery }
        Task {
            #if DEBUG && os(macOS)
            // Debug-only Mac storage probe. The delivery is registered first, so an expiry during the probe answers.
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
        // A suppressed delivery carries only the badge; a handed-off one leaves it to the app, a fallback as it is.
        let badge: NSNumber?
        switch outcome {
        case let .settled(report): badge = report.badge.map { NSNumber(value: $0) }
        case .handedOff: badge = nil
        case .fallback:
            callback(Self.fallback(for: request, badge: nil))
            return
        }
        guard NotificationFiltering.isAvailable else {
            callback(Self.standIn(for: request, badge: badge))
            return
        }
        let content = UNMutableNotificationContent()
        content.badge = badge
        callback(content)
    }

    // Generic, no message content; the request's identifier (the gateway's collapse ID) lets repeats replace each other.
    static func fallback(for request: UNNotificationRequest, badge: NSNumber?) -> UNNotificationContent {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.title = ""
        content.subtitle = ""
        content.body = NotificationPlanner.fallbackBody
        content.categoryIdentifier = NotificationIdentity.fallbackCategory
        content.threadIdentifier = ""
        content.userInfo = [:]
        content.attachments = []
        content.badge = badge
        return content
    }

    // Without the filtering entitlement empty content does not hide the push, so a settled run hands back the fallback,
    // passive and silent; its category lets the next run or the app's catch-up remove it.
    static func standIn(for request: UNNotificationRequest, badge: NSNumber?) -> UNNotificationContent {
        let content = (fallback(for: request, badge: badge).mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.sound = nil
        content.interruptionLevel = .passive
        return content
    }
}

// `com.apple.developer.usernotifications.filtering` makes empty content hide a push. The `HausNotificationFiltering`
// Info.plist key, set from `HAUS_EXTENSION_FILTERING`, says whether this build has it; a missing key counts as no.
enum NotificationFiltering {
    static let isAvailable = Bundle.main.object(forInfoDictionaryKey: "HausNotificationFiltering") as? String == "YES"
}

#if DEBUG && os(macOS)
extension RemoteDelivery {
    var probedRequest: UNNotificationRequest { request }
    var isFinished: Bool { lock.withLock { handler == nil } }

    func suppress() {
        guard let callback = lock.withLock({ () -> ((UNNotificationContent) -> Void)? in
            defer { handler = nil }
            return handler
        }) else { return }
        callback(NotificationFiltering.isAvailable ? UNMutableNotificationContent() : Self.standIn(for: request, badge: nil))
    }
}
#endif

private enum ExtensionRun {
    static func run(_ progress: NotificationRunProgress) async -> NotificationRunOutcome {
        var directory: URL?
        let outcome: NotificationRunOutcome
        do {
            let root: URL
            do { root = try await SharedStorage.directory(migrate: false) } catch { throw NotificationRunError.protectedDataUnavailable }
            directory = root
            // A restore of the previous version's data is under way or done: that data is the app's alone.
            guard !PreUpgradeHold.isHeld(groupRoot: root.deletingLastPathComponent()) else { throw NotificationRunError.upgradePending }
            guard !TransferHold.isMoved(groupRoot: root.deletingLastPathComponent()) else { throw NotificationRunError.noAccount }
            guard let account = try NotificationAccount.load(), account.push != nil else { throw NotificationRunError.noAccount }
            let key: Data
            do { key = try EncryptionKeychain.load(storageID: "primary", allowCreation: false) }
            catch { throw NotificationRunError.protectedDataUnavailable }
            let accountID = account.accountID
            // The suggestion setting is read as each notification posts, under the lease the app changes it under.
            let donates: @Sendable () -> Bool = { ShareSuggestionSetting.isEnabled(accountID: accountID) }
            let presenter = NotificationPresenter(posting: UserNotificationPoster(donates: donates, avatarData: { hash in
                AvatarStore.notificationImageData(root: root, account: accountID, hash: hash)
            }))
            try await BackgroundSynchronizer().synchronize(databaseURL: root.appending(path: "messages.sqlite"), wrappingKey: key,
                account: BackgroundAccount(route: account.route, domain: account.domain, username: account.username,
                                           password: account.password, requiresSCRAM: account.requiresSCRAM,
                                           resource: SharedSession.resource(accountID: accountID),
                                           push: PushRegistrationState.sessionSubscription(
                                               saved: account.push, state: try? PushRegistrationState.load(accountID: accountID)),
                                           leftForeground: SharedSession.leftForeground()),
                liveness: AppLiveness.isOffered
                    ? AppLiveness.ExtensionChannel(files: AppLiveness.Files(groupRoot: root.deletingLastPathComponent())) : nil,
                progress: progress, presentation: { store, stage in
                    // The transport lease spans presentation, so preferences cannot change; logout authorization is
                    // reread before each presentation.
                    try await presenter.present(store: store, accountID: accountID, progress: progress, stage: stage,
                                                blocklist: BlockedAddresses.load(accountID: accountID), authorize: {
                        guard try NotificationAccount.load() == account else { throw CancellationError() }
                    })
                })
            outcome = .settled(progress.report)
        } catch {
            outcome = .ended(by: error, progress: progress)
        }
        #if DEBUG
        // Synthetic staging diagnostics: timestamps, phase and counts only; no account, token, body or key data.
        if let directory { try? NotificationOutcomeLog.append(NotificationOutcomeRecord(progress: progress, outcome: outcome), directory: directory) }
        #endif
        return outcome
    }
}
