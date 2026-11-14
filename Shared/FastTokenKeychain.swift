import Foundation
import Security
import XMPPProtocol

// Each account's XEP-0484 token, a credential like the password beside it: in the Keychain access group the app and
// both extensions share, this device only, after first unlock. Nothing is saved while the sign-out tombstone stands, so
// a connection that outlives a sign-out cannot leave a token behind; deleting always works.
struct FastTokenKeychain: XMPPFastTokenStore {
    static let service = "haus.xmpp.fast-token"
    var service = Self.service
    var tombstone: @Sendable () throws -> URL = NotificationAccessGate.location

    func fastToken(account: String) -> XMPPFastToken? {
        guard !account.isEmpty, !signedOut else { return nil }
        var query = KeychainQuery.genericPassword(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(XMPPFastToken.self, from: data)
    }

    func saveFastToken(_ token: XMPPFastToken?, account: String) {
        guard !account.isEmpty else { return }
        guard let token else {
            // A token that stays after the server refused it is refused again and deleted then; sign-out checks its own.
            try? Self.remove(account: account, service: service)
            return
        }
        guard !signedOut, let data = try? JSONEncoder().encode(token) else { return }
        let query = KeychainQuery.genericPassword(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func remove(account: String, service: String = service) throws {
        let status = SecItemDelete(KeychainQuery.genericPassword(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NotificationAccount.Failure.unavailable }
    }

    private var signedOut: Bool { (try? NotificationAccessGate.isDisabled(at: tombstone())) ?? true }
}
