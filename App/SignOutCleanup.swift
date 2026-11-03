import Foundation
import MessageStore
import UserNotifications
import os

// The rows sign-out deletes (`AccountTable`), owed from the moment it starts until a lease holder deleted them, so a
// sign-out cut short by a background transition or a busy lease finishes at this process's next lease.
@MainActor struct SignOutCleanup {
    struct Owed: Error {}

    nonisolated static let key = "signOutRowsOwed"
    static let log = Logger(subsystem: "haus.xmpp.ios", category: "sync")
    let defaults: UserDefaults

    var owed: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func owe(_ account: String) {
        guard !account.isEmpty, !owed.contains(account) else { return }
        defaults.set(owed + [account], forKey: Self.key)
    }

    // Needs `store`'s lease. True once nothing is owed.
    @discardableResult
    func settle(store: MessageStore) async -> Bool {
        var settled = Set<String>()
        for account in owed {
            do {
                try await store.removeRowsAtSignOut(accountID: account)
                settled.insert(account)
            } catch {
                Self.log.error("sign-out rows stay until the next lease: \(Self.reason(error), privacy: .public)")
            }
        }
        let left = owed.filter { !settled.contains($0) }
        if left.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(left, forKey: Self.key) }
        return left.isEmpty
    }

    static func reason(_ error: any Error) -> String {
        switch error {
        case MessageStoreError.transportOwnershipRequired: "no lease"
        case MessageStoreError.closed: "store closed"
        case MessageStoreError.replaced: "store replaced"
        default: String(describing: error)
        }
    }
}

extension AppModel {
    // Under the lease. An extension run that held it may have posted since sign-out cleared the notifications.
    func settleSignOut(_ store: MessageStore) async {
        await SignOutCleanup(defaults: preferences).settle(store: store)
        guard testSessionID == nil else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // Re-entering credentials keeps an existing server subscription and the SCRAM pin (a server that drops SCRAM must
    // not get PLAIN by making the user retype the password); only signing out lifts them. Nothing crosses accounts.
    static func retainingSavedState(previous: NotificationAccount?, replacement: NotificationAccount) -> NotificationAccount {
        guard let previous, previous.accountID == replacement.accountID, previous.domain == replacement.domain,
              previous.username == replacement.username else { return replacement }
        let keepEndpoint = replacement.discoversEndpoint && previous.discoversEndpoint && !previous.host.isEmpty
        let endpoint = keepEndpoint ? previous : replacement
        return NotificationAccount(accountID: replacement.accountID, host: endpoint.host, port: endpoint.port, security: endpoint.security,
            discoversEndpoint: replacement.discoversEndpoint, requiresSCRAM: previous.requiresSCRAM || replacement.requiresSCRAM,
            domain: replacement.domain, username: replacement.username, password: replacement.password, push: replacement.push ?? previous.push)
    }
}
