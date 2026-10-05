import Foundation
import Testing
@testable import XMPPProtocol

/// Server delay stamps and returned stanzas, through `XMPPClient`'s own socket and parser against `LoopbackServer`.
@Suite(.serialized)
struct MessageDeliveryTests {
    private static let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"
    private static let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 7,
                                                    keys: [.init(recipientJID: "alice@localhost", deviceID: 9, keyExchange: false, data: Data([1]))],
                                                    payload: Data([2]))

    /// An OMEMO message from `from` to our bound resource, with `extra` children.
    private static func encrypted(_ id: String, from: String = "bob@localhost/phone", extra: String = "") throws -> String {
        try OMEMOWire.messageXML(to: "alice@localhost", envelope: envelope, id: id)
            .replacingOccurrences(of: "<message to='alice@localhost'", with: "<message from='\(from)' to='alice@localhost/r'")
            .replacingOccurrences(of: "</message>", with: extra + "</message>")
    }

    private static func delay(_ from: String, _ stamp: String) -> String { "<delay xmlns='urn:xmpp:delay' from='\(from)' stamp='\(stamp)'/>" }

    /// Signed in as alice@localhost/r without stream management; the iterator has seen everything up to `.online`.
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

    /// Events up to (not including) the plaintext message with id `end`, which the caller sent last.
    private func collect(until end: String, from iterator: inout AsyncStream<XMPPEvent>.Iterator) async -> [XMPPEvent] {
        var seen: [XMPPEvent] = []
        while let event = await iterator.next() {
            if case .message(let message) = event, message.id == end { break }
            seen.append(event)
        }
        return seen
    }

    @Test func liveMessagesTakeOnlyOurOwnServersDelayAsTheirTime() async throws {
        let (server, client, iterator) = try await online()
        var events = iterator
        let held = "2026-10-01T08:00:00Z", offline = "2026-09-30T21:15:30.250Z"
        try await server.send(Self.encrypted("hibernated", extra: Self.delay("alice@localhost", held))
            + Self.encrypted("offline", extra: Self.delay("bob@localhost", "2026-09-01T00:00:00Z") + Self.delay("localhost", offline))
            + Self.encrypted("peer", extra: Self.delay("bob@localhost", held))
            + Self.encrypted("resource", extra: Self.delay("alice@localhost/r", held))
            + Self.encrypted("ambiguous", extra: Self.delay("alice@localhost", held) + Self.delay("localhost", offline))
            + Self.encrypted("future", extra: Self.delay("alice@localhost", "2099-01-01T00:00:00Z"))
            + Self.encrypted("live")
            // Prosody's mod_smacks puts its delay on the carbon wrapper it queued, not inside the forwarded copy.
            + "<message from='alice@localhost' to='alice@localhost/r'><received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>"
            + Self.encrypted("carbon", extra: Self.delay("bob@localhost", "2026-09-01T00:00:00Z")).replacingOccurrences(of: "<message ", with: "<message xmlns='jabber:client' ")
            + "</forwarded></received>\(Self.delay("alice@localhost", held))</message>"
            + "<message from='bob@localhost/phone' id='end'><body>end</body></message>")
        var stamps: [String: Date?] = [:]
        for case .encryptedMessage(let message) in await collect(until: "end", from: &events) { stamps[message.id] = message.serverStamp }
        let heldDate = try #require(ArchiveQuery.timestamp(held)), offlineDate = try #require(ArchiveQuery.timestamp(offline))
        #expect(stamps["hibernated"] == heldDate)
        #expect(stamps["offline"] == offlineDate)
        #expect(stamps["carbon"] == heldDate)
        for id in ["peer", "resource", "ambiguous", "live"] { #expect(stamps[id] == .some(nil), "\(id)") }
        let future = try #require(stamps["future"] ?? nil)
        #expect(future <= Date())
        await client.disconnect()
        await server.stop()
    }
}
