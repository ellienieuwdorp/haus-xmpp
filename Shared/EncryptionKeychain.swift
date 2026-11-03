import Foundation
import Security

enum EncryptionKeychain {
    enum Failure: Error {
        case unavailable
        // Only this case may lead to the recovery screen; every other failure fails closed.
        case missing
    }

    static let service = "haus.xmpp.encryption-state"

    // Only absence permits creation, and only with no encrypted identity stored or after the user chose to start over.
    // Locked, inaccessible or deleted keys never regenerate the identity.
    static func load(storageID: String, allowCreation: Bool) throws -> Data {
        let query = KeychainQuery.genericPassword(service: service, account: storageID)
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw Failure.unavailable }
        guard allowCreation else { throw Failure.missing }
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
