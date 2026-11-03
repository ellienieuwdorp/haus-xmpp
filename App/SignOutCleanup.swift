import Foundation
import MessageStore
import UserNotifications
import os

// The rows sign-out deletes (`AccountTable`), owed from the moment it starts until a lease holder deleted them, so a
// sign-out cut short by a background transition or a busy lease finishes at this process's next lease.
@MainActor struct SignOutCleanup {
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
    // A background transition joins `acquiringOwnership` and connect stops while `quiescing`, as for a transfer.
    func settleSignOut(_ store: MessageStore) async {
        let background = BackgroundActivity("Sign out")
        defer { background.end() }
        quiescing = true
        acquiringOwnership = true
        defer { quiescing = false; acquiringOwnership = false }
        guard await takeLease(store) else { return SignOutCleanup.log.error("sign-out rows stay until the next lease: none was taken") }
        guard await SignOutCleanup(defaults: preferences).settle(store: store), testSessionID == nil else { return }
        // An extension run that held the lease may have posted since sign-out cleared them.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
