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
