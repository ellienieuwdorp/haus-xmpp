import Foundation
import XMPPProtocol

/// Per-installation session facts the app, its notification actions and the extension share through the App Group.
/// Neither is secret, and neither names the user or the device.
enum SharedSession {
    static var groupDefaults: UserDefaults? { UserDefaults(suiteName: SharedStorage.group) }

    /// The XMPP resource every fresh bind of this installation requests for the account: random once, then kept, so a
    /// new session (app, extension or notification action) replaces the previous one instead of adding a second.
    /// Without shared defaults a random resource serves this process only.
    static func resource(accountID: String, defaults: UserDefaults? = groupDefaults) -> String {
        let key = "xmppResource." + accountID
        if let saved = defaults?.string(forKey: key), XMPPClient.validResource(saved) { return saved }
        let created = XMPPClient.makeResource()
        defaults?.set(created, forKey: key)
        return created
    }

    /// Recorded when the scene leaves the foreground; background sessions announce it as their XEP-0319 idle time.
    static func recordLeftForeground(_ date: Date = Date(), defaults: UserDefaults? = groupDefaults) {
        defaults?.set(date.timeIntervalSince1970, forKey: "leftForeground")
    }

    static func leftForeground(defaults: UserDefaults? = groupDefaults) -> Date? {
        guard let seconds = defaults?.object(forKey: "leftForeground") as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
