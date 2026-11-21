import Foundation
import XMPPProtocol

// The server's list, copied for the notification extension, which never fetches it, and for blocked chats offline.
// Beside it, when this device blocked each address: XEP-0191 carries no date, so a block made elsewhere has none.
enum BlockedAddresses {
    private static func key(_ accountID: String) -> String { "blocklist." + accountID }
    private static func datesKey(_ accountID: String) -> String { "blockedAt." + accountID }

    static func load(accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) -> XMPPBlocklist {
        guard !accountID.isEmpty, let saved = defaults?.stringArray(forKey: key(accountID)) else { return XMPPBlocklist() }
        return XMPPBlocklist(Set(saved))
    }

    // Dates of addresses no longer listed go with this save, so a block lifted and set again elsewhere shows none.
    static func save(_ blocklist: XMPPBlocklist, accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) {
        guard !accountID.isEmpty else { return }
        if blocklist.isEmpty { defaults?.removeObject(forKey: key(accountID)) }
        else { defaults?.set(blocklist.addresses.sorted(), forKey: key(accountID)) }
        saveDates(rawDates(accountID: accountID, defaults: defaults).filter { blocklist.addresses.contains($0.key) }, accountID: accountID, defaults: defaults)
    }

    static func forget(accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) {
        guard !accountID.isEmpty else { return }
        defaults?.removeObject(forKey: key(accountID))
        defaults?.removeObject(forKey: datesKey(accountID))
    }

    // After the server confirmed the block and the list was saved; an address not on the list gets no date.
    static func recordBlocked(_ address: String, at date: Date, accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) {
        let address = JID.normalized(address) ?? address
        guard load(accountID: accountID, defaults: defaults).addresses.contains(address) else { return }
        var dates = rawDates(accountID: accountID, defaults: defaults)
        dates[address] = date.timeIntervalSince1970
        saveDates(dates, accountID: accountID, defaults: defaults)
    }

    static func blockDates(accountID: String, defaults: UserDefaults? = SharedSession.groupDefaults) -> [String: Date] {
        rawDates(accountID: accountID, defaults: defaults).mapValues(Date.init(timeIntervalSince1970:))
    }

    // Newest block first; addresses without a date follow, alphabetically.
    static func ordered(_ addresses: Set<String>, dates: [String: Date]) -> [String] {
        addresses.sorted { a, b in
            switch (dates[a], dates[b]) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a < b
            }
        }
    }

    private static func rawDates(accountID: String, defaults: UserDefaults?) -> [String: Double] {
        guard !accountID.isEmpty else { return [:] }
        return defaults?.dictionary(forKey: datesKey(accountID)) as? [String: Double] ?? [:]
    }

    private static func saveDates(_ dates: [String: Double], accountID: String, defaults: UserDefaults?) {
        if dates.isEmpty { defaults?.removeObject(forKey: datesKey(accountID)) }
        else { defaults?.set(dates, forKey: datesKey(accountID)) }
    }
}
