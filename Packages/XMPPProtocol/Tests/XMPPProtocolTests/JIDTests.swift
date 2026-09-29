import Foundation
import Testing
@testable import XMPPProtocol

/// RFC 7622 normal forms, with the spellings Prosody 13 (`util.jid.prep`) produced for the same inputs where they agree.
@Test func addressesNormaliseToOneSpelling() {
    let cases: [(String, String)] = [
        ("Ellie@LocalHost", "ellie@localhost"),
        ("Ellie@Example.ORG./Res", "ellie@example.org/Res"),       // resource keeps its case; one trailing dot goes
        ("ＡＢＣ@x.example", "abc@x.example"),                      // fullwidth is width-mapped
        ("ｶ@x.example", "カ@x.example"),                           // halfwidth katakana maps to its full form
        ("A\u{030A}ngstro\u{0308}m@x.example", "ångström@x.example"), // NFC after lowercasing
        ("Σ@x.example", "σ@x.example"),
        ("Rooms.Example.org", "rooms.example.org"),                 // a domain JID
        ("bob@x.example/a/b@c", "bob@x.example/a/b@c"),             // the first slash starts the resource
        ("[::1]", "[::1]"),
    ]
    for (input, expected) in cases { #expect(JID.normalized(input) == expected, "\(input)") }
    #expect(JID.normalizedBare("Bob@Example.org/phone") == "bob@example.org")
    #expect(JID.normalizedBare("example.org") == nil)
}

@Test func invalidAddressesAreRejected() {
    let long = String(repeating: "a", count: 1024)
    for input in ["", "@x.example", "bob@", "bob@x.example/", "a b@x.example", "bo'b@x.example", "b:ob@x.example",
                  "a<b@x.example", "a@b@x.example", "bob@x..example", "bob@.x.example", "bob@x ex", "zero\u{200B}width@x.example",
                  "ctl\u{0007}@x.example", "bob@x.example/res\u{0000}", long + "@x.example", "bob@" + long, "bob@[zz]"] {
        #expect(JID(input) == nil, "\(input.debugDescription)")
    }
}

@Test func forwardedAddressesAreNormalisedButOtherAttributesAreNot() throws {
    var parser = XMLStreamFramer()
    let xml = "<message from='Me@Example.Test' to='Me@Example.Test/Phone'><sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>"
        + "<message xmlns='jabber:client' from='Me@Example.Test/Laptop' to='Bob@Example.Test' id='X'><reply xmlns='urn:xmpp:reply:0' to='Bob@Example.Test' id='Y'/></message>"
        + "</forwarded></sent></message>"
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { Issue.record("no stanza"); return }
    let normal = JID.normalizingAddresses(node)
    #expect(normal.attributes["from"] == "me@example.test" && normal.attributes["to"] == "me@example.test/Phone")
    let (inner, provenance) = try Carbons.unwrap(normal, accountBareJID: "me@example.test", accountFullJID: "me@example.test/Phone")
    #expect(provenance == .sentCarbon)
    #expect(inner.attributes["from"] == "me@example.test/Laptop" && inner.attributes["to"] == "bob@example.test" && inner.attributes["id"] == "X")
    // Only stanza addresses: an extension's attribute keeps its spelling for its own parser.
    #expect(inner.children.first?.attributes["to"] == "Bob@Example.Test")
}
