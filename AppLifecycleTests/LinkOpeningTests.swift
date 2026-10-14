import XCTest
import XMPPProtocol
@testable import HausXMPP

/// Where a link in a message goes when it is opened. The iPhone and the Mac perform the same destinations; only the
/// iPhone has an in-app browser.
final class LinkOpeningTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testEachKindOfLinkGoesWhereItsSchemeSays() {
        let cases: [(link: String, inApp: Bool, destination: LinkDestination, line: UInt)] = [
            ("https://example.org/a?b=c", true, .web(url("https://example.org/a?b=c"), inApp: true), #line),
            ("https://example.org/a?b=c", false, .web(url("https://example.org/a?b=c"), inApp: false), #line),
            // http opens as written; it is never fetched, which is the fetcher's rule, not this one's.
            ("http://example.org/", true, .web(url("http://example.org/"), inApp: true), #line),
            ("tel:+31612345678", true, .phone(number: "+31612345678", call: url("tel:+31612345678"), message: url("sms:+31612345678")), #line),
            ("mailto:bob@example.org?subject=Hi", true, .mail(url("mailto:bob@example.org?subject=Hi"), address: "bob@example.org"), #line),
            // XEP-0147: a person's address opens their chat, in normal form and without a resource; ?join is a group.
            ("xmpp:Romeo@montague.lit?message;body=hi", true, .chat("romeo@montague.lit"), #line),
            ("xmpp:romeo@montague.lit/balcony", true, .chat("romeo@montague.lit"), #line),
            ("xmpp:room@conference.example.org?join", true, .group("room@conference.example.org"), #line),
            ("xmpp://guest@example.org/romeo@montague.lit", true, .chat("romeo@montague.lit"), #line),
            // A bare server is no one to chat with.
            ("xmpp:montague.lit", true, .unsupported, #line),
            ("geo:37.786971,-122.399677;u=35", true,
             .map(url("https://maps.apple.com/?ll=37.786971,-122.399677&q=37.786971,-122.399677")), #line),
            ("geo:91,0", true, .unsupported, #line),
            ("ftp://example.org/file", true, .unsupported, #line),
        ]
        for item in cases {
            XCTAssertEqual(LinkOpening.destination(for: url(item.link), inAppBrowser: item.inApp), item.destination, item.link, line: item.line)
        }
    }

    /// The detector's URLs for what people write open the same way: a bare domain as https, a written phone number as a
    /// number to call, a bare address as mail.
    func testWrittenLinksOpenAsTheirKind() throws {
        let links = LinkDetection.links(in: "See example.org/a, call +31 6 12345678 or mail bob@example.org")
        XCTAssertEqual(links.map(\.kind), [.web, .phone, .mail])
        let destinations = links.map { LinkOpening.destination(for: $0.url, inAppBrowser: true) }
        XCTAssertEqual(destinations[0], .web(url("https://example.org/a"), inApp: true))
        XCTAssertEqual(destinations[1], .phone(number: "+31612345678", call: url("tel:+31612345678"), message: url("sms:+31612345678")))
        XCTAssertEqual(destinations[2], .mail(url("mailto:bob@example.org"), address: "bob@example.org"))
    }

    /// Copy puts what a person would paste elsewhere: the number or address alone, the link itself otherwise.
    func testCopyTakesTheNumberOrAddressRatherThanTheScheme() {
        XCTAssertEqual(LinkOpening.copyText(for: url("tel:+31612345678")), "+31612345678")
        XCTAssertEqual(LinkOpening.copyText(for: url("mailto:bob@example.org?subject=Hi")), "bob@example.org")
        XCTAssertEqual(LinkOpening.copyText(for: url("xmpp:room@conference.example.org?join")), "room@conference.example.org")
        XCTAssertEqual(LinkOpening.copyText(for: url("https://example.org/a#top")), "https://example.org/a#top")
        XCTAssertEqual(LinkOpening.copyText(for: url("geo:37.78,-122.39")), "geo:37.78,-122.39")
    }
}
