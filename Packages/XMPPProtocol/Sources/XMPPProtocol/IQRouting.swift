import Foundation

// An IQ ID is only a correlation token: the response must also come from the addressed entity, compared in normal
// form.
struct IQReplyScope: Sendable {
    let recipient: String?
    let accountBareJID: String
    let accountFullJID: String
    let serverDomain: String

    init(recipient: String?, accountBareJID: String, accountFullJID: String, serverDomain: String) {
        func normal(_ value: String) -> String { JID.normalized(value) ?? value }
        self.recipient = recipient.map(normal); self.accountBareJID = normal(accountBareJID)
        self.accountFullJID = normal(accountFullJID); self.serverDomain = normal(serverDomain)
    }

    func accepts(_ node: XMLNode) -> Bool {
        guard node.name == "iq", node.namespace == "jabber:client",
              ["result", "error"].contains(node.attributes["type"] ?? "") else { return false }
        if let to = node.attributes["to"].map({ JID.normalized($0) ?? $0 }), to != accountBareJID && to != accountFullJID { return false }
        let from = node.attributes["from"].map { JID.normalized($0) ?? $0 }
        if let recipient, recipient != accountBareJID && recipient != serverDomain {
            // No bare/full widening: a different resource is not the entity we queried.
            return from == recipient
        }
        return from == nil || from == accountBareJID || from == serverDomain || from == accountFullJID
    }

    static func result(_ node: XMLNode) throws -> XMLNode {
        if node.attributes["type"] == "error" {
            let error = try OMEMOWire.singleton(node, "error", "jabber:client")
            // RFC 6120 §8.3.2 names one condition, but some servers add a second; the first decides, as in other
            // clients.
            guard let condition = error.children.first(where: { $0.namespace == "urn:ietf:params:xml:ns:xmpp-stanzas" && $0.name != "text" }) else {
                throw XMPPIQError.malformedResponse
            }
            throw XMPPIQError.stanza(condition: condition.name)
        }
        return node
    }
}

extension XMPPClient {
    /// Pure, so the exact ciphertext is persisted before any network write.
    public nonisolated static func encryptedMessageXML(to: String, envelope: XMPPOMEMOEnvelope, id: String, requestReceipt: Bool = false, markable: Bool = false, replaces: String? = nil) throws -> String {
        try OMEMOWire.messageXML(to: to, envelope: envelope, id: id, requestReceipt: requestReceipt, markable: markable, replaces: replaces)
    }

    /// The plain XEP-0424 twin of `decodeOutgoingReactionXML`.
    public nonisolated static func decodeOutgoingRetractionXML(_ xml: String, from account: String) -> XMPPRetraction? {
        guard OMEMOWire.bareJID(account) == account else { return nil }
        var parser = XMLStreamFramer()
        guard let frames = try? parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml + "</stream:stream>").utf8)) else { return nil }
        let elements = frames.compactMap { frame -> XMLNode? in if case .element(let node) = frame { node } else { nil } }
        guard elements.count == 1, let original = elements.first, original.attributes["from"] == nil || original.attributes["from"] == account else { return nil }
        var attributes = original.attributes; attributes["from"] = account
        return parsedRetraction(XMLNode(name: original.name, namespace: original.namespace, attributes: attributes, text: original.text, children: original.children,
                                attributePrefixes: original.attributePrefixes))
    }

    /// Decodes saved outgoing ciphertext for fingerprint-scoped replay authorization. Only the authenticated account
    /// may fill the absent outgoing sender.
    public nonisolated static func decodeOutgoingEncryptedMessageXML(_ xml: String, from account: String) throws -> XMPPEncryptedMessage {
        guard OMEMOWire.bareJID(account) == account else { throw XMPPClientError.invalidConfiguration }
        var parser = XMLStreamFramer()
        let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml + "</stream:stream>").utf8))
        let elements = frames.compactMap { frame -> XMLNode? in if case .element(let node) = frame { node } else { nil } }
        guard elements.count == 1, let original = elements.first,
              original.name == "message", original.namespace == "jabber:client",
              original.attributes["from"] == nil || original.attributes["from"] == account,
              !Carbons.containsWrapper(original), !ArchiveQuery.containsWrapper(original) else { throw XMPPIQError.malformedResponse }
        var attributes = original.attributes; attributes["from"] = account
        let node = XMLNode(name: original.name, namespace: original.namespace, attributes: attributes, text: original.text, children: original.children,
                                attributePrefixes: original.attributePrefixes)
        return try OMEMOWire.parseMessage(node)
    }

    /// Plain XEP-0444, for deciding whether a journaled reaction stanza may be replayed.
    public nonisolated static func decodeOutgoingReactionXML(_ xml: String, from account: String) -> XMPPReaction? {
        guard OMEMOWire.bareJID(account) == account else { return nil }
        var parser = XMLStreamFramer()
        guard let frames = try? parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml + "</stream:stream>").utf8)) else { return nil }
        let elements = frames.compactMap { frame -> XMLNode? in if case .element(let node) = frame { node } else { nil } }
        guard elements.count == 1, let original = elements.first, original.attributes["from"] == nil || original.attributes["from"] == account else { return nil }
        var attributes = original.attributes; attributes["from"] = account
        return parsedReaction(XMLNode(name: original.name, namespace: original.namespace, attributes: attributes, text: original.text, children: original.children,
                                attributePrefixes: original.attributePrefixes))
    }

    /// The plain receipt/marker twin of `decodeOutgoingReactionXML`.
    public nonisolated static func decodeOutgoingReceiptXML(_ xml: String, from account: String) -> XMPPReceipt? {
        guard OMEMOWire.bareJID(account) == account else { return nil }
        var parser = XMLStreamFramer()
        guard let frames = try? parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml + "</stream:stream>").utf8)) else { return nil }
        let elements = frames.compactMap { frame -> XMLNode? in if case .element(let node) = frame { node } else { nil } }
        guard elements.count == 1, let original = elements.first, original.attributes["from"] == nil || original.attributes["from"] == account else { return nil }
        var attributes = original.attributes; attributes["from"] = account
        return parsedReceipt(XMLNode(name: original.name, namespace: original.namespace, attributes: attributes, text: original.text, children: original.children,
                                attributePrefixes: original.attributePrefixes))
    }
}
