import Foundation
import Security
import XMPPProtocol

/// Contains secrets; intentionally has no printable description. The extension only reads a
/// foreground-authenticated account. Push payloads cannot supply credentials or endpoints.
struct NotificationAccount: Codable, Sendable, Equatable {
    let accountID: String
    /// The endpoint that last worked, tried first by the app and the extension.
    let host: String
    let port: UInt16
    let security: XMPPTransportSecurity
    /// False for a manually entered server or the lab: that endpoint only. True: SRV discovery when it fails.
    let discoversEndpoint: Bool
    /// Set once the account authenticated with SCRAM; PLAIN is refused from then on (downgrade protection).
    let requiresSCRAM: Bool
    let domain: String
    let username: String
    let password: String
    let push: XMPPPushConfiguration?

    /// Records written before discovery and SCRAM existed were direct TLS to one fixed endpoint, with PLAIN.
    init(accountID: String, host: String, port: UInt16, security: XMPPTransportSecurity = .directTLS, discoversEndpoint: Bool = false,
         requiresSCRAM: Bool = false, domain: String, username: String, password: String, push: XMPPPushConfiguration?) {
        self.accountID = accountID; self.host = host; self.port = port; self.security = security
        self.discoversEndpoint = discoversEndpoint; self.requiresSCRAM = requiresSCRAM
        self.domain = domain; self.username = username; self.password = password; self.push = push
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accountID: try values.decode(String.self, forKey: .accountID), host: try values.decode(String.self, forKey: .host),
                  port: try values.decode(UInt16.self, forKey: .port),
                  security: try values.decodeIfPresent(XMPPTransportSecurity.self, forKey: .security) ?? .directTLS,
                  discoversEndpoint: try values.decodeIfPresent(Bool.self, forKey: .discoversEndpoint) ?? false,
                  requiresSCRAM: try values.decodeIfPresent(Bool.self, forKey: .requiresSCRAM) ?? false,
                  domain: try values.decode(String.self, forKey: .domain), username: try values.decode(String.self, forKey: .username),
                  password: try values.decode(String.self, forKey: .password), push: try values.decodeIfPresent(XMPPPushConfiguration.self, forKey: .push))
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, host, port, security, discoversEndpoint, requiresSCRAM, domain, username, password, push
    }

    var endpoint: XMPPEndpoint { XMPPEndpoint(host: host, port: port, security: security) }
    /// A discovering account that has never connected has no endpoint yet (empty host, in memory only).
    var route: XMPPRoute { discoversEndpoint ? .discover(preferred: host.isEmpty ? nil : endpoint) : .fixed(endpoint) }

    /// The same credentials with another (or no) push subscription.
    func replacingPush(_ push: XMPPPushConfiguration?) -> Self {
        NotificationAccount(accountID: accountID, host: host, port: port, security: security, discoversEndpoint: discoversEndpoint,
                            requiresSCRAM: requiresSCRAM, domain: domain, username: username, password: password, push: push)
    }

    /// After a successful sign-in: remember the endpoint that worked, and pin SCRAM once it was used.
    func connected(_ session: XMPPConnectedSession) -> Self {
        NotificationAccount(accountID: accountID, host: session.endpoint.host, port: session.endpoint.port, security: session.endpoint.security,
                            discoversEndpoint: discoversEndpoint, requiresSCRAM: requiresSCRAM || session.authenticatedWithSCRAM,
                            domain: domain, username: username, password: password, push: push)
    }

    static func load() throws -> Self? {
        guard try !NotificationAccessGate.isDisabled(at: NotificationAccessGate.location()) else { return nil }
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.unavailable }
        let value = try JSONDecoder().decode(Self.self, from: normalizingIdentity(data))
        guard value.accountID == value.username + "@" + value.domain, value.port > 0,
              !value.host.isEmpty, !value.password.isEmpty else { throw Failure.unavailable }
        return value
    }

    func save() throws {
        guard !host.isEmpty, port > 0 else { throw Failure.unavailable }
        let data = try JSONEncoder().encode(self)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(Self.keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.keychainQuery
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        } else if status != errSecSuccess { throw Failure.unavailable }
        try NotificationAccessGate.enable(at: NotificationAccessGate.location())
    }

    static func remove() throws {
        var disabled = false
        do {
            try NotificationAccessGate.disable(at: NotificationAccessGate.location())
            disabled = true
        } catch { /* Still attempt credential deletion if the separate tombstone cannot be saved. */ }
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.credentialsRemain(backgroundDisabled: disabled)
        }
    }

    /// A record saved before addresses were normalised may name the account as typed (`Ellie@Example.org`). It is read
    /// in normal form, the account's spelling everywhere else; the next successful sign-in saves it that way. Rewritten
    /// in the JSON so every other field is carried over untouched.
    static func normalizingIdentity(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = object["username"] as? String, let domain = object["domain"] as? String,
              let local = JID.normalizedLocalpart(username), let host = JID.normalizedDomainpart(domain),
              local != username || host != domain || object["accountID"] as? String != local + "@" + host else { return data }
        guard object["accountID"] as? String == username + "@" + domain else { return data }
        object["username"] = local; object["domain"] = host; object["accountID"] = local + "@" + host
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static var keychainQuery: [String: Any] {
        KeychainQuery.genericPassword(service: "haus.xmpp.notification-account", account: "primary")
    }
    enum Failure: Error { case unavailable, credentialsRemain(backgroundDisabled: Bool) }
}
