import Foundation
import Testing
@testable import XMPPProtocol

private func stanza(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return JID.normalizingAddresses(node)
}
private let account = "me@example.test"

@Test func blocklistResultParsesItemsInNormalFormAndSkipsInvalidOnes() throws {
    // XEP-0191 Example 2, plus a domain, a full JID and an address that is not a JID.
    let result = try stanza("""
        <iq type='result' id='blocklist1'><blocklist xmlns='urn:xmpp:blocking'>\
        <item jid='romeo@montague.net'/><item jid='Iago@Shakespeare.lit'/>\
        <item jid='spam.example'/><item jid='nurse@capulet.example/balcony'/>\
        <item jid='bad address@example.test'/><item/>\
        </blocklist></iq>
        """)
    #expect(try BlockingWire.blocklistResult(result)
            == ["romeo@montague.net", "iago@shakespeare.lit", "spam.example", "nurse@capulet.example/balcony"])
    // Example 3: an empty list.
    #expect(try BlockingWire.blocklistResult(try stanza("<iq type='result' id='b2'><blocklist xmlns='urn:xmpp:blocking'/></iq>")) == [])
    for xml in ["<iq type='result' id='b3'/>",
                "<iq type='result' id='b4'><blocklist xmlns='urn:xmpp:blocking'/><blocklist xmlns='urn:xmpp:blocking'/></iq>",
                "<iq type='result' id='b5'><blocklist xmlns='urn:xmpp:other'/></iq>"] {
        #expect(throws: XMPPIQError.self, "\(xml)") { try BlockingWire.blocklistResult(try stanza(xml)) }
    }
}

@Test func blockRequestsCarryOneItemAndAnOptionalReport() throws {
    // XEP-0191 Example 4.
    #expect(try BlockingWire.blockXML("Romeo@Montague.net", report: nil)
            == "<block xmlns='urn:xmpp:blocking'><item jid='romeo@montague.net'/></block>")
    // XEP-0377 Example 5: the report on the item.
    #expect(try BlockingWire.blockXML("romeo@example.net", report: XMPPBlockReport(reason: .abuse))
            == "<block xmlns='urn:xmpp:blocking'><item jid='romeo@example.net'><report xmlns='urn:xmpp:reporting:1' reason='urn:xmpp:reporting:abuse'/></item></block>")
    // Example 6: copies of the reported messages' stanza IDs inside the report.
    let report = XMPPBlockReport(reason: .spam, messages: [XMPPStanzaReference(id: "28482-98726-73623", by: "juliet@example.com"),
                                                           XMPPStanzaReference(id: "a'b", by: "juliet@example.com")])
    #expect(try BlockingWire.blockXML("romeo@example.net", report: report)
            == "<block xmlns='urn:xmpp:blocking'><item jid='romeo@example.net'><report xmlns='urn:xmpp:reporting:1' reason='urn:xmpp:reporting:spam'>"
            + "<stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='28482-98726-73623'/>"
            + "<stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='a&apos;b'/></report></item></block>")
    let many = XMPPBlockReport(reason: .spam, messages: (0..<50).map { XMPPStanzaReference(id: "id\($0)", by: account) })
    #expect(try BlockingWire.blockXML("romeo@example.net", report: many).components(separatedBy: "<stanza-id ").count - 1 == BlockingWire.maximumReportedMessages)
    for (address, report) in [("bad address@example.test", nil), ("", nil),
                              ("romeo@example.net", XMPPBlockReport(reason: .spam, messages: [XMPPStanzaReference(id: "", by: account)])),
                              ("romeo@example.net", XMPPBlockReport(reason: .spam, messages: [XMPPStanzaReference(id: "x", by: "not a jid@x")]))] as [(String, XMPPBlockReport?)] {
        #expect(throws: XMPPClientError.self, "\(address)") { try BlockingWire.blockXML(address, report: report) }
    }
}

@Test func unblockNamesItsItemsAndNeverMeansEverything() throws {
    // XEP-0191 Example 7.
    #expect(try BlockingWire.unblockXML(["romeo@montague.net", "spam.example"])
            == "<unblock xmlns='urn:xmpp:blocking'><item jid='romeo@montague.net'/><item jid='spam.example'/></unblock>")
    // An empty unblock is §3.5 "unblock all"; a bad address must not shrink the list into one.
    for addresses in [[], ["bad address@example.test"], ["romeo@montague.net", "bad address@example.test"]] {
        #expect(throws: XMPPClientError.self, "\(addresses)") { try BlockingWire.unblockXML(addresses) }
    }
}

@Test func pushesAreAcceptedOnlyFromTheServerOrOurAccount() throws {
    let block = "<block xmlns='urn:xmpp:blocking'><item jid='romeo@montague.net'/></block>"
    // XEP-0191 Examples 5, 8 and 10 as pushes.
    #expect(BlockingWire.push(try stanza("<iq type='set' id='push1' to='\(account)/phone'>\(block)</iq>"), accountBareJID: account)
            == .blocked(["romeo@montague.net"]))
    #expect(BlockingWire.push(try stanza("<iq type='set' id='push2' from='Me@Example.test'><unblock xmlns='urn:xmpp:blocking'><item jid='romeo@montague.net'/></unblock></iq>"),
                              accountBareJID: account) == .unblocked(["romeo@montague.net"]))
    #expect(BlockingWire.push(try stanza("<iq type='set' id='push3'><unblock xmlns='urn:xmpp:blocking'/></iq>"), accountBareJID: account) == .unblockedAll)
    for xml in ["<iq type='set' id='p4' from='mallory@example.test'>\(block)</iq>",
                "<iq type='set' id='p5' from='\(account)/laptop'>\(block)</iq>",
                "<iq type='set' id='p6' from='example.test'>\(block)</iq>",
                "<iq type='get' id='p7'>\(block)</iq>",
                // §3.3: a block without items is a bad request, never "block nothing".
                "<iq type='set' id='p8'><block xmlns='urn:xmpp:blocking'/></iq>",
                "<iq type='set' id='p9'><block xmlns='urn:xmpp:blocking'><item jid='a@example.test'/><item jid='bad address@x'/></block></iq>",
                "<iq type='set' id='p10'><blocklist xmlns='urn:xmpp:blocking'/></iq>",
                "<iq type='set' id='p11'>\(block)<query xmlns='jabber:iq:roster'/></iq>"] {
        #expect(BlockingWire.push(try stanza(xml), accountBareJID: account) == nil, "\(xml)")
    }
}

@Test func blocklistMatchesTheXEP0016Order() {
    let list = XMPPBlocklist(["romeo@montague.net", "spam.example", "nurse@capulet.example/balcony", "capulet.example/kitchen", "Iago@Shakespeare.lit"])
    for blocked in ["romeo@montague.net", "romeo@montague.net/orchard", "anyone@spam.example", "spam.example", "bot@spam.example/x",
                    "nurse@capulet.example/balcony", "cook@capulet.example/kitchen", "iago@shakespeare.lit"] {
        #expect(list.blocks(blocked), "\(blocked)")
    }
    // A full-JID entry blocks one resource, so the bare address (the chat) is not blocked by it.
    for open in ["nurse@capulet.example", "nurse@capulet.example/garden", "juliet@capulet.example", "romeo@montague.org", "sub.spam.example.org", "not a jid@x"] {
        #expect(!list.blocks(open), "\(open)")
    }
}

@Test func blocklistChangesApplyInOrder() {
    var list = XMPPBlocklist()
    list.apply(.replaceAll(["a@example.test", "b@example.test"]))
    list.apply(.blocked(["C@Example.test"]))
    list.apply(.unblocked(["a@example.test", "z@example.test"]))
    #expect(list.addresses == ["b@example.test", "c@example.test"])
    list.apply(.unblockedAll)
    #expect(list.isEmpty)
    let decoded = try? JSONDecoder().decode(XMPPBlocklist.self, from: JSONEncoder().encode(XMPPBlocklist(["b@example.test"])))
    #expect(decoded == XMPPBlocklist(["b@example.test"]))
}

/// The fetch, block and push paths through `XMPPClient`'s own socket and parser against `LoopbackServer`.
@Suite(.serialized)
struct BlockingSessionTests {
    private static let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"

    private func online() async throws -> (LoopbackServer, XMPPClient, AsyncStream<XMPPEvent>.Iterator) {
        let server = try await LoopbackServer.start()
        let client = server.client()
        var events = client.events.makeAsyncIterator()
        async let connected: Void = server.connect(client)
        try await server.authenticate(features: "")
        let bind = try await server.next()
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(Self.bindNamespace)'><jid>alice@localhost/r</jid></bind></iq>")
        #expect(try await server.next().name == "presence")
        try await connected
        while let event = await events.next() { if case .state(.online) = event { break } }
        return (server, client, events)
    }

    private func nextBlocklistChange(_ events: inout AsyncStream<XMPPEvent>.Iterator) async -> XMPPBlocklistChange? {
        while let event = await events.next() {
            if case .blocklist(let change) = event { return change }
        }
        return nil
    }

    @Test func pushesAreAnsweredOnlyAfterTheListWasFetched() async throws {
        let (server, client, iterator) = try await online()
        var events = iterator
        let push = "<iq type='set' id='early'><block xmlns='urn:xmpp:blocking'><item jid='bob@localhost'/></block></iq>"
        // Before a fetch the session is not one the server pushes to: the stanza is refused like any unknown request.
        try await server.send(push)
        let refused = try await server.next()
        #expect(refused.attributes["type"] == "error" && refused.attributes["id"] == "early")

        async let fetched = client.fetchBlocklist()
        let request = try await server.next()
        #expect(request.attributes["type"] == "get" && request.attributes["to"] == nil
                && request.child("blocklist", namespace: BlockingWire.namespace) != nil)
        try await server.send("<iq type='result' id='\(request.attributes["id"] ?? "")'><blocklist xmlns='urn:xmpp:blocking'><item jid='Mallory@Localhost'/></blocklist></iq>"
            + push.replacingOccurrences(of: "early", with: "push1"))
        #expect(try await fetched == XMPPBlocklist(["mallory@localhost"]))
        // The result comes first, then the push, in stream order; the push is acknowledged.
        #expect(await nextBlocklistChange(&events) == .replaceAll(["mallory@localhost"]))
        #expect(await nextBlocklistChange(&events) == .blocked(["bob@localhost"]))
        let answer = try await server.next()
        #expect(answer.attributes["type"] == "result" && answer.attributes["id"] == "push1")

        // A push from anyone but our server or account is not one.
        try await server.send("<iq type='set' id='spoof' from='mallory@localhost/x'><unblock xmlns='urn:xmpp:blocking'/></iq>")
        let spoof = try await server.next()
        #expect(spoof.attributes["type"] == "error" && spoof.attributes["id"] == "spoof")
        await client.disconnect()
        await server.stop()
    }

    @Test func blockAndUnblockAreSetsWithoutAnAddress() async throws {
        let (server, client, _) = try await online()
        async let blocked: Void = client.block("bob@localhost", report: XMPPBlockReport(reason: .spam))
        let block = try await server.next()
        #expect(block.attributes["type"] == "set" && block.attributes["to"] == nil)
        let item = try #require(block.child("block", namespace: BlockingWire.namespace)?.child("item", namespace: BlockingWire.namespace))
        #expect(item.attributes["jid"] == "bob@localhost")
        #expect(item.child("report", namespace: BlockingWire.reportingNamespace)?.attributes["reason"] == XMPPReportReason.spam.rawValue)
        try await server.send("<iq type='result' id='\(block.attributes["id"] ?? "")'/>")
        try await blocked

        let unblocked = Task { try await client.unblock(["bob@localhost"]) }
        let unblock = try await server.next()
        #expect(unblock.child("unblock", namespace: BlockingWire.namespace)?.children.count == 1)
        // A server without XEP-0191 refuses; the caller sees the condition.
        try await server.send("<iq type='error' id='\(unblock.attributes["id"] ?? "")'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        await #expect(throws: XMPPIQError.stanza(condition: "service-unavailable")) { try await unblocked.value }
        await client.disconnect()
        await server.stop()
    }
}
