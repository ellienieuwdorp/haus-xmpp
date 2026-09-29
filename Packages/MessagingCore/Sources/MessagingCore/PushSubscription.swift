import Foundation
import Security
import XMPPProtocol

/// One installation's subscription at the push gateway: a node and secret it generated itself. The gateway creates the
/// node on first registration and binds it to the registering account's bare JID; the account server receives the same
/// pair in the XEP-0357 enable and presents the secret with every publish.
public enum PushSubscription {
    public enum Failure: Error, Equatable { case randomUnavailable }

    /// What to do with a saved subscription before registering at `serviceJID`.
    public enum Plan: Equatable, Sendable {
        /// Saved at this service: reuse it, so a reinstall keeps its node.
        case keep(XMPPPushConfiguration)
        /// Nothing saved: generate a new subscription.
        case create
        /// Saved at another service (the retired staging gateway, or a DEBUG override): disable that one at the
        /// account server first, then generate a new subscription. Never leave both enabled.
        case replace(XMPPPushConfiguration)
    }

    public static func plan(saved: XMPPPushConfiguration?, serviceJID: String) -> Plan {
        guard let saved else { return .create }
        return saved.serviceJID.lowercased() == serviceJID.lowercased() ? .keep(saved) : .replace(saved)
    }

    /// 32 random bytes each for node and secret, unpadded base64url (43 characters).
    public static func generate(serviceJID: String, random: (Int) throws -> [UInt8] = systemRandom) throws -> XMPPPushConfiguration {
        let node = try encoded(random(32)), secret = try encoded(random(32))
        return try XMPPPushConfiguration(serviceJID: serviceJID, node: node, publishOptions: ["secret": secret])
    }

    public static func systemRandom(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.randomUnavailable }
        return bytes
    }

    private static func encoded(_ bytes: [UInt8]) throws -> String {
        guard bytes.count == 32 else { throw Failure.randomUnavailable }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
