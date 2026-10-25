import Foundation

/// "Suggest chats in Share Sheet", per account, in the App Group so the notification and share extensions read the
/// same answer the app shows. On unless the user turned it off, for existing accounts too. With it off (or with
/// message previews off) nothing is donated: no outgoing interaction from a send, and no incoming one with a
/// communication notification, which still shows its sender's name and avatar.
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

    /// Sign-out: the next sign-in starts from the default.
    static func forget(accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) {
        defaults?.removeObject(forKey: key(accountID))
    }
}
