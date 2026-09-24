import Foundation
import Security
import XMPPProtocol

/// Contains secrets; intentionally has no printable description. The extension only reads a
/// foreground-authenticated account. Push payloads cannot supply credentials or endpoints.
struct NotificationAccount: Codable, Sendable, Equatable {
    let accountID: String
    let host: String
    let port: UInt16
    let domain: String
    let username: String
    let password: String
    let push: XMPPPushConfiguration?

    static func load() throws -> Self? {
        guard try !NotificationAccessGate.isDisabled(at: NotificationAccessGate.location()) else { return nil }
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.unavailable }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.accountID == value.username + "@" + value.domain, value.port > 0,
              !value.host.isEmpty, !value.password.isEmpty else { throw Failure.unavailable }
        return value
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(Self.keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.keychainQuery
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        } else if status != errSecSuccess { throw Failure.unavailable }
        try NotificationAccessGate.enable(at: NotificationAccessGate.location())
    }

    static func remove() throws {
        var disabled = false
        do {
            try NotificationAccessGate.disable(at: NotificationAccessGate.location())
            disabled = true
        } catch { /* Still attempt credential deletion if the separate tombstone cannot be saved. */ }
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.credentialsRemain(backgroundDisabled: disabled)
        }
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "haus.xmpp.notification-account",
         kSecAttrAccount as String: "primary",
         kSecAttrSynchronizable as String: false]
    }
    enum Failure: Error { case unavailable, credentialsRemain(backgroundDisabled: Bool) }
}
