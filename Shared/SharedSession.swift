import Foundation
import MessagingCore
import XMPPProtocol

enum SharedSession {
    static var groupDefaults: UserDefaults? { UserDefaults(suiteName: SharedStorage.group) }

    // Each account's stream profile, which every process connects with and learns into.
    static var streamProfiles: StreamProfileMemory? { groupDefaults.map(StreamProfileMemory.init) }

    // Random once, then kept, so a new bind (app, extension or notification action) replaces the previous session.
    static func resource(accountID: String, defaults: UserDefaults? = groupDefaults) -> String {
        let key = "xmppResource." + accountID
        if let saved = defaults?.string(forKey: key), XMPPClient.validResource(saved) { return saved }
        let created = XMPPClient.makeResource()
        defaults?.set(created, forKey: key)
        return created
    }

    // Background sessions announce this as their XEP-0319 idle time.
    static func recordLeftForeground(_ date: Date = Date(), defaults: UserDefaults? = groupDefaults) {
        defaults?.set(date.timeIntervalSince1970, forKey: "leftForeground")
    }

    static func leftForeground(defaults: UserDefaults? = groupDefaults) -> Date? {
        guard let seconds = defaults?.object(forKey: "leftForeground") as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
