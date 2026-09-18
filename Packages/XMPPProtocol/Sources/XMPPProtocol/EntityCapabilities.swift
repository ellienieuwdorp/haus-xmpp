import CryptoKit
import Foundation

/// XEP-0115 entity capabilities: the one disco#info identity and feature list this client
/// advertises, hashed into the `<c/>` element on presence so PEP services know which
/// `+notify` nodes to push (servers ignore a client that sends presence without caps).
public enum EntityCapabilities {
    public static let node = "https://xmpplab.dev/ios"
    public static let identity = "client/phone//XMPP Lab"
    public static var features: [String] {
        ["http://jabber.org/protocol/disco#info", "http://jabber.org/protocol/caps", "urn:xmpp:ping", "urn:xmpp:receipts", "urn:xmpp:chat-markers:0", AvatarWire.metadataNode + "+notify"]
            + XMPPOMEMOProfile.allCases.flatMap { [$0.namespace, $0.devicesNode + "+notify"] }
    }

    /// XEP-0115 §5.1 over one identity: identity, then features in byte order, each `<`-terminated, SHA-1, base64.
    public static func verification(identity: String, features: [String]) -> String {
        let sorted = features.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let input = ([identity] + sorted).map { $0 + "<" }.joined()
        return Data(Insecure.SHA1.hash(data: Data(input.utf8))).base64EncodedString()
    }

    public static var verification: String { verification(identity: identity, features: features) }

    static var presenceElement: String {
        "<c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='\(node)' ver='\(verification)'/>"
    }

    /// The disco#info result body; echoes the requested `node` so caps lookups match their query.
    static func discoInfoQuery(node requested: String?) -> String {
        let nodeAttribute = requested.map { " node='\(xmlEscaped($0))'" } ?? ""
        return "<query xmlns='http://jabber.org/protocol/disco#info'\(nodeAttribute)><identity category='client' type='phone' name='XMPP Lab'/>"
            + features.map { "<feature var='\($0)'/>" }.joined() + "</query>"
    }
}
