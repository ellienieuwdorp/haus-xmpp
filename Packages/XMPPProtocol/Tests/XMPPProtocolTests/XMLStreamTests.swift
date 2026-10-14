import Foundation
import Testing
@testable import XMPPProtocol

private let opening = "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' xmlns:p='urn:test'>"

@Test func fragmentedUnicodeAndNamespaces() throws {
    let xml = opening + "<message from='alice@example.test'><body>Hi 👋 &amp; goodbye</body><p:detail a='greater > less'>ok</p:detail></message>"
    var parser = XMLStreamFramer()
    var frames: [XMLStreamFrame] = []
    for byte in xml.utf8 { frames += try parser.feed(Data([byte])) }
    #expect(frames.count == 2)
    guard case .element(let node) = frames.last else { Issue.record("Missing stanza"); return }
    #expect(node.namespace == "jabber:client")
    #expect(node.child("body", namespace: "jabber:client")?.text == "Hi 👋 & goodbye")
    #expect(node.child("detail", namespace: "urn:test")?.attributes["a"] == "greater > less")
}

@Test func multipleStanzasCDATACommentsAndStreamClose() throws {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data((opening + "<!-- keepalive --><presence/><message><body><![CDATA[a < b > c]]></body></message></s:stream>").utf8))
    #expect(frames.count == 4)
    guard case .element(let node) = frames[2] else { Issue.record("Missing message"); return }
    #expect(node.children.first?.text == "a < b > c")
    #expect(frames.last == .closed)
    #expect(throws: XMLStreamError.unexpectedStream) { try parser.feed(Data("<presence/>".utf8)) }
}

@Test func rejectsDoctypeAndEntityDeclarations() throws {
    for malicious in ["<!DOCTYPE message SYSTEM 'file:///etc/passwd'>", "<!DOCTYPE message [<!ENTITY x 'boom'>]>", "<!ENTITY x SYSTEM 'https://example.test'>"] {
        var parser = XMLStreamFramer()
        _ = try parser.feed(Data(opening.utf8))
        #expect(throws: XMLStreamError.forbiddenDeclaration) { try parser.feed(Data(malicious.utf8)) }
    }
}

@Test func rejectsMismatchedTagsUndefinedPrefixAndInvalidUTF8() throws {
    for malformed in [Data("<message><body>x</wrong></message>".utf8), Data("<bad:message/>".utf8), Data([60,109,101,115,115,97,103,101,62,255,60,47,109,101,115,115,97,103,101,62])] {
        var parser = XMLStreamFramer()
        _ = try parser.feed(Data(opening.utf8))
        #expect(throws: XMLStreamError.invalidXML) { try parser.feed(malformed) }
    }
}

@Test func boundsIncompleteStanzaAndDepth() throws {
    var parser = XMLStreamFramer(maximumBytes: 256)
    _ = try parser.feed(Data(opening.utf8))
    _ = try parser.feed(Data("<message>".utf8))
    #expect(throws: XMLStreamError.limitExceeded) { try parser.feed(Data(repeating: 65, count: 256)) }
    var deep = XMLStreamFramer()
    _ = try deep.feed(Data(opening.utf8))
    #expect(throws: XMLStreamError.limitExceeded) { try deep.feed(Data(String(repeating: "<a>", count: 65).utf8)) }
}

@Test func rejectsWrongStreamNamespaceAndUnframedText() throws {
    var parser = XMLStreamFramer()
    #expect(throws: XMLStreamError.unexpectedStream) { try parser.feed(Data("<stream xmlns='urn:wrong'>".utf8)) }
    var other = XMLStreamFramer()
    _ = try other.feed(Data(opening.utf8))
    #expect(throws: XMLStreamError.invalidXML) { try other.feed(Data("unexpected".utf8)) }
}

@Test func disconnectedStateRefusesSendingAndBadConfiguration() async {
    let client = XMPPClient()
    await #expect(throws: XMPPClientError.notConnected) { try await client.sendMessage(to: "a@example.test", body: "hello") }
    await #expect(throws: XMPPClientError.invalidConfiguration) { try await client.connect(host: "", domain: "example.test", username: "a", password: "b") }
    await client.disconnect()
    var iterator = client.events.makeAsyncIterator()
    #expect(await iterator.next() == .state(.disconnected(nil)))
}

/// XEP-0511's `rdf:about` may come with any prefix bound to the RDF namespace. Attributes are still keyed by qualified
/// name, as every existing reader expects, and an element without prefixed attributes compares equal to a built one.
@Test func prefixedAttributesResolveByNamespace() throws {
    let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    let node = try XMLNode.parse(standalone: Data("""
        <x xmlns='urn:test' xmlns:r='\(rdf)' xmlns:o='urn:other' r:about='by-r' about='bare' xml:lang='en'><y xmlns:q='\(rdf)' q:about='by-q' o:about='other'/></x>
        """.utf8))
    #expect(node.attributes["r:about"] == "by-r")
    #expect(node.attribute("about", namespace: rdf) == "by-r")
    #expect(node.attribute("lang", namespace: "http://www.w3.org/XML/1998/namespace") == "en")
    #expect(node.children[0].attribute("about", namespace: rdf) == "by-q")
    #expect(node.children[0].attribute("about", namespace: "urn:other") == "other")
    // An unprefixed attribute is in no namespace.
    #expect(try XMLNode.parse(standalone: Data("<x xmlns='\(rdf)' about='bare'/>".utf8)).attribute("about", namespace: rdf) == nil)
    let plain = try XMLNode.parse(standalone: Data("<x xmlns='urn:test' xml:lang='en' a='1'/>".utf8))
    #expect(plain == XMLNode(name: "x", namespace: "urn:test", attributes: ["xml:lang": "en", "a": "1"]))
}
