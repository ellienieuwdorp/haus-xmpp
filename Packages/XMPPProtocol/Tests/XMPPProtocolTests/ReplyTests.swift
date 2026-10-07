import Foundation
import Testing
@testable import XMPPProtocol

private func replyNode(body: String = "Answer", reply: XMPPReply?) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let xml = try XMPPClient.messageXML(to: "bob@example.test", body: body, id: "durable-original", reply: reply)
    let frames = try parser.feed(Data(("<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPClientError.unexpectedProtocol }
    return node
}

@Test func replyPreservesIDsEscapingAndNamespace() throws {
    let targetID = "original-'&<>"
    let node = try replyNode(body: "Yes & <ok>", reply: XMPPReply(id: targetID, to: "b&b@example.test/device", body: "A & <B>\nC"))
    #expect(node.attributes["id"] == "durable-original")
    #expect(node.child("origin-id", namespace: "urn:xmpp:sid:0")?.attributes["id"] == "durable-original")
    let metadata = try #require(node.child("reply", namespace: "urn:xmpp:reply:0"))
    #expect(metadata.attributes["id"] == targetID)
    #expect(metadata.attributes["to"] == "b&b@example.test/device")
    #expect(node.child("body", namespace: "jabber:client")?.text == "> A & <B>\n> C\nYes & <ok>")
    #expect(node.child("fallback", namespace: "urn:xmpp:fallback:0")?.attributes["for"] == "urn:xmpp:reply:0")
}

@Test func replyFallbackCountsUnicodeScalarsAfterXMLNewlineNormalization() throws {
    let node = try replyNode(reply: XMPPReply(id: "known", to: "bob@example.test", body: "👩🏽‍💻 e\u{301}\r\n<&>\rLast"))
    let body = try #require(node.child("body", namespace: "jabber:client")?.text)
    let range = try #require(node.child("fallback", namespace: "urn:xmpp:fallback:0")?.child("body", namespace: "urn:xmpp:fallback:0"))
    let end = try #require(Int(range.attributes["end"] ?? ""))
    #expect(range.attributes["start"] == "0")
    #expect(String(String.UnicodeScalarView(body.unicodeScalars.dropFirst(end))) == "Answer")
    let prefix = String(String.UnicodeScalarView(body.unicodeScalars.prefix(end)))
    #expect(prefix == "> 👩🏽‍💻 e\u{301}\n> <&>\n> Last\n")
    #expect(end == prefix.unicodeScalars.count)
    #expect(end != prefix.count)
    #expect(end != prefix.utf16.count)
}

@Test func messageProblemNamesThePartThatCannotBeSent() {
    func problem(_ body: String, quote: String?) -> XMPPClient.MessageProblem? {
        XMPPClient.messageProblem(to: "bob@example.test", body: body, id: "m1", reply: quote.map { XMPPReply(id: "w1", to: "bob@example.test", body: $0) })
    }
    #expect(problem("Answer", quote: "Photo") == nil)
    #expect(problem("Answer", quote: "") == .emptyQuote)
    #expect(problem("Answer", quote: String(repeating: "a", count: 16_385)) == .quoteTooLong)
    #expect(problem("Answer", quote: "bad\u{0001}") == .quoteUnsupportedCharacters)
    #expect(problem("", quote: nil) == .emptyBody)
    #expect(problem("bad\u{fffe}", quote: nil) == .bodyUnsupportedCharacters)
    #expect(problem(String(repeating: "a", count: 65_537), quote: nil) == .bodyTooLong)
    #expect(problem(String(repeating: "a", count: 60_000), quote: String(repeating: "q", count: 16_000)) == .combinedTooLong)
    #expect(XMPPClient.messageProblem(to: "bob@example.test", body: "Answer", id: "has space") == .invalidAddressing)
    #expect(throws: (any Error).self) { try XMPPClient.validateMessage(to: "bob@example.test", body: "Answer", id: "m1", reply: XMPPReply(id: "w1", to: "bob@example.test", body: "")) }
}
