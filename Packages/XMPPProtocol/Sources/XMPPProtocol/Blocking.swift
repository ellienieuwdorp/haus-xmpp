import Foundation

// XEP-0191 Blocking Command 1.3 (`urn:xmpp:blocking`) with XEP-0377 Blocking Command Reports 0.4.1
// (`urn:xmpp:reporting:1`). The account's server keeps and enforces the list for every session; a client only reads
// it, asks for changes and follows the server's pushes.

/// XEP-0377 §3 reasons.
public enum XMPPReportReason: String, Sendable, Equatable, CaseIterable {
    /// Unwanted messages, such as advertising.
    case spam = "urn:xmpp:reporting:spam"
    /// Any other abuse: harassment, threats.
    case abuse = "urn:xmpp:reporting:abuse"
}

/// A XEP-0359 `<stanza-id/>`: `by` is the archive that assigned it (the account's bare JID for a direct chat).
public struct XMPPStanzaReference: Sendable, Equatable, Hashable {
    public let id: String
    public let by: String
    public init(id: String, by: String) { self.id = id; self.by = by }
}

/// A XEP-0377 report riding on a block. The server blocks exactly as it would without it (XEP-0377 §6); a server
/// that does not know the namespace ignores it.
public struct XMPPBlockReport: Sendable, Equatable {
    public let reason: XMPPReportReason
    /// XEP-0377 §6 allows these only when the server has a XEP-0313 archive, where they point.
    public let messages: [XMPPStanzaReference]
    public init(reason: XMPPReportReason, messages: [XMPPStanzaReference] = []) { self.reason = reason; self.messages = messages }
}

/// In stream order.
public enum XMPPBlocklistChange: Sendable, Equatable {
    /// The whole list, from a fetch (XEP-0191 §3.2).
    case replaceAll(Set<String>)
    /// A server push (§3.3, §3.4): this or another session of the account blocked or unblocked these addresses.
    case blocked(Set<String>)
    case unblocked(Set<String>)
    /// An `<unblock/>` push without items (§3.5).
    case unblockedAll
}

/// The account's blocked addresses, in normal form, with the XEP-0191 §3.1 matching rules (those of XEP-0016 §2.1).
public struct XMPPBlocklist: Sendable, Equatable, Codable {
    public private(set) var addresses: Set<String>

    public init(_ addresses: Set<String> = []) {
        self.addresses = Set(addresses.compactMap(JID.normalized))
    }

    public var isEmpty: Bool { addresses.isEmpty }

    /// Matches an entry for the full address, its bare address, its domain with the same resource, or its domain alone.
    /// A full-JID entry blocks only that resource, so a bare address is blocked only by its bare or domain entry.
    public func blocks(_ address: String) -> Bool {
        guard let jid = JID(address) else { return false }
        if addresses.contains(jid.full) || addresses.contains(jid.bare) || addresses.contains(jid.domainpart) { return true }
        if let resource = jid.resourcepart, addresses.contains(jid.domainpart + "/" + resource) { return true }
        return false
    }

    public mutating func apply(_ change: XMPPBlocklistChange) {
        switch change {
        case .replaceAll(let all): addresses = Set(all.compactMap(JID.normalized))
        case .blocked(let added): addresses.formUnion(added.compactMap(JID.normalized))
        case .unblocked(let removed): addresses.subtract(removed.compactMap(JID.normalized))
        case .unblockedAll: addresses.removeAll()
        }
    }

    public func applying(_ change: XMPPBlocklistChange) -> XMPPBlocklist {
        var copy = self
        copy.apply(change)
        return copy
    }
}

enum BlockingWire {
    static let namespace = "urn:xmpp:blocking"
    static let reportingNamespace = "urn:xmpp:reporting:1"
    static let stanzaIDNamespace = "urn:xmpp:sid:0"
    static let maximumItems = 10_000
    // More IDs in one report add nothing.
    static let maximumReportedMessages = 20

    // A non-JID item is skipped in a fetched list but makes a push malformed: a push is all or nothing.
    static func items(_ element: XMLNode, strict: Bool) throws -> Set<String> {
        let items = element.children.filter { $0.name == "item" && $0.namespace == namespace }
        guard items.count <= maximumItems else { throw XMPPIQError.malformedResponse }
        var addresses = Set<String>()
        for item in items {
            guard let raw = item.attributes["jid"], let address = JID.normalized(raw) else {
                if strict { throw XMPPIQError.malformedResponse }
                continue
            }
            addresses.insert(address)
        }
        return addresses
    }

    // §3.2 result: exactly one `<blocklist/>`, possibly empty.
    static func blocklistResult(_ response: XMLNode) throws -> Set<String> {
        try items(OMEMOWire.singleton(response, "blocklist", namespace), strict: false)
    }

    // §3.3 request, with an optional XEP-0377 report on the single item.
    static func blockXML(_ address: String, report: XMPPBlockReport?) throws -> String {
        guard let jid = JID.normalized(address), MessageContent.validXMLText(jid) else { throw XMPPClientError.invalidConfiguration }
        guard let report else { return "<block xmlns='\(namespace)'><item jid='\(xmlEscaped(jid))'/></block>" }
        var references = ""
        for message in report.messages.prefix(maximumReportedMessages) {
            guard !message.id.isEmpty, MessageContent.validXMLText(message.id), let by = JID.normalized(message.by) else {
                throw XMPPClientError.invalidConfiguration
            }
            references += "<stanza-id xmlns='\(stanzaIDNamespace)' by='\(xmlEscaped(by))' id='\(xmlEscaped(message.id))'/>"
        }
        let open = "<report xmlns='\(reportingNamespace)' reason='\(report.reason.rawValue)'"
        let element = references.isEmpty ? open + "/>" : open + ">" + references + "</report>"
        return "<block xmlns='\(namespace)'><item jid='\(xmlEscaped(jid))'>\(element)</item></block>"
    }

    // §3.4 request. An empty list would unblock everything (§3.5).
    static func unblockXML(_ addresses: [String]) throws -> String {
        let normal = addresses.compactMap(JID.normalized)
        guard !normal.isEmpty, normal.count == addresses.count, normal.allSatisfy(MessageContent.validXMLText) else {
            throw XMPPClientError.invalidConfiguration
        }
        return "<unblock xmlns='\(namespace)'>" + normal.map { "<item jid='\(xmlEscaped($0))'/>" }.joined() + "</unblock>"
    }

    // A §3.3/§3.4/§3.5 push is legitimate only without `from` or from our own bare address (as RFC 6121 §2.1.6 roster
    // pushes), carrying one `<block/>` with items or one `<unblock/>`.
    static func push(_ node: XMLNode, accountBareJID: String) -> XMPPBlocklistChange? {
        guard node.name == "iq", node.namespace == "jabber:client", node.attributes["type"] == "set",
              node.attributes["from"] == nil || node.attributes["from"] == accountBareJID,
              node.children.count == 1, let element = node.children.first, element.namespace == namespace,
              let addresses = try? items(element, strict: true) else { return nil }
        switch element.name {
        case "block": return addresses.isEmpty ? nil : .blocked(addresses)
        case "unblock": return addresses.isEmpty ? .unblockedAll : .unblocked(addresses)
        default: return nil
        }
    }
}
