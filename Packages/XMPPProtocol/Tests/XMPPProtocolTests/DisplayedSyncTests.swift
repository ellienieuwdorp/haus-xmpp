import Foundation
import Testing
@testable import XMPPProtocol

// XEP-0490 1.1.0 (accessed 2026-09-28): node urn:xmpp:mds:displayed:0, item id = chat JID,
// <displayed xmlns='urn:xmpp:mds:displayed:0'><stanza-id xmlns='urn:xmpp:sid:0' by=… id=…/></displayed>.

private func node(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}

private let account = "juliet@capulet.lit"
private func item(_ chat: String, id: String, by: String) -> String {
    "<item id='\(chat)'><displayed xmlns='urn:xmpp:mds:displayed:0'><stanza-id xmlns='urn:xmpp:sid:0' by='\(by)' id='\(id)'/></displayed></item>"
}

@Test func displayedItemRoundTripsThroughPublishAndResult() throws {
    let direct = XMPPDisplayedItem(chat: "romeo@montegue.lit", stanzaID: "0f710f2b-52ed-4d52-b928-784dad74a52b", by: account)
    let room = XMPPDisplayedItem(chat: "orchard@rooms.capulet.lit", stanzaID: "room-7", by: "orchard@rooms.capulet.lit")
    let publish = try DisplayedSync.publishXML(direct)
    // The XEP's publish options, all four.
    for option in ["pubsub#persist_items'><value>true", "pubsub#max_items'><value>max", "pubsub#send_last_published_item'><value>never", "pubsub#access_model'><value>whitelist"] {
        #expect(publish.contains(option))
    }
    #expect(publish.contains("<publish node='urn:xmpp:mds:displayed:0'><item id='romeo@montegue.lit'>"))
    // What we publish is what a fetch hands back.
    let items = try DisplayedSync.itemXML(direct) + DisplayedSync.itemXML(room)
    let result = try node("<iq type='result' from='\(account)' id='1'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:mds:displayed:0'>\(items)</items></pubsub></iq>")
    #expect(try DisplayedSync.items(fromResult: result) == [direct, room])
    let empty = try node("<iq type='result' id='1'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:mds:displayed:0'/></pubsub></iq>")
    #expect(try DisplayedSync.items(fromResult: empty) == [])
    let otherNode = try node("<iq type='result' id='1'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:bookmarks:1'/></pubsub></iq>")
    #expect(throws: XMPPIQError.malformedResponse) { try DisplayedSync.items(fromResult: otherNode) }
    // Invalid values never reach the wire.
    #expect(throws: XMPPClientError.self) { try DisplayedSync.itemXML(XMPPDisplayedItem(chat: "romeo@montegue.lit", stanzaID: "has space", by: account)) }
    #expect(throws: XMPPClientError.self) { try DisplayedSync.itemXML(XMPPDisplayedItem(chat: "romeo@montegue.lit/phone", stanzaID: "x", by: account)) }
}

@Test func malformedItemsAreSkippedNotGuessed() throws {
    let good = item("romeo@montegue.lit", id: "a", by: account)
    let shapes = [
        "<item id='romeo@montegue.lit'><displayed xmlns='urn:xmpp:mds:displayed:0'/></item>",                                  // no stanza-id
        "<item id='romeo@montegue.lit'><displayed xmlns='urn:xmpp:mds:displayed:0'><stanza-id xmlns='urn:xmpp:sid:0' by='\(account)' id='a'/><stanza-id xmlns='urn:xmpp:sid:0' by='\(account)' id='b'/></displayed></item>",
        "<item id='romeo@montegue.lit'><displayed xmlns='urn:xmpp:mds:other'><stanza-id xmlns='urn:xmpp:sid:0' by='\(account)' id='a'/></displayed></item>",
        item("montegue.lit", id: "a", by: account),                                                                          // not a bare JID of a chat
        "<item id='romeo@montegue.lit'><displayed xmlns='urn:xmpp:mds:displayed:0'><stanza-id xmlns='urn:xmpp:sid:0' id='a'/></displayed></item>", // no by
    ]
    let event = try node("<message from='\(account)' to='\(account)/balcony' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:mds:displayed:0'>\(shapes.joined())\(good)</items></event></message>")
    #expect(DisplayedSync.event(event, accountBareJID: account) == [XMPPDisplayedItem(chat: "romeo@montegue.lit", stanzaID: "a", by: account)])
}

@Test func onlyOurOwnBareJIDMayNotifyDisplayedState() throws {
    let payload = "<event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:mds:displayed:0'>\(item("romeo@montegue.lit", id: "a", by: account))</items></event>"
    // XEP-0490 §7: a contact's node of the same name, or our full JID, is not our account's state.
    for from in ["romeo@montegue.lit", account + "/balcony", "capulet.lit"] {
        #expect(DisplayedSync.event(try node("<message from='\(from)' to='\(account)/balcony' type='headline'>\(payload)</message>"), accountBareJID: account) == nil)
    }
    #expect(DisplayedSync.event(try node("<message to='\(account)/balcony' type='headline'>\(payload)</message>"), accountBareJID: account) == nil)
    #expect(DisplayedSync.event(try node("<message from='\(account)' to='\(account)/balcony' type='headline'>\(payload)</message>"), accountBareJID: account)?.count == 1)
    // Another node's notification is not ours to interpret.
    let other = "<message from='\(account)'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:avatar:metadata'/></event></message>"
    #expect(DisplayedSync.event(try node(other), accountBareJID: account) == nil)
}

@Test func ownStanzaIDIsTheOneOurServerAssigned() throws {
    func message(_ ids: String) throws -> XMPPProtocol.XMLNode { try node("<message from='romeo@montegue.lit/x' to='\(account)/balcony' type='chat'>\(ids)<body>x</body></message>") }
    #expect(DisplayedSync.ownStanzaID(try message("<stanza-id xmlns='urn:xmpp:sid:0' by='\(account)' id='s1'/>"), accountBareJID: account) == "s1")
    // A room's or a peer's stanza-id is not our archive's.
    #expect(DisplayedSync.ownStanzaID(try message("<stanza-id xmlns='urn:xmpp:sid:0' by='romeo@montegue.lit' id='s1'/>"), accountBareJID: account) == nil)
    // Two claims for our archive are ambiguous.
    #expect(DisplayedSync.ownStanzaID(try message("<stanza-id xmlns='urn:xmpp:sid:0' by='\(account)' id='s1'/><stanza-id xmlns='urn:xmpp:sid:0' by='\(account)' id='s2'/>"), accountBareJID: account) == nil)
    #expect(DisplayedSync.ownStanzaID(try message(""), accountBareJID: account) == nil)
}

@Test func ownArchiveEntryCarriesItsResultIDAsTheStanzaID() throws {
    var query = ArchiveQuery(queryID: "q", accountBareJID: "alice@localhost", accountFullJID: "alice@localhost/ios", limit: 10)
    let inner = "<message xmlns='jabber:client' from='bob@localhost/x' to='alice@localhost' type='chat' id='m1'><encrypted xmlns='eu.siacs.conversations.axolotl'><header sid='7'><key rid='9'>AQID</key><iv>AAAAAAAAAAAAAAAA</iv></header><payload>AAAA</payload></encrypted></message>"
    try query.receive(node("<message xmlns='jabber:client' to='alice@localhost/ios'><result xmlns='urn:xmpp:mam:2' queryid='q' id='arch-1'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-09-01T10:00:00Z'/>\(inner)</forwarded></result></message>"))
    #expect(query.messages.first?.encryptedMessage?.archiveStanzaID == "arch-1")
}

@Test func capsAdvertiseDisplayedSyncNotifications() {
    #expect(EntityCapabilities.features.contains("urn:xmpp:mds:displayed:0+notify"))
    #expect(EntityCapabilities.discoInfoQuery(node: nil).contains("<feature var='urn:xmpp:mds:displayed:0+notify'/>"))
}

/// The node is private (whitelist): a response that fails to decode is logged by shape only, never with the contact
/// and room JIDs or stanza-ids its attributes carry.
@Test func malformedDisplayedSyncIsLoggedWithoutAttributes() throws {
    let items = item("romeo@montegue.lit", id: "secret-stanza", by: account) + item("orchard@rooms.capulet.lit", id: "room-7", by: "orchard@rooms.capulet.lit")
    let result = try node("<iq type='result' from='\(account)' id='1'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:bookmarks:1'>\(items)</items></pubsub></iq>")
    #expect(throws: XMPPIQError.malformedResponse) { try DisplayedSync.items(fromResult: result) }
    let logged = XMPPClient.shape(result)
    #expect(logged == "iq#1[pubsub#1[items#2[item#1[…],item#1[…]]]]")
    for value in ["romeo", "orchard", "capulet", "juliet", "secret", "room-7", "bookmarks"] { #expect(!logged.contains(value)) }
}
