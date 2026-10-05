import Foundation

/// A contact resource's availability (RFC 6121 §4) with its XEP-0319 idle time. `<show/>`, `<status/>` and
/// priority are ignored. The sender is server-stamped; presence from our own other resources is kept.
public struct XMPPContactPresence: Sendable, Equatable {
    /// The contact's bare address.
    public let contact: String
    public let resource: String?
    public let available: Bool
    /// XEP-0319 `since`, only on an available presence.
    public let idleSince: Date?
    public init(contact: String, resource: String?, available: Bool, idleSince: Date? = nil) {
        self.contact = contact; self.resource = resource; self.available = available; self.idleSince = idleSince
    }
}

/// RFC 6121 §3 subscription presence types.
public enum XMPPSubscriptionRequest: String, Sendable, Equatable, CaseIterable {
    case subscribe, subscribed, unsubscribe, unsubscribed
}

/// A subscription presence from a contact's bare address.
public struct XMPPSubscriptionEvent: Sendable, Equatable {
    public let from: String
    public let kind: XMPPSubscriptionRequest
    public init(from: String, kind: XMPPSubscriptionRequest) { self.from = from; self.kind = kind }
}

/// One RFC 6121 §2.1.2 roster item. `askPending` is `ask='subscribe'`: our request awaits the contact.
public struct XMPPRosterItem: Sendable, Equatable {
    public enum Subscription: String, Sendable, Equatable, CaseIterable { case none, to, from, both, remove }
    public let jid: String
    public let subscription: Subscription
    public let askPending: Bool
    public init(jid: String, subscription: Subscription, askPending: Bool = false) {
        self.jid = jid; self.subscription = subscription; self.askPending = askPending
    }
}

enum PresenceWire {
    static let rosterNamespace = "jabber:iq:roster"
    static let lastActivityNamespace = "jabber:iq:last"
    static let idleNamespace = "urn:xmpp:idle:1"
    static let maximumRosterItems = 10_000

    /// A non-room presence from a contact, addressed to us: a subscription change or an availability.
    /// Errors, probes and unknown types are dropped. Rooms keep their own path.
    static func event(_ node: XMLNode, accountBareJID: String, accountFullJID: String, rooms: Set<String>) -> XMPPEvent? {
        guard node.name == "presence", node.namespace == "jabber:client",
              let from = node.attributes["from"], let bare = OMEMOWire.bareJID(from), !rooms.contains(bare) else { return nil }
        if let to = node.attributes["to"], to != accountBareJID, to != accountFullJID { return nil }
        let type = node.attributes["type"]
        if let type, let kind = XMPPSubscriptionRequest(rawValue: type) {
            return .subscription(XMPPSubscriptionEvent(from: bare, kind: kind))
        }
        guard type == nil || type == "unavailable" else { return nil }
        let resource = from.count > bare.count + 1 ? String(from.dropFirst(bare.count + 1)) : nil
        guard from == bare || from.hasPrefix(bare + "/") && resource != nil else { return nil }
        let available = type == nil
        var idleSince: Date?
        if available, let idle = try? OMEMOWire.singleton(node, "idle", idleNamespace), let since = idle.attributes["since"] {
            idleSince = ArchiveQuery.timestamp(since)
        }
        return .contactPresence(XMPPContactPresence(contact: bare, resource: resource, available: available, idleSince: idleSince))
    }

    static func subscriptionXML(_ kind: XMPPSubscriptionRequest, to bare: String) throws -> String {
        guard OMEMOWire.bareJID(bare) == bare, MessageContent.validXMLText(bare) else { throw XMPPClientError.invalidConfiguration }
        return "<presence to='\(xmlEscaped(bare))' type='\(kind.rawValue)'/>"
    }

    /// Items that are not bare user addresses or carry an unknown subscription are skipped, not fatal.
    static func rosterItems(_ query: XMLNode) throws -> [XMPPRosterItem] {
        guard query.name == "query", query.namespace == rosterNamespace else { throw XMPPIQError.malformedResponse }
        let items = query.children.filter { $0.name == "item" && $0.namespace == rosterNamespace }
        guard items.count <= maximumRosterItems else { throw XMPPIQError.malformedResponse }
        return items.compactMap { item in
            guard let raw = item.attributes["jid"], !raw.contains("/"), let jid = OMEMOWire.bareJID(raw),
                  let subscription = XMPPRosterItem.Subscription(rawValue: item.attributes["subscription"] ?? "none") else { return nil }
            return XMPPRosterItem(jid: jid, subscription: subscription, askPending: item.attributes["ask"] == "subscribe")
        }
    }

    /// RFC 6121 §2.1.3 result. A server may omit the query when the roster is empty.
    static func rosterResult(_ response: XMLNode) throws -> [XMPPRosterItem] {
        let queries = response.children.filter { $0.name == "query" && $0.namespace == rosterNamespace }
        if queries.isEmpty, response.children.isEmpty { return [] }
        guard queries.count == 1 else { throw XMPPIQError.malformedResponse }
        return try rosterItems(queries[0])
    }

    /// RFC 6121 §2.1.6: a push is legitimate only without `from` or from our own bare address,
    /// and carries exactly one item. Anything else is not a push.
    static func rosterPush(_ node: XMLNode, accountBareJID: String) -> XMPPRosterItem? {
        guard node.name == "iq", node.namespace == "jabber:client", node.attributes["type"] == "set",
              node.attributes["from"] == nil || node.attributes["from"] == accountBareJID,
              node.children.count == 1, let query = node.child("query", namespace: rosterNamespace),
              query.children.count == 1, let items = try? rosterItems(query), items.count == 1 else { return nil }
        return items[0]
    }

    /// XEP-0012 seconds from an answer; a missing or non-numeric count is malformed.
    static func lastActivitySeconds(_ response: XMLNode) throws -> Int {
        let query = try OMEMOWire.singleton(response, "query", lastActivityNamespace)
        guard let text = query.attributes["seconds"], !text.isEmpty, text.utf8.count <= 12,
              text.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Int(text) else { throw XMPPIQError.malformedResponse }
        return seconds
    }

    /// The inline answer to an inbound IQ get/set that is not a roster push: disco#info, ping,
    /// XEP-0012 to our full address while sharing is on, otherwise `service-unavailable`.
    static func inlineResponse(_ node: XMLNode, accountFullJID: String, sharesLastActivity: Bool) -> String? {
        guard node.name == "iq", node.namespace == "jabber:client",
              ["get", "set"].contains(node.attributes["type"] ?? ""), let id = node.attributes["id"] else { return nil }
        let to = node.attributes["from"].map { " to='\(xmlEscaped($0))'" } ?? ""
        let get = node.attributes["type"] == "get" && node.children.count == 1
        if get, let query = node.child("query", namespace: "http://jabber.org/protocol/disco#info") {
            return "<iq type='result' id='\(xmlEscaped(id))'\(to)>\(EntityCapabilities.discoInfoQuery(node: query.attributes["node"]))</iq>"
        }
        if node.child("ping", namespace: "urn:xmpp:ping") != nil {
            return "<iq type='result' id='\(xmlEscaped(id))'\(to)/>"
        }
        // The app is connected only while in front, so an answer is always "active now".
        if get, sharesLastActivity, !accountFullJID.isEmpty, node.attributes["to"] == accountFullJID,
           let query = node.child("query", namespace: lastActivityNamespace), query.children.isEmpty {
            return "<iq type='result' id='\(xmlEscaped(id))'\(to)><query xmlns='\(lastActivityNamespace)' seconds='0'/></iq>"
        }
        return "<iq type='error' id='\(xmlEscaped(id))'\(to)><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
    }
}
