import Foundation

/// One XEP-0490 item: the chat (a contact's or room's bare JID, the item id) was read on some device of this
/// account up to the message the stanza-id names. `by` is the archive that assigned it: the account's bare JID for
/// direct chats, the room for group chats. The id is opaque; resolving it to a stored message is the caller's work.
public struct XMPPDisplayedItem: Sendable, Equatable {
    public let chat: String
    public let stanzaID: String
    public let by: String
    public init(chat: String, stanzaID: String, by: String) { self.chat = chat; self.stanzaID = stanzaID; self.by = by }
}

/// XEP-0490 Message Displayed Synchronization (1.1.0) wire codecs, and the XEP-0359 `<stanza-id/>` the account's
/// own server assigns. Bounded and pure; the client decides who may have sent what.
public enum DisplayedSync {
    public static let node = "urn:xmpp:mds:displayed:0"
    static let namespace = node
    static let stanzaIDNamespace = "urn:xmpp:sid:0"
    /// A generous bound on one account's conversations; a larger node is refused rather than half applied.
    static let maximumItems = 5_000

    /// The `<item/>` body for one chat.
    static func itemXML(_ item: XMPPDisplayedItem) throws -> String {
        guard valid(item) else { throw XMPPClientError.invalidConfiguration }
        return "<item id='\(xmlEscaped(item.chat))'><displayed xmlns='\(namespace)'><stanza-id xmlns='\(stanzaIDNamespace)' by='\(xmlEscaped(item.by))' id='\(xmlEscaped(item.stanzaID))'/></displayed></item>"
    }

    /// XEP-0490 §4: the node options every publish asserts. A node created with other defaults is reconfigured first.
    static let nodeOptions = "<field var='pubsub#persist_items'><value>true</value></field><field var='pubsub#max_items'><value>max</value></field>"
        + "<field var='pubsub#send_last_published_item'><value>never</value></field><field var='pubsub#access_model'><value>whitelist</value></field>"

    static func publishXML(_ item: XMPPDisplayedItem) throws -> String {
        "<pubsub xmlns='\(OMEMOWire.pubsub)'><publish node='\(node)'>\(try itemXML(item))</publish><publish-options><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/pubsub#publish-options</value></field>\(nodeOptions)</x></publish-options></pubsub>"
    }

    static func configureXML() -> String {
        "<pubsub xmlns='http://jabber.org/protocol/pubsub#owner'><configure node='\(node)'><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/pubsub#node_config</value></field>\(nodeOptions)</x></configure></pubsub>"
    }

    static let fetchXML = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(node)'/></pubsub>"

    /// One `<item/>` of the node, from an IQ result (pubsub namespace) or an event (pubsub#event namespace).
    /// Anything unexpected makes the item unusable (nil), never a guess.
    static func parseItem(_ item: XMLNode, namespace container: String) -> XMPPDisplayedItem? {
        guard item.name == "item", item.namespace == container, let chat = item.attributes["id"].flatMap(JID.normalized), validJID(chat),
              item.children.count == 1, item.children[0].name == "displayed", item.children[0].namespace == namespace else { return nil }
        let displayed = item.children[0]
        let identifiers = displayed.children.filter { $0.name == "stanza-id" && $0.namespace == stanzaIDNamespace }
        guard identifiers.count == 1, let id = identifiers[0].attributes["id"], let by = identifiers[0].attributes["by"].flatMap(JID.normalized),
              identifiers[0].children.isEmpty else { return nil }
        let parsed = XMPPDisplayedItem(chat: chat, stanzaID: id, by: by)
        return valid(parsed) ? parsed : nil
    }

    /// The items of an IQ result for the node. A node without items is an empty list; malformed items are skipped.
    static func items(fromResult response: XMLNode) throws -> [XMPPDisplayedItem] {
        let pubsub = try OMEMOWire.singleton(response, "pubsub", OMEMOWire.pubsub)
        let items = try OMEMOWire.singleton(pubsub, "items", OMEMOWire.pubsub)
        guard items.attributes["node"] == node, items.children.count <= maximumItems else { throw XMPPIQError.malformedResponse }
        return items.children.compactMap { parseItem($0, namespace: OMEMOWire.pubsub) }
    }

    /// A PEP notification for the node. XEP-0490 §7: only a notification from the account's own bare JID counts;
    /// anyone else's (a contact's node of the same name, a forged `from`) returns nil. Retractions carry no state.
    static func event(_ message: XMLNode, accountBareJID: String) -> [XMPPDisplayedItem]? {
        guard message.name == "message", message.namespace == "jabber:client", message.attributes["from"] == accountBareJID,
              let event = try? OMEMOWire.singleton(message, "event", OMEMOWire.eventNamespace),
              let items = try? OMEMOWire.singleton(event, "items", OMEMOWire.eventNamespace),
              items.attributes["node"] == node, items.children.count <= maximumItems else { return nil }
        return items.children.compactMap { parseItem($0, namespace: OMEMOWire.eventNamespace) }
    }

    /// XEP-0359: the stanza-id the account's own server assigned to a message it archived. Only an element whose
    /// `by` is the account's bare JID counts (the server strips client-supplied ones with that `by`); none or more
    /// than one is nil.
    static func ownStanzaID(_ message: XMLNode, accountBareJID: String) -> String? {
        let identifiers = message.children.filter { $0.name == "stanza-id" && $0.namespace == stanzaIDNamespace && $0.attributes["by"].flatMap(JID.normalized) == accountBareJID }
        guard identifiers.count == 1, let id = identifiers[0].attributes["id"], identifiers[0].children.isEmpty,
              OMEMOWire.validStanzaID(id) else { return nil }
        return id
    }

    static func valid(_ item: XMPPDisplayedItem) -> Bool {
        validJID(item.chat) && OMEMOWire.bareJID(item.by) == item.by && OMEMOWire.validStanzaID(item.stanzaID)
            && MessageContent.validXMLText(item.stanzaID)
    }

    /// A bare JID (contacts, rooms). Private-message items (a full JID) are not a chat this client keeps.
    private static func validJID(_ value: String) -> Bool { OMEMOWire.bareJID(value) == value && MessageContent.validAddress(value) }
}
