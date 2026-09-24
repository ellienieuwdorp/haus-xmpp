import Foundation
import Security

enum EncryptionKeychain {
    enum Failure: Error { case unavailable }

    /// Only absence permits creation, and only while the database has no encrypted identity.
    /// Locked/inaccessible/deleted keys never cause identity regeneration.
    static func load(storageID: String, allowCreation: Bool) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "haus.xmpp.encryption-state",
            kSecAttrAccount as String: storageID,
            kSecAttrSynchronizable as String: false
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, allowCreation else { throw Failure.unavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unavailable }
        let data = Data(bytes)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try load(storageID: storageID, allowCreation: false) }
        guard added == errSecSuccess else { throw Failure.unavailable }
        return data
    }
}
