import Foundation
import Testing
@testable import XMPPProtocol

/// XEP-0424 retractions and XEP-0308 corrections share the one payload grammar with bodies and reactions.
private func stanza(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPClientError.unexpectedProtocol }
    return node
}

@Test func retractionStanzaFallbackBodyIsNeverAMessage() throws {
    let xml = try XMPPClient.retractionXML(to: "bob@localhost", targetID: "orig-1", id: "r-1")
    let node = try stanza(xml)
    #expect(node.child("body", namespace: "jabber:client")?.text == MessageContent.retractionFallback)
    let content = try MessageContent.decode(node, strict: false)
    #expect(content.retraction == "orig-1" && content.body.isEmpty && content.reply == nil && content.reaction == nil)
    // The fallback text must not surface as a chat message, and the twin decoder sees the retraction.
    #expect(XMPPClient.parsedMessage(node) == nil)
    #expect(XMPPClient.parsedReaction(node) == nil)
    let retraction = try #require(XMPPClient.decodeOutgoingRetractionXML(xml, from: "alice@localhost"))
    #expect(retraction.id == "r-1" && retraction.targetID == "orig-1" && retraction.to == "bob@localhost")
    #expect(XMPPClient.decodeOutgoingRetractionXML(xml.replacingOccurrences(of: "<retract", with: "<retract xmlns='urn:xmpp:other'"), from: "alice@localhost") == nil)
}

@Test func correctionRidesWithItsBodyAndContradictionsAreRejectedWhenAuthenticated() throws {
    let payload = try MessageContent(body: "fixed text", correction: "orig-1").xml()
    let node = try stanza("<message from='alice@localhost/phone' type='chat' id='c-1'>\(payload)</message>")
    let content = try MessageContent.decode(node, strict: true)
    #expect(content.correction == "orig-1" && content.body == "fixed text" && content.retraction == nil)
    // A retraction next to other content is tampering in an authenticated payload and dropped otherwise.
    let contradiction = "<message from='a@x'><retract xmlns='urn:xmpp:message-retract:1' id='o'/><reactions xmlns='urn:xmpp:reactions:0' id='o'><reaction>👍</reaction></reactions></message>"
    #expect(throws: XMPPClientError.self) { try MessageContent.decode(stanza(contradiction), strict: true) }
    let lenient = try MessageContent.decode(stanza(contradiction), strict: false)
    #expect(lenient.retraction == "o" && lenient.reaction == nil)
    // A replace without a body is not a correction; two replaces are ambiguous.
    #expect(try MessageContent.decode(stanza("<message from='a@x'><replace xmlns='urn:xmpp:message-correct:0' id='o'/></message>"), strict: false).correction == nil)
    #expect(throws: XMPPClientError.self) {
        try MessageContent.decode(stanza("<message from='a@x'><body>b</body><replace xmlns='urn:xmpp:message-correct:0' id='o'/><replace xmlns='urn:xmpp:message-correct:0' id='p'/></message>"), strict: true)
    }
    // The encoder refuses a retraction with content and a correction without a body.
    #expect(throws: XMPPClientError.self) { try MessageContent(body: "x", retraction: "o").xml() }
    #expect(throws: XMPPClientError.self) { try MessageContent(body: "", correction: "o").xml() }
    #expect(throws: XMPPClientError.self) { try MessageContent(body: "", retraction: "with space").xml() }
}

@Test func encryptedStanzaCarriesTheLegacyCorrectionReferenceOutsideTheCiphertext() throws {
    let envelope = XMPPOMEMOEnvelope(profile: .legacy, senderDeviceID: 1, keys: [.init(deviceID: 2, keyExchange: false, data: Data([1]))],
                                     iv: Data(repeating: 0, count: 12), payload: Data([2]))
    let xml = try XMPPClient.encryptedMessageXML(to: "bob@localhost", envelope: envelope, id: "c-1", replaces: "orig-1")
    let decoded = try XMPPClient.decodeOutgoingEncryptedMessageXML(xml, from: "alice@localhost")
    #expect(decoded.id == "c-1" && decoded.replaces == "orig-1" && decoded.envelope == envelope)
    let plain = try XMPPClient.encryptedMessageXML(to: "bob@localhost", envelope: envelope, id: "m-1")
    #expect(try XMPPClient.decodeOutgoingEncryptedMessageXML(plain, from: "alice@localhost").replaces == nil)
    #expect(throws: XMPPClientError.self) { try XMPPClient.encryptedMessageXML(to: "bob@localhost", envelope: envelope, id: "c-1", replaces: "with space") }
    // Two references are ambiguous and ignored, never chosen by order.
    let twice = xml.replacingOccurrences(of: "<replace xmlns='urn:xmpp:message-correct:0' id='orig-1'/>", with: "<replace xmlns='urn:xmpp:message-correct:0' id='orig-1'/><replace xmlns='urn:xmpp:message-correct:0' id='orig-2'/>")
    #expect(try XMPPClient.decodeOutgoingEncryptedMessageXML(twice, from: "alice@localhost").replaces == nil)
}
