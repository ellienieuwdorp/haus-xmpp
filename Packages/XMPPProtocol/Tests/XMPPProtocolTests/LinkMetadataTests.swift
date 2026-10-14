import Foundation
import Testing
@testable import XMPPProtocol

/// Card text is plain text: a sender or a page cannot reorder the host line with bidi controls, hide characters, or
/// break the card's line limits with newlines.
@Test func cardTextDropsControlsAndBidiAndCollapsesWhitespace() {
    let cases: [(String, String?)] = [
        ("  Council\n\napproves\tthe\u{2028}bridge  ", "Council approves the bridge"),
        ("evil\u{202E}gpj.exe\u{2066}x\u{2069}", "evilgpj.exex"),
        ("bell\u{07}\u{1B}[31m red\u{85}line", "bell[31m red line"),
        ("\u{200F}\u{200E}\n \u{0}", nil),
        ("Ünïcødé — 日本語 👍🏽", "Ünïcødé — 日本語 👍🏽"),
    ]
    for (input, expected) in cases {
        #expect(MessageContent.LinkMetadata.plainText(input) == expected, "\(input.debugDescription)")
    }
}

// MARK: XEP-0511 codec

private typealias LinkMetadata = MessageContent.LinkMetadata
private let rdf = LinkMetadata.rdfNamespace, og = LinkMetadata.openGraphNamespace, ogi = LinkMetadata.openGraphImageNamespace
private let link = "https://example.org/news/42?ref=a&b=c"
private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

/// Decodes `<content/>` children the way the SCE layer does: strictly, as authenticated content.
private func content(_ children: String, body: String = "Read this \(xmlEscaped(link))", strict: Bool = true,
                     languages: [String] = ["en-US"]) throws -> MessageContent {
    let node = try XMLNode.parse(standalone: Data("<content xmlns='urn:xmpp:sce:1'><body xmlns='jabber:client'>\(body)</body>\(children)</content>".utf8))
    var decoded = try MessageContent.decode(node, strict: strict)
    if strict { decoded.linkMetadata = LinkMetadata.decode(in: node, body: decoded.body, preferredLanguages: languages) }
    return decoded
}
private func description(about: String = xmlEscaped(link), _ children: String = "<title xmlns='\(og)'>Bridge</title>") -> String {
    "<Description xmlns='\(rdf)' xmlns:rdf='\(rdf)' rdf:about='\(about)'>\(children)</Description>"
}

/// What we send is what a receiver reads back, inside the reply form, in a fixed order: body, reply and its fallback,
/// at most one Description, origin ID.
@Test func sentMetadataRoundTripsInsideContentAfterTheReply() throws {
    let sent = MessageContent(body: "Look \(link) now", reply: .init(id: "w1", to: "bob@example.org", quote: "> bob\n> https://quoted.example/x\n\n"),
                              originID: "o1", linkMetadata: [LinkMetadata(about: link, title: " Council\napproves ", description: "Spring.",
                                                                          image: .data(type: "image/jpeg", bytes: png), imageAlt: "Dusk")])
    let xml = try sent.xml()
    let order = ["<body", "<reply", "<fallback", "<Description", "<origin-id"].map { xml.range(of: $0)?.lowerBound }
    #expect(order.allSatisfy { $0 != nil } && order.map { $0! } == order.map { $0! }.sorted(), "\(xml)")
    let node = try XMLNode.parse(standalone: Data("<content xmlns='urn:xmpp:sce:1'>\(xml)</content>".utf8))
    let received = try MessageContent.decode(node, strict: true)
    #expect(received.linkMetadata == [LinkMetadata(about: link, title: "Council approves", description: "Spring.",
                                                   image: .data(type: "image/jpeg", bytes: png), imageAlt: "Dusk")])
}

/// The deployed form, the XEP's prefixed example and any other RDF prefix are one and the same Description.
@Test func everyPrefixFormDecodesAlike() throws {
    let image = "data:image/png;base64,\(png.base64EncodedString())"
    let forms = [
        description("<title xmlns='\(og)'>Bridge</title><image xmlns='\(og)'>\(image)</image><alt xmlns='\(ogi)'>Dusk</alt>"),
        "<rdf:Description xmlns:rdf='\(rdf)' xmlns:og='\(og)' xmlns:ogi='\(ogi)' rdf:about='\(xmlEscaped(link))'><og:title>Bridge</og:title><og:image>\(image)</og:image><ogi:alt>Dusk</ogi:alt></rdf:Description>",
        "<r:Description xmlns:r='\(rdf)' r:about='\(xmlEscaped(link))'><title xmlns='\(og)'>Bridge</title><image xmlns='\(og)'>\n\(image.prefix(30))\n\(image.dropFirst(30))\n</image><alt xmlns='\(ogi)'>Dusk</alt></r:Description>",
    ]
    for form in forms {
        #expect(try content(form).linkMetadata == [LinkMetadata(about: link, title: "Bridge", image: .data(type: "image/png", bytes: png), imageAlt: "Dusk")], "\(form)")
    }
}

/// Receive rules: a broken Description drops every Description of the message, never the text.
@Test func brokenMetadataDropsAllOfItAndKeepsTheMessage() throws {
    let good = description()
    let other = "https://other.example/a"
    let oversizeImage = Data(repeating: 7, count: LinkMetadata.maximumImageBytes + 1).base64EncodedString()
    let cases: [(String, String)] = [
        ("more than four", String(repeating: good, count: 5)),
        ("about not in the body", good + description(about: other)),
        ("about only bare", good + "<Description xmlns='\(rdf)' about='\(xmlEscaped(link))'><title xmlns='\(og)'>x</title></Description>"),
        ("bare about differs", "<Description xmlns='\(rdf)' xmlns:rdf='\(rdf)' rdf:about='\(xmlEscaped(link))' about='\(other)'><title xmlns='\(og)'>x</title></Description>"),
        ("same about twice", good + good),
        ("title over the cap", description("<title xmlns='\(og)'>\(String(repeating: "é", count: 513))</title>")),
        ("title not a leaf", description("<title xmlns='\(og)'>a<b xmlns='urn:x'/></title>")),
        ("two titles", description("<title xmlns='\(og)'>a</title><title xmlns='\(og)'>b</title>")),
        ("broken base64", description("<title xmlns='\(og)'>a</title><image xmlns='\(og)'>data:image/png;base64,***</image>")),
        ("image over the cap", description("<image xmlns='\(og)'>data:image/jpeg;base64,\(oversizeImage)</image>")),
        ("too many children", description(String(repeating: "<url xmlns='\(og)'>x</url>", count: 17))),
    ]
    for (name, children) in cases {
        let decoded = try content(children)
        #expect(decoded.linkMetadata.isEmpty, "\(name)")
        #expect(decoded.body == "Read this \(link)", "\(name)")
    }
    // A link only on a quoted line is not previewable, so a Description about it is broken too.
    #expect(try content(good, body: "&gt; \(xmlEscaped(link))\nmine").linkMetadata.isEmpty)
}

/// What is merely unsupported is ignored without dropping its neighbours: remote, `cid:` and other-type images, other
/// properties, and Descriptions with nothing to show.
@Test func unsupportedPartsAreIgnored() throws {
    let second = "https://second.example/b"
    let decoded = try content(description(about: second, "<title xmlns='\(og)'>Two</title><image xmlns='\(og)'>https://cdn.example/x.jpg</image><url xmlns='\(og)'>https://evil.example/</url>")
                              + description("<image xmlns='\(og)'>cid:sha1+abc@bob.xmpp.org</image><site_name xmlns='\(og)'>Spoof</site_name>")
                              + description(about: "https://third.example/c", "<image xmlns='\(og)'>data:image/svg+xml;base64,PHN2Zz4=</image>"),
                              body: "\(xmlEscaped(link)) and \(second) and https://third.example/c")
    #expect(decoded.linkMetadata == [LinkMetadata(about: second, title: "Two")])
}

/// Several languages for one link: the reader's language, else the first given.
@Test func prefersTheReadersLanguage() throws {
    let both = description("<title xmlns='\(og)'>Brug</title>").replacingOccurrences(of: "rdf:about", with: "xml:lang='nl' rdf:about")
        + description("<title xmlns='\(og)'>Bridge</title>").replacingOccurrences(of: "rdf:about", with: "xml:lang='en' rdf:about")
    #expect(try content(both, languages: ["en-GB", "nl"]).linkMetadata.map(\.title) == ["Bridge"])
    #expect(try content(both, languages: ["nl-NL"]).linkMetadata.map(\.title) == ["Brug"])
    #expect(try content(both, languages: ["de"]).linkMetadata.map(\.title) == ["Brug"])
}

/// Only text messages carry metadata, and the encoder writes only what a receiver would keep.
@Test func encoderWritesOnlyValidMetadataOnTextMessages() throws {
    let preview = LinkMetadata(about: link, title: "Bridge")
    for message in [MessageContent(body: "No link here", linkMetadata: [preview]),
                    MessageContent(body: "> \(link)\nquoted only", linkMetadata: [preview]),
                    MessageContent(body: "Read \(link)", linkMetadata: [LinkMetadata(about: link)]),
                    MessageContent(body: "Read \(link)", linkMetadata: [LinkMetadata(about: link, image: .data(type: "image/svg+xml", bytes: png))]),
                    MessageContent(body: "Read \(link)", linkMetadata: [preview, preview]),
                    MessageContent(body: "", reaction: .init(targetID: "t", reactions: ["👍"]), linkMetadata: [preview])] {
        #expect(message.sendableLinkMetadata.isEmpty)
        #expect(try !message.xml().contains("Description"))
    }
    #expect(try MessageContent(body: "Read \(link)", linkMetadata: [preview]).xml().contains("rdf:about='\(xmlEscaped(link))'"))
}

/// We send within our own bounds, which are tighter than what we accept: a 24 KiB thumbnail, a title of 200 characters
/// and 512 bytes, a description of 300 characters and 1,024 bytes, an alt of 200 characters. One field over its bound
/// sends no metadata; every field at its bound sends.
@Test func encoderKeepsToTheSendBounds() throws {
    let jpeg = { (count: Int) in MessageContent.LinkMetadata.Image.data(type: "image/jpeg", bytes: Data(repeating: 0xFF, count: count)) }
    let wide = String(repeating: "日", count: 171) // 171 characters, 513 bytes
    let over = [
        LinkMetadata(about: link, title: "Bridge", image: jpeg(LinkMetadata.maximumSentImageBytes + 1)),
        LinkMetadata(about: link, title: String(repeating: "a", count: 201)),
        LinkMetadata(about: link, title: wide),
        LinkMetadata(about: link, title: "Bridge", description: String(repeating: "a", count: 301)),
        LinkMetadata(about: link, title: "Bridge", description: String(repeating: "😀", count: 257)), // 1,028 bytes
        LinkMetadata(about: link, title: "Bridge", image: jpeg(16), imageAlt: String(repeating: "a", count: 201)),
    ]
    for metadata in over {
        #expect(MessageContent(body: "Read \(link)", linkMetadata: [metadata]).sendableLinkMetadata.isEmpty, "\(metadata)")
    }
    let atBounds = LinkMetadata(about: link, title: String(repeating: "a", count: 200), description: String(repeating: "é", count: 300),
                                image: jpeg(LinkMetadata.maximumSentImageBytes), imageAlt: String(repeating: "日", count: 170))
    #expect(MessageContent(body: "Read \(link)", linkMetadata: [atBounds]).sendableLinkMetadata == [atBounds])
}
