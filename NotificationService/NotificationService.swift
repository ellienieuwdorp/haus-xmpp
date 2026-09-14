import Foundation
import UserNotifications
import MessagingCore

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var work: Task<Void, Never>?
    private var delivery: NotificationDelivery?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        // Privacy default: neither the gateway nor notification center receives plaintext.
        content.title = "XMPP"
        content.body = "New encrypted activity"
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
                        domain: account.domain, username: account.username, password: account.password))
                #if DEBUG
                // Synthetic staging diagnostics contain no account, token, body or key data.
                let marker = try JSONEncoder().encode(["started": started, "completed": Date().timeIntervalSince1970])
                try? marker.write(to: directory.appending(path: "notification-result.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #endif
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
    func finish() {
        lock.lock()
        let callback = handler
        handler = nil
        lock.unlock()
        callback?(content)
    }
}
