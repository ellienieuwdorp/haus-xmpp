import Foundation

public enum XMPPMessageProvenance: String, Sendable, Codable {
    case direct, receivedCarbon, sentCarbon
}

/// XEP-0280 forwarding is accepted only inside a carbon from our own bare JID.
/// Arbitrary XEP-0297 forwarded payloads and nested wrappers are never unwrapped.
enum Carbons {
    static let namespace = "urn:xmpp:carbons:2"
    static let forwarding = "urn:xmpp:forward:0"

    static func containsWrapper(_ node: XMLNode) -> Bool {
        node.children.contains { ["sent", "received"].contains($0.name) && $0.namespace.hasPrefix("urn:xmpp:carbons:") }
    }

    static func unwrap(_ node: XMLNode, accountBareJID: String, accountFullJID: String) throws -> (XMLNode, XMPPMessageProvenance) {
        guard node.name == "message", node.namespace == "jabber:client",
              node.attributes["from"] == accountBareJID, node.attributes["to"] == accountFullJID else { throw XMPPIQError.malformedResponse }
        let wrappers = node.children.filter { ["sent", "received"].contains($0.name) && $0.namespace.hasPrefix("urn:xmpp:carbons:") }
        guard wrappers.count == 1, wrappers[0].namespace == namespace, wrappers[0].children.count == 1 else { throw XMPPIQError.malformedResponse }
        let wrapper = wrappers[0]
        let forwarded = try OMEMOWire.singleton(wrapper, "forwarded", forwarding)
        let messages = forwarded.children.filter { $0.name == "message" && $0.namespace == "jabber:client" }
        let delays = forwarded.children.filter { $0.name == "delay" && $0.namespace == "urn:xmpp:delay" }
        guard messages.count == 1, delays.count <= 1, forwarded.children.count == messages.count + delays.count else { throw XMPPIQError.malformedResponse }
        let message = messages[0]
        guard !containsWrapper(message), message.child("forwarded", namespace: forwarding) == nil,
              message.attributes["type"] == nil || ["chat", "normal"].contains(message.attributes["type"]!),
              let from = message.attributes["from"], let sender = OMEMOWire.bareJID(from),
              let to = message.attributes["to"], let recipient = OMEMOWire.bareJID(to) else { throw XMPPIQError.malformedResponse }
        if wrapper.name == "sent" {
            guard sender == accountBareJID else { throw XMPPIQError.malformedResponse }
            return (message, .sentCarbon)
        }
        guard recipient == accountBareJID else { throw XMPPIQError.malformedResponse }
        return (message, .receivedCarbon)
    }
}
