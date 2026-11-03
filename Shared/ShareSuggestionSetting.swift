import Foundation

// In the App Group so both extensions read the answer the app shows; off, nothing is donated, outgoing or incoming.
enum ShareSuggestionSetting {
    private static func key(_ accountID: String) -> String { "shareSuggestions." + accountID }

    static func isEnabled(accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) -> Bool {
        guard !accountID.isEmpty else { return false }
        return defaults?.object(forKey: key(accountID)) as? Bool ?? true
    }

    static func set(_ enabled: Bool, accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) {
        guard !accountID.isEmpty else { return }
        defaults?.set(enabled, forKey: key(accountID))
    }

    static func forget(accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) {
        defaults?.removeObject(forKey: key(accountID))
    }
}
