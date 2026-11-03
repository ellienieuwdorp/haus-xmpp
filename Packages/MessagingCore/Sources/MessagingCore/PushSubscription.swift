import Foundation
import Security
import XMPPProtocol

/// A self-generated node and secret. The gateway creates the node on first registration and binds it to the
/// account's bare JID; the account server receives the pair in the XEP-0357 enable and presents the secret with every
/// publish.
public enum PushSubscription {
    public enum Failure: Error, Equatable { case randomUnavailable }

    public enum Plan: Equatable, Sendable {
        /// Reuse it, so a reinstall keeps its node.
        case keep(XMPPPushConfiguration)
        case create
        /// Saved at another service: disable that one at the account server first. Never leave both enabled.
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
