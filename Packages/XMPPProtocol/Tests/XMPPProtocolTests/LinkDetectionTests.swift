import Foundation
import Testing
@testable import XMPPProtocol

private func found(_ text: String) -> [(DetectedLink.Kind, String, String)] {
    LinkDetection.links(in: text).map { ($0.kind, $0.text, $0.url.absoluteString) }
}

/// Every kind the bubble draws, with what each opens: a bare domain opens as https, a written number as `tel:`.
@Test func detectsEveryLinkKindWithTheURLItOpens() {
    let text = "Read HTTPS://Example.org/A and www.example.net/b. Or http://plain.example, xmpp:room@muc.example?join, "
        + "bob@example.com, mailto:eve@example.com?subject=hi, tel:+3161234, +31 6 12345678 and geo:52.3731,4.8922;u=30."
    let links = found(text)
    let expected: [(DetectedLink.Kind, String, String)] = [
        (.web, "HTTPS://Example.org/A", "HTTPS://Example.org/A"),
        (.web, "www.example.net/b", "https://www.example.net/b"),
        (.web, "http://plain.example", "http://plain.example"),
        (.xmpp, "xmpp:room@muc.example?join", "xmpp:room@muc.example?join"),
        (.mail, "bob@example.com", "mailto:bob@example.com"),
        (.mail, "mailto:eve@example.com?subject=hi", "mailto:eve@example.com?subject=hi"),
        (.phone, "tel:+3161234", "tel:+3161234"),
        (.phone, "+31 6 12345678", "tel:+31612345678"),
        (.geo, "geo:52.3731,4.8922;u=30", "geo:52.3731,4.8922;u=30"),
    ]
    #expect(links.count == expected.count, "\(links)")
    for (link, want) in zip(links, expected) {
        #expect(link.0 == want.0 && link.1 == want.1 && link.2 == want.2, "\(link) != \(want)")
    }
}

/// Ranges count UTF-16 units, so a link after an emoji still underlines its own characters.
@Test func rangesCoverTheWrittenCharacters() throws {
    let text = "👩🏽‍💻 see example.org/x 🎉 and geo:1,2"
    for link in LinkDetection.links(in: text) {
        #expect((text as NSString).substring(with: link.range) == link.text)
    }
    #expect(LinkDetection.links(in: text).map(\.kind) == [.web, .geo])
}

/// Doc 06: key-bearing attachment links go only to the attachment decoder, never to open, copy or fetch. Other
/// schemes, credentials and out-of-range coordinates are not links either.
@Test func neverTreatsKeysCredentialsOrOtherSchemesAsLinks() {
    let key = String(repeating: "ab", count: 44), longKey = String(repeating: "cd", count: 48)
    for text in ["aesgcm://up.example/f.jpg#\(key)",
                 "https://up.example/f.jpg#\(key)",
                 "https://up.example/f.jpg#\(longKey)",
                 "https://user:secret@example.org/x",
                 "https://bank.example@evil.example/",
                 "ftp://files.example/x", "file:///etc/hosts", "javascript:alert(1)", "sms:+3161234",
                 "geo:95,4.89", "geo:52.1,190"] {
        #expect(LinkDetection.links(in: text).isEmpty, "\(text) gave \(LinkDetection.links(in: text))")
    }
    // A short fragment is an ordinary anchor.
    #expect(found("https://example.org/doc#section-2").map(\.0) == [.web])
}

/// link-previews.md, engineering default 9: one classifier for which links may carry a preview, used by the composer, the encoder and the
/// receive validator alike.
@Test func previewableURLsApplyEveryExclusion() {
    let file = "https://upload.example.org/slot/photo.jpg"
    let aesgcmFile = "aesgcm://upload.example.org/slot/legacy.jpg#" + String(repeating: "0", count: 88)
    let text = """
    > alex@example.org
    > old https://quoted.example/only
    Look https://news.example/a?b=1&c=2 and news.example/a?b=1&c=2 again https://news.example/a?b=1&c=2
    http://plain.example/x xmpp:me@example.org mail@example.org +31 6 12345678 geo:1,2
    https://upload.example.org/slot/photo.jpg https://upload.example.org/slot/legacy.jpg
    https://files.example.net/other.png https://long.example/\(String(repeating: "abcd/", count: 450))
    """
    let urls = LinkDetection.previewableURLs(in: text, fileURLs: [file, aesgcmFile], uploadHosts: ["Files.Example.NET"])
    #expect(urls.map(\.absoluteString) == ["https://news.example/a?b=1&c=2", "http://plain.example/x"])
    // Without the file and host lists only the quoted line and the overlong link stay out.
    #expect(LinkDetection.previewableURLs(in: text).count == 5)
}

/// The fetcher's scheme and port rule, and the key two fetches of one page share.
@Test func onlyDefaultPortHTTPSIsFetchedAndCacheKeysIgnoreCaseOfHostAndFragments() throws {
    let fetchable = ["https://example.org/a", "https://example.org:443/a"]
    let refused = ["http://example.org/a", "https://example.org:8443/a", "xmpp:me@example.org", "https://user@example.org/"]
    for text in fetchable { #expect(LinkDetection.isFetchable(try #require(URL(string: text))), "\(text)") }
    for text in refused { #expect(!LinkDetection.isFetchable(try #require(URL(string: text))), "\(text)") }

    let key = LinkDetection.cacheKey(for: try #require(URL(string: "HTTPS://WWW.Example.ORG:443/Path?q=A#top")))
    #expect(key == "https://www.example.org/Path?q=A")
    #expect(LinkDetection.displayHost(for: try #require(URL(string: "https://WWW.Example.org/x"))) == "example.org")
    // International names stay in the ASCII form the detector gives them, so a mixed-script look-alike is visible.
    let lookalike = try #require(LinkDetection.links(in: "https://\u{0430}pple.com/").first)
    #expect(LinkDetection.displayHost(for: lookalike.url) == "xn--pple-43d.com")
}
