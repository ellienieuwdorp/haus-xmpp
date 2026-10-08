import Foundation
import Security

/// The base of every Keychain query the app and the notification extension make, so they all reach the same items.
///
/// `kSecUseDataProtectionKeychain` changes nothing on iOS, where the data protection keychain is the only one. On
/// native macOS a query without it uses the file-based keychain, which ignores access groups and `kSecAttrAccessible`,
/// so the extension could not read what the app saved.
enum KeychainQuery {
    /// A non-synchronizable generic password item. Without an account the query matches every account in the service.
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
