import Foundation
import XMPPProtocol

/// The account's XEP-0191 block list as its server last reported it, kept in the App Group. The server is the source of
/// truth and drops what blocked addresses send; this copy lets the notification extension, which never fetches the list,
/// leave out anything that still reaches the store, and lets the app show blocked chats before it connects. The app
/// replaces it on every fetch and push.
enum BlockedAddresses {
    private static func key(_ accountID: String) -> String { "blocklist." + accountID }

    static func load(accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) -> XMPPBlocklist {
        guard !accountID.isEmpty, let saved = defaults?.stringArray(forKey: key(accountID)) else { return XMPPBlocklist() }
        return XMPPBlocklist(Set(saved))
    }

    static func save(_ blocklist: XMPPBlocklist, accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) {
        guard !accountID.isEmpty else { return }
        if blocklist.isEmpty { defaults?.removeObject(forKey: key(accountID)) }
        else { defaults?.set(blocklist.addresses.sorted(), forKey: key(accountID)) }
    }

    static func forget(accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) {
        guard !accountID.isEmpty else { return }
        defaults?.removeObject(forKey: key(accountID))
    }
}
