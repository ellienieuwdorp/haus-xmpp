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


@Test func receiptRequestsAndReceiptsRoundTripThroughTheOneCodec() throws {
    // A sent message asks for both; the elements ride outside SCE and never carry content.
    let asked = try stanza(try XMPPClient.messageXML(to: "a@example.test", body: "hi", id: "m1", requestReceipt: true, markable: true))
    #expect(asked.child("request", namespace: "urn:xmpp:receipts") != nil && asked.child("markable", namespace: "urn:xmpp:chat-markers:0") != nil)
    let decoded = try MessageContent.decode(asked, strict: true)
    #expect(decoded.requestsReceipt && decoded.markable && decoded.receipt == nil && decoded.body == "hi")
    let quiet = try MessageContent.decode(try stanza(try XMPPClient.messageXML(to: "a@example.test", body: "hi", id: "m2")), strict: true)
    #expect(!quiet.requestsReceipt && !quiet.markable)
    // Receipts and markers: no body, one target, store hint, same shape Conversations sends.
    for kind in [MessageContent.Receipt.Kind.delivered, .displayed] {
        let xml = try XMPPClient.receiptXML(to: "a&b@example.test", targetID: "t<1>", kind: kind, id: "r'1")
        let node = try stanza(xml)
        let receipt = try #require(XMPPClient.decodeOutgoingReceiptXML(xml, from: "me@example.test"))
        #expect(receipt.id == "r'1" && receipt.targetID == "t<1>" && receipt.kind == kind && node.attributes["to"] == "a&b@example.test")
        #expect(node.child("body", namespace: "jabber:client") == nil && node.child("store", namespace: "urn:xmpp:hints") != nil)
        #expect(XMPPClient.parsedMessage(node) == nil && XMPPClient.parsedReaction(node) == nil)
        #expect(try MessageContent.decode(node, strict: true).receipt == .init(targetID: "t<1>", kind: kind))
    }
    // Encrypted stanzas carry the flags in the clear, next to the envelope.
    let envelope = XMPPOMEMOEnvelope(profile: .legacy, senderDeviceID: 1, keys: [.init(deviceID: 2, keyExchange: false, data: Data([1]))], iv: Data(repeating: 0, count: 12), payload: Data([2]))
    let encrypted = try XMPPClient.decodeOutgoingEncryptedMessageXML(try XMPPClient.encryptedMessageXML(to: "a@example.test", envelope: envelope, id: "e1", requestReceipt: true, markable: false), from: "me@example.test")
    #expect(encrypted.requestsReceipt && !encrypted.markable)
    #expect(try !XMPPClient.decodeOutgoingEncryptedMessageXML(try XMPPClient.encryptedMessageXML(to: "a@example.test", envelope: envelope, id: "e2"), from: "me@example.test").requestsReceipt)
    // Two receipts, a receipt of both kinds, or a malformed one is ambiguous under strict decoding and dropped when lenient.
    for bad in [
        "<received xmlns='urn:xmpp:receipts' id='a'/><received xmlns='urn:xmpp:receipts' id='b'/>",
        "<received xmlns='urn:xmpp:receipts' id='a'/><displayed xmlns='urn:xmpp:chat-markers:0' id='a'/>",
        "<received xmlns='urn:xmpp:receipts'/>",
        "<displayed xmlns='urn:xmpp:chat-markers:0' id='with space'/>"
    ] {
        let node = try stanza("<message from='a@example.test' id='x'>\(bad)</message>")
        #expect(throws: XMPPClientError.invalidConfiguration) { try MessageContent.decode(node, strict: true) }
        #expect(try MessageContent.decode(node, strict: false).receipt == nil)
        #expect(XMPPClient.parsedReceipt(node) == nil)
    }
    #expect(throws: XMPPClientError.invalidConfiguration) { try XMPPClient.receiptXML(to: "a@example.test", targetID: "with space", kind: .delivered, id: "r") }
}
