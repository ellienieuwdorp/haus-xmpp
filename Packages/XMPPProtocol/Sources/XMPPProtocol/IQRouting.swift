import Foundation

/// An IQ ID is only a correlation token. The response must also come from the addressed entity.
struct IQReplyScope: Sendable {
    let recipient: String?
    let accountBareJID: String
    let accountFullJID: String
    let serverDomain: String

    func accepts(_ node: XMLNode) -> Bool {
        guard node.name == "iq", node.namespace == "jabber:client",
              ["result", "error"].contains(node.attributes["type"] ?? "") else { return false }
        if let to = node.attributes["to"], to != accountBareJID && to != accountFullJID { return false }
        let from = node.attributes["from"]
        if let recipient, recipient != accountBareJID && recipient != serverDomain {
            // No bare/full widening: a different resource is not the entity we queried.
            return from == recipient
        }
        return from == nil || from == accountBareJID || from == serverDomain || from == accountFullJID
    }

    static func result(_ node: XMLNode) throws -> XMLNode {
        if node.attributes["type"] == "error" {
            let error = try OMEMOWire.singleton(node, "error", "jabber:client")
            let conditions = error.children.filter { $0.namespace == "urn:ietf:params:xml:ns:xmpp-stanzas" && $0.name != "text" }
            guard conditions.count == 1 else { throw XMPPIQError.malformedResponse }
            throw XMPPIQError.stanza(condition: conditions[0].name)
        }
        return node
    }
}

extension XMPPClient {
    /// Pure encoding used to persist the exact ciphertext before any network write.
    public nonisolated static func encryptedMessageXML(to: String, envelope: XMPPOMEMOEnvelope, id: String) throws -> String {
        try OMEMOWire.messageXML(to: to, envelope: envelope, id: id)
    }

    /// Standalone parser for a complete stanza. Includes the same size, depth and namespace limits as the transport.
    public nonisolated static func decodeEncryptedMessageXML(_ xml: String) throws -> XMPPEncryptedMessage {
        var parser = XMLStreamFramer()
        let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml + "</stream:stream>").utf8))
        let elements = frames.compactMap { frame -> XMLNode? in if case .element(let node) = frame { node } else { nil } }
        guard elements.count == 1 else { throw XMPPIQError.malformedResponse }
        return try OMEMOWire.parseMessage(elements[0])
    }
}
