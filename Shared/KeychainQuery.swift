import Foundation
import Security

// On macOS the file-based keychain ignores access groups, so every query names the data protection keychain.
enum KeychainQuery {
    static func genericPassword(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}
