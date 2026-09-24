import Foundation
import Security
import MessagingCore
import XMPPProtocol

/// Durable registration intent contains no account password. A revocation tombstone can
/// survive sign-out and retry only after the same account authenticates again.
struct PushRegistrationState: Codable, Sendable {
    let accountID: String
    let configuration: XMPPPushConfiguration
    var journal: PushRegistrationJournal

    static func load(accountID: String) throws -> Self? {
        var query = query(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw NotificationAccount.Failure.unavailable }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.accountID == accountID else { throw NotificationAccount.Failure.unavailable }
        return value
    }

    func save() throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(Self.query(accountID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.query(accountID)
            for (key, value) in attributes { item[key] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw NotificationAccount.Failure.unavailable }
        } else if status != errSecSuccess { throw NotificationAccount.Failure.unavailable }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "haus.xmpp.push-registration",
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}
