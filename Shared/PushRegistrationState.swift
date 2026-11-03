import Foundation
import Security
import MessagingCore
import XMPPProtocol

// Holds no password. A revocation tombstone survives sign-out and retries only after the same account signs in again.
struct PushRegistrationState: Codable, Sendable, Equatable {
    let accountID: String
    let configuration: XMPPPushConfiguration
    var journal: PushRegistrationJournal
    // Cleared only once the server confirmed the XEP-0357 disable. Separate from the gateway revocation, so a settled
    // revocation never drops a disable that is still owed.
    var disablePending = false

    // Revocation and disable both retry on every connection until confirmed; an unjournaled subscription gets one here.
    static func turningOff(accountID: String, saved: Self?, enabled: XMPPPushConfiguration?) throws -> Self? {
        guard var state = saved ?? enabled.map({ Self(accountID: accountID, configuration: $0, journal: PushRegistrationJournal()) })
        else { return nil }
        try state.journal.stageRevocation()
        state.disablePending = true
        return state
    }

    // Only the app registers with the gateway, so another session re-enables only a subscription this journal has
    // settled.
    static func sessionSubscription(saved push: XMPPPushConfiguration?, state: Self?) -> XMPPPushConfiguration? {
        guard let push, let state, state.configuration == push, !state.disablePending,
              state.journal.pending == nil, state.journal.acknowledgedRevision > 0 else { return nil }
        return push
    }

    static let service = "haus.xmpp.push-registration"

    static func load(accountID: String, service: String = service) throws -> Self? {
        var query = query(accountID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw NotificationAccount.Failure.unavailable }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.accountID == accountID else { throw NotificationAccount.Failure.unavailable }
        return value
    }

    func save(service: String = Self.service) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(Self.query(accountID, service: service) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.query(accountID, service: service)
            for (key, value) in attributes { item[key] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw NotificationAccount.Failure.unavailable }
        } else if status != errSecSuccess { throw NotificationAccount.Failure.unavailable }
    }

    // Moves registrations keyed by the account as typed to the normal key once; one already saved there wins.
    static func normalizeSavedAccounts(service: String = service) {
        var all = KeychainQuery.genericPassword(service: service, account: nil)
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        all[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(all as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            guard let normal = JID.normalizedBare(account), normal != account,
                  let saved = try? load(accountID: account, service: service) else { continue }
            if (try? load(accountID: normal, service: service)) == nil {
                var moved = PushRegistrationState(accountID: normal, configuration: saved.configuration, journal: saved.journal)
                moved.disablePending = saved.disablePending
                guard (try? moved.save(service: service)) != nil else { continue }
            }
            SecItemDelete(query(account, service: service) as CFDictionary)
        }
    }

    private static func query(_ account: String, service: String) -> [String: Any] {
        KeychainQuery.genericPassword(service: service, account: account)
    }
}

extension PushRegistrationState {
    private enum CodingKeys: String, CodingKey { case accountID, configuration, journal, disablePending }

    // Items without `disablePending` disabled right after revocation, so a staged revocation still owes that disable.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try values.decode(String.self, forKey: .accountID)
        configuration = try values.decode(XMPPPushConfiguration.self, forKey: .configuration)
        journal = try values.decode(PushRegistrationJournal.self, forKey: .journal)
        disablePending = try values.decodeIfPresent(Bool.self, forKey: .disablePending) ?? (journal.pending?.action == .revoke)
    }
}
