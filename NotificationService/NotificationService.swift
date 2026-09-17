import Foundation
import UserNotifications
import MessagingCore

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var work: Task<Void, Never>?
    private var delivery: NotificationDelivery?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        // The gateway sends no plaintext. Only authenticated local decryption can replace
        // this fallback; iOS and the app's preview preference govern message presentation.
        content.title = "XMPP"
        content.body = "New encrypted activity"
        content.categoryIdentifier = "message"
        content.userInfo = [:]
        let delivery = NotificationDelivery(content: content, handler: contentHandler)
        lock.lock()
        self.delivery?.finish()
        work?.cancel()
        self.delivery = delivery
        work = Task {
            defer { delivery.finish() }
            do {
                guard let account = try NotificationAccount.load(), account.push != nil else { return }
                let directory = try await SharedStorage.directory(migrate: false)
                let started = Date().timeIntervalSince1970
                let key = try EncryptionKeychain.load(storageID: "primary", allowCreation: false)
                try await BackgroundSynchronizer().synchronize(databaseURL: directory.appending(path: "messages.sqlite"),
                    wrappingKey: key, account: BackgroundAccount(host: account.host, port: account.port,
                        domain: account.domain, username: account.username, password: account.password), presentation: { batch in
                    // Keep the transport lease through presentation. Preferences cannot change
                    // under this lease; logout authorization is reread after the network work.
                    guard try NotificationAccount.load() == account else { throw CancellationError() }
                    let preview = NotificationPreview(batch)
                    try Task.checkCancellation()
                    #if DEBUG
                    // Synthetic staging diagnostics contain no account, token, body or key data.
                    let marker = try JSONEncoder().encode(["started": started, "completed": Date().timeIntervalSince1970])
                    try? marker.write(to: directory.appending(path: "notification-result.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    #endif
                    delivery.finish(preview: preview, storageRoot: directory, account: account.accountID)
                })
            } catch {
                // Contention, unavailable protected data, network failure and expiration all
                // preserve a generic alert. The next foreground MAM pass recovers content.
            }
        }
        lock.unlock()
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let work = work
        let delivery = delivery
        lock.unlock()
        work?.cancel()
        delivery?.finish()
    }
}

private final class NotificationDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let content: UNNotificationContent
    private var handler: ((UNNotificationContent) -> Void)?
    init(content: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content; self.handler = handler
    }
    func finish(preview: NotificationPreview? = nil, storageRoot: URL? = nil, account: String? = nil) {
        lock.lock()
        let callback = handler
        handler = nil
        let finalContent: UNNotificationContent
        if let preview, let updated = content.mutableCopy() as? UNMutableNotificationContent {
            updated.title = preview.title
            updated.body = preview.body
            updated.threadIdentifier = preview.threadIdentifier
            updated.userInfo = preview.destination.map { [NotificationDestination.userInfoKey: $0.payload] } ?? [:]
            // The app's verified avatar file, copied because iOS takes ownership of an attachment.
            if let hash = preview.avatarHash, let storageRoot, let account {
                let cached = AvatarStore.url(root: storageRoot, account: account, hash: hash)
                let copy = FileManager.default.temporaryDirectory.appending(path: "avatar-\(hash).png")
                if AvatarStore.image(at: cached) != nil, (try? FileManager.default.copyItem(at: cached, to: copy)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "avatar", url: copy, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]) {
                    updated.attachments = [attachment]
                }
            }
            #if NOTIFICATION_FILTERING_APPROVED
            // Enable only after Apple grants the entitlement and the signing profile includes it.
            finalContent = preview.hasNewMessage ? updated : UNNotificationContent()
            #else
            finalContent = updated
            #endif
        } else { finalContent = content }
        lock.unlock()
        callback?(finalContent)
    }
}
