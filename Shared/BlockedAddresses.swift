import Foundation
import XMPPProtocol

// The server's list, copied for the notification extension, which never fetches it, and for blocked chats offline.
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
