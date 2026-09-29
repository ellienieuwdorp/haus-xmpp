import Foundation
import MessageStore
import XCTest
@testable import OMEMO

final class EncryptedContentTests: XCTestCase {
    private let sender = "alice@localhost"
    private let recipient = "bob@localhost"

    private func decode(_ xml: String) throws -> EncryptedContent {
        try EncryptedContent.decode(Data(xml.utf8), sender: sender, recipient: recipient, modern: true)
    }
    private func envelope(_ content: String = "<body xmlns='jabber:client'>Hello</body>", affixes: String = "<from jid='alice@localhost'/><to jid='bob@localhost'/>") -> String {
        "<envelope xmlns='urn:xmpp:sce:1'><content>\(content)</content><rpad>random fixture padding</rpad>\(affixes)</envelope>"
    }
    private func assertRejected(_ xml: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(xml), file: file, line: line)
    }

    func testUnicodeXMLCharactersAndRandomPaddingRoundTrip() throws {
        let body = "👩🏽‍💻 café & <tag> 'quoted' \"double\"\nSecond line"
        let first = try EncryptedContent.encode(body: body, reply: nil, sender: sender, recipient: recipient, modern: true)
        let second = try EncryptedContent.encode(body: body, reply: nil, sender: sender, recipient: recipient, modern: true)
        XCTAssertNotEqual(first, second, "Each envelope must receive new random padding")
        XCTAssertEqual(try EncryptedContent.decode(first, sender: sender, recipient: recipient, modern: true).body, body)
    }

    func testAuthenticatedAffixesMustMatchDirectChatAndMayContainResource() throws {
        assertRejected(envelope(affixes: "<from jid='mallory@localhost'/><to jid='bob@localhost'/>"))
        assertRejected(envelope(affixes: "<from jid='alice@localhost'/><to jid='mallory@localhost'/>"))
        assertRejected(envelope(affixes: "<from/><to jid='bob@localhost'/>"))
        assertRejected(envelope(affixes: "<from jid='alice@localhost'/><to/>"))
        XCTAssertEqual(try decode(envelope(affixes: "<from jid='alice@localhost/laptop'/><to jid='bob@localhost/phone'/>" )).body, "Hello")
        // Another client may spell the addresses as its user typed them; they name the same accounts.
        XCTAssertEqual(try decode(envelope(affixes: "<from jid='Alice@LocalHost/laptop'/><to jid='BOB@localhost'/>")).body, "Hello")
        XCTAssertEqual(try decode(envelope(affixes: "")).body, "Hello", "Direct-message profile permits missing from/to affixes")
    }

    func testRejectsAmbiguousStructureAndWrongNamespaces() {
        assertRejected(envelope(affixes: "<from jid='alice@localhost'/><from jid='alice@localhost'/>"))
        assertRejected(envelope(affixes: "<to jid='bob@localhost'/><to jid='bob@localhost'/>"))
        assertRejected(envelope().replacingOccurrences(of: "<rpad>", with: "<rpad xmlns='urn:evil'>"))
        assertRejected(envelope().replacingOccurrences(of: "<content>", with: "<content xmlns='urn:evil'>"))
        assertRejected(envelope().replacingOccurrences(of: "urn:xmpp:sce:1", with: "urn:xmpp:sce:0"))
        assertRejected(envelope("<body xmlns='urn:evil'>Hello</body>"))
        assertRejected(envelope("<body xmlns='jabber:client'>First</body><body xmlns='jabber:client'>Second</body>"))
        assertRejected(envelope("<body xmlns='jabber:client'><nested>Hidden</nested></body>"))
        assertRejected(envelope("<body xmlns='jabber:client'/>"))
        assertRejected(envelope().replacingOccurrences(of: "</envelope>", with: "<content/></envelope>"))
        assertRejected(envelope().replacingOccurrences(of: "</envelope>", with: "<rpad>second</rpad></envelope>"))
    }

    func testEntityDocumentAndResourceDeclarationsAreRejected() {
        assertRejected("<!DOCTYPE envelope [<!ENTITY e SYSTEM 'file:///etc/passwd'>]>" + envelope("<body xmlns='jabber:client'>&e;</body>"))
        assertRejected("<?xml version='1.0'?>" + envelope())
        assertRejected(envelope("<body xmlns='jabber:client'><![CDATA[Hello]]></body>"))
        assertRejected(envelope() + envelope())
        assertRejected(envelope(String(repeating: "<nested>", count: 18) + "value" + String(repeating: "</nested>", count: 18)))
        XCTAssertThrowsError(try EncryptedContent.decode(Data([0xff, 0xfe]), sender: sender, recipient: recipient, modern: true))
        XCTAssertThrowsError(try EncryptedContent.decode(Data(repeating: 0x61, count: 131_073), sender: sender, recipient: recipient, modern: true))
    }

    func testUnactionedExtensionsNeverOverrideAuthenticatedBody() throws {
        let content = "<body xmlns='jabber:client'>Real body</body><body xmlns='urn:evil'>Fake body</body><message xmlns='jabber:client' from='mallory@localhost'><body>Injected</body></message><reactions xmlns='urn:xmpp:reactions:0' id='target'><reaction>❤️</reaction></reactions>"
        let result = try decode(envelope(content))
        XCTAssertEqual(result.body, "Real body")
        XCTAssertNil(result.reply)
    }

    func testStructuredReplyUsesUnicodeScalarOffsetsAndKeepsQuoteInsideEnvelope() throws {
        let reply = MessageReply(messageID: "local-id", senderID: "bob@localhost", body: "👩🏽‍💻 source\r\nline & <two>", wireID: "wire-id")
        let data = try EncryptedContent.encode(body: "My answer", reply: reply, sender: sender, recipient: recipient, modern: true)
        let result = try EncryptedContent.decode(data, sender: sender, recipient: recipient, modern: true)
        XCTAssertEqual(result.body, "My answer")
        XCTAssertEqual(result.reply?.wireID, "wire-id")
        XCTAssertEqual(result.reply?.senderID, recipient)
        XCTAssertEqual(result.reply?.body, "👩🏽‍💻 source\nline & <two>")
    }

    func testMalformedReplyFallbackDoesNotDiscardMessageText() throws {
        let body = "<body xmlns='jabber:client'>Quote and answer</body>"
        let reference = "<reply xmlns='urn:xmpp:reply:0' id='target' to='bob@localhost'/>"
        for range in ["start='0' end='-1'", "start='1' end='4'", "start='0' end='999999999999999999999'", "start='0' end='16'", "start='0' end='0'"] {
            let fallback = "<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body \(range)/></fallback>"
            let result = try decode(envelope(body + reference + fallback))
            XCTAssertEqual(result.body, "Quote and answer")
            XCTAssertNil(result.reply)
        }
        let result = try decode(envelope(body + reference + reference))
        XCTAssertEqual(result.body, "Quote and answer")
        XCTAssertNil(result.reply)
    }

    func testLegacyBodyCannotBecomeExecutableXMLOrStructuredReply() throws {
        let text = "<body xmlns='jabber:client'>Literal text</body>"
        let result = try EncryptedContent.decode(Data(text.utf8), sender: sender, recipient: recipient, modern: false)
        XCTAssertEqual(result.body, text)
        XCTAssertNil(result.reply)
        let reply = MessageReply(messageID: "source", senderID: recipient, body: "A quote", wireID: "wire")
        let encoded = try EncryptedContent.encode(body: "Answer", reply: reply, sender: sender, recipient: recipient, modern: false)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "> bob@localhost\n> A quote\n\nAnswer")
        XCTAssertThrowsError(try EncryptedContent.encode(body: "", reply: nil, sender: sender, recipient: recipient, modern: true))
        XCTAssertThrowsError(try EncryptedContent.encode(body: String(repeating: "🦊", count: 4097), reply: nil, sender: sender, recipient: recipient, modern: false))
    }
    func testEncoderRejectsInvalidXMLAndUnboundedReplyMetadata() throws {
        for text in ["nul\u{0000}", "control\u{0001}", "noncharacter\u{fffe}"] {
            XCTAssertThrowsError(try EncryptedContent.encode(body: text, reply: nil, sender: sender, recipient: recipient, modern: true))
        }
        for address in ["", "a\nb@localhost", String(repeating: "a", count: 3072)] {
            XCTAssertThrowsError(try EncryptedContent.encode(body: "hello", reply: nil, sender: address, recipient: recipient, modern: true))
        }
        let bad = MessageReply(messageID: "source", senderID: recipient, body: String(repeating: "a", count: 16_385), wireID: "wire")
        XCTAssertThrowsError(try EncryptedContent.encode(body: "hello", reply: bad, sender: sender, recipient: recipient, modern: true))
    }

    func testForeignReplyQuotationRemainsVerbatim() throws {
        let quote = "Alice said: hello\n"
        let body = "<body xmlns='jabber:client'>\(quote)Answer</body>"
        let reference = "<reply xmlns='urn:xmpp:reply:0' id='wire' to='alice@localhost'/>"
        let fallback = "<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='\(quote.unicodeScalars.count)'/></fallback>"
        let result = try decode(envelope(body + reference + fallback))
        XCTAssertEqual(result.body, "Answer")
        XCTAssertEqual(result.reply?.body, quote)
    }

    /// Duplicate-emoji folding and the two-container case are pinned against the plain path in ContentCodecParityTests.
    func testReactionParserRejectsMalformedContainersAndEncoderRejectsNonEmoji() throws {
        assertRejected(envelope("<reactions xmlns='urn:xmpp:reactions:0'/>"))
        assertRejected(envelope("<reactions xmlns='urn:xmpp:reactions:0' id=''><reaction>👍</reaction></reactions>"))
        assertRejected(envelope("<reactions xmlns='urn:xmpp:reactions:0' id='target'><reaction><nested>👍</nested></reaction></reactions>"))
        assertRejected(envelope("<reactions xmlns='urn:evil' id='target'><reaction>👍</reaction></reactions>"))
        for invalid in [["1"], ["plain"], ["👍👍"], [String(repeating: "👍", count: 17)]] {
            XCTAssertThrowsError(try EncryptedContent.encodeReaction(targetWireID: "target", reactions: invalid,
                                                                      sender: sender, recipient: recipient, originID: "id", modern: true))
        }
    }

    func testAuthenticatedOriginCannotBeOverriddenByNestedOrDuplicateIDs() throws {
        let xml = envelope("<body xmlns='jabber:client'>Bound message</body><origin-id xmlns='urn:xmpp:sid:0' id='real'/><container xmlns='urn:evil'><origin-id xmlns='urn:xmpp:sid:0' id='fake'/></container>")
        XCTAssertEqual(try decode(xml).originID, "real")
        assertRejected(envelope("<body xmlns='jabber:client'>Body</body><origin-id xmlns='urn:xmpp:sid:0' id='first'/><origin-id xmlns='urn:xmpp:sid:0' id='second'/>"))
        XCTAssertNil(try decode(envelope("<body xmlns='jabber:client'>Body</body><origin-id xmlns='urn:evil' id='fake'/>" )).originID)
    }

    func testAuthenticatedTimeMustMatchArchiveOrLiveContext() throws {
        let content = "<reactions xmlns='urn:xmpp:reactions:0' id='target'><reaction>👍</reaction></reactions>"
        let xml = envelope(content, affixes: "<from jid='alice@localhost'/><to jid='bob@localhost'/><time stamp='2023-11-14T22:13:20Z'/>")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = try EncryptedContent.decode(Data(xml.utf8), sender: sender, recipient: recipient, modern: true, sendingTime: stamp)
        XCTAssertEqual(valid.timestamp, stamp)
        XCTAssertThrowsError(try EncryptedContent.decode(Data(xml.utf8), sender: sender, recipient: recipient, modern: true, sendingTime: stamp.addingTimeInterval(301)))
        assertRejected(envelope(content, affixes: "<time stamp='not-a-time'/>"))
        assertRejected(envelope(content, affixes: "<time stamp='2023-11-14T22:13:20Z'/><time stamp='2023-11-14T22:13:20Z'/>"))
    }

}
