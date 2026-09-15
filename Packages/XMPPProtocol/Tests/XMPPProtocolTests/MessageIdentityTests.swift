import Foundation
import Testing
@testable import XMPPProtocol

private func stanza(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPClientError.unexpectedProtocol }
    return node
}

@Test func renderingPreservesCallerIdentityAndEscapesEveryField() throws {
    let id = "durable-'\"&<>-👋"
    let body = "first <line> & 'quotes'\nsecond 👋"
    let recipient = "a&b@example.test"
    let xml = try XMPPClient.messageXML(to: recipient, body: body, id: id)
    let node = try stanza(xml)
    #expect(node.attributes["id"] == id)
    #expect(node.attributes["to"] == recipient)
    #expect(node.child("body", namespace: "jabber:client")?.text == body)
    #expect(node.child("origin-id", namespace: "urn:xmpp:sid:0")?.attributes["id"] == id)
    #expect(try XMPPClient.messageXML(to: recipient, body: body, id: id) == xml)
}

@Test func renderingRejectsUnboundedOrInvalidXMLInputs() {
    for id in ["", "with space", "with\nnewline", "bad\0", "bad\u{FFFF}", String(repeating: "a", count: 1_025)] {
        #expect(throws: XMPPClientError.invalidConfiguration) { try XMPPClient.messageXML(to: "a@example.test", body: "hi", id: id) }
    }
    for body in ["", "bad\u{0001}", "bad\u{FFFE}", String(repeating: "a", count: 65_537)] {
        #expect(throws: XMPPClientError.invalidConfiguration) { try XMPPClient.messageXML(to: "a@example.test", body: body, id: "id") }
    }
    for recipient in ["", "a b", "a\0@example.test", String(repeating: "a", count: 3_072)] {
        #expect(throws: XMPPClientError.invalidConfiguration) { try XMPPClient.messageXML(to: recipient, body: "hi", id: "id") }
    }
}

@Test func parsingRetainsSeparateUntrustedStanzaAndOriginIdentity() throws {
    let node = try stanza("<message from='a@example.test/device' id='stanza-id' type='chat'><body>hi</body><origin-id xmlns='urn:xmpp:sid:0' id='origin-id'/></message>")
    let message = try #require(XMPPClient.parsedMessage(node))
    #expect(message.id == "stanza-id")
    #expect(message.originID == "origin-id")
    #expect(message.from == "a@example.test/device")
    #expect(message.type == "chat")
}

@Test func parsingIgnoresWrongNestedMissingAndAmbiguousOriginIdentifiers() throws {
    for extra in [
        "<origin-id xmlns='urn:wrong' id='wrong'/>",
        "<wrapper><origin-id xmlns='urn:xmpp:sid:0' id='nested'/></wrapper>",
        "<origin-id xmlns='urn:xmpp:sid:0'/>",
        "<origin-id xmlns='urn:xmpp:sid:0' id=''/>",
        "<origin-id xmlns='urn:xmpp:sid:0' id='one'/><origin-id xmlns='urn:xmpp:sid:0' id='two'/>"
    ] {
        let node = try stanza("<message from='a@example.test' id='stanza'><body>hi</body>\(extra)</message>")
        #expect(XMPPClient.parsedMessage(node)?.originID == nil)
        #expect(XMPPClient.parsedMessage(node)?.id == "stanza")
    }
}

@Test func parsingAcceptsUnencryptedXEP0444ReactionsAndKeepsThemOutOfPlaintextMessages() throws {
    // Shape sent by Conversations: no body, complete set, store hint.
    let node = try stanza("<message from='a@example.test/phone' to='me@example.test/ios' id='r1' type='chat'><reactions xmlns='urn:xmpp:reactions:0' id='target'><reaction>👍</reaction><reaction>👍</reaction><reaction>❤️</reaction></reactions><store xmlns='urn:xmpp:hints'/></message>")
    let reaction = try #require(XMPPClient.parsedReaction(node))
    #expect(reaction.id == "r1" && reaction.from == "a@example.test/phone" && reaction.targetID == "target")
    #expect(reaction.reactions == ["❤️", "👍"])
    #expect(XMPPClient.parsedMessage(node) == nil)
    // An empty set is a withdrawal, not garbage.
    #expect(try XMPPClient.parsedReaction(stanza("<message from='a@example.test' id='r2'><reactions xmlns='urn:xmpp:reactions:0' id='target'/></message>"))?.reactions == [])
    for bad in [
        "<message from='a@example.test' type='groupchat'><reactions xmlns='urn:xmpp:reactions:0' id='t'><reaction>👍</reaction></reactions></message>",
        "<message from='a@example.test'><reactions xmlns='urn:xmpp:reactions:0'><reaction>👍</reaction></reactions></message>",
        "<message from='a@example.test'><reactions xmlns='urn:wrong' id='t'><reaction>👍</reaction></reactions></message>",
        "<message from='a@example.test'><reactions xmlns='urn:xmpp:reactions:0' id='t'><reaction><b/></reaction></reactions></message>",
        "<message from='a@example.test'><reactions xmlns='urn:xmpp:reactions:0' id='t'/><reactions xmlns='urn:xmpp:reactions:0' id='u'/></message>",
        "<message from='a@example.test'><encrypted xmlns='eu.siacs.conversations.axolotl'/><reactions xmlns='urn:xmpp:reactions:0' id='t'/></message>"
    ] {
        #expect(try XMPPClient.parsedReaction(stanza(bad)) == nil)
    }
}

@Test func reactionRenderingRoundTripsThroughTheParserAndRejectsInvalidInput() throws {
    // Outgoing stanzas carry no `from`; the journal decoder stamps the account on before parsing.
    func received(_ xml: String) throws -> (XMPPProtocol.XMLNode, XMPPReaction?) {
        (try stanza(xml), XMPPClient.decodeOutgoingReactionXML(xml, from: "me@example.test"))
    }
    let (node, reaction) = try received(try XMPPClient.reactionXML(to: "a&b@example.test", targetID: "t<1>", reactions: ["👍", "❤️"], id: "r'1"))
    let parsed = try #require(reaction)
    #expect(parsed.id == "r'1" && parsed.targetID == "t<1>" && parsed.reactions == ["❤️", "👍"] && node.attributes["to"] == "a&b@example.test")
    #expect(node.child("store", namespace: "urn:xmpp:hints") != nil && node.child("body", namespace: "jabber:client") == nil)
    #expect(try received(try XMPPClient.reactionXML(to: "a@example.test", targetID: "t", reactions: [], id: "r2")).1?.reactions == [])
    #expect(XMPPClient.decodeOutgoingReactionXML("<message from='other@example.test' id='x'><reactions xmlns='urn:xmpp:reactions:0' id='t'/></message>", from: "me@example.test") == nil)
    #expect(XMPPClient.decodeOutgoingReactionXML("<message id='x'><body>hi</body></message>", from: "me@example.test") == nil)
    let invalid: [(String, String, [String], String)] = [("a b@example.test", "t", ["👍"], "r"), ("a@example.test", "", ["👍"], "r"), ("a@example.test", "t", [""], "r"),
                                                       ("a@example.test", "t", ["bad\u{0001}"], "r"), ("a@example.test", "t", Array(repeating: "👍", count: 13), "r"), ("a@example.test", "t", ["👍"], "with space")]
    for (to, target, reactions, id) in invalid {
        #expect(throws: XMPPClientError.invalidConfiguration) { try XMPPClient.reactionXML(to: to, targetID: target, reactions: reactions, id: id) }
    }
}
