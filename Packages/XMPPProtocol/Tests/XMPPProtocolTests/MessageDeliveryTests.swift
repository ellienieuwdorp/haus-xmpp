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

    /// `message` as a received carbon our server wrote, with `extra` on the wrapper.
    private static func carbon(_ message: String, extra: String = "") -> String {
        "<message from='alice@localhost' to='alice@localhost/r'><received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>"
            + message.replacingOccurrences(of: "<message ", with: "<message xmlns='jabber:client' ") + "</forwarded></received>\(extra)</message>"
    }

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
            // Prosody's mod_smacks puts its delay on the carbon wrapper it queued, not inside the forwarded copy.
            + Self.carbon(Self.encrypted("carbon", extra: Self.delay("bob@localhost", "2026-09-01T00:00:00Z")), extra: Self.delay("alice@localhost", held))
            + Self.encrypted("live")
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

    /// Our server stamps only what it held while we were away and sends it first. Later, a delay naming our server was
    /// written by the sender, who could otherwise date a live message into the past, below the read pointer.
    @Test func aDelayNamingOurServerAfterTheCatchUpIsTheSendersClaim() async throws {
        for ending in ["live message", "answer to our request"] {
            let (server, client, iterator) = try await online()
            var events = iterator
            let forged = Self.delay("localhost", "2026-10-01T08:00:00Z")
            try await server.send(Self.encrypted("held", extra: Self.delay("alice@localhost", "2026-10-01T09:00:00Z")))
            if ending == "live message" {
                try await server.send(Self.encrypted("live"))
            } else {
                async let roster = client.fetchRoster()
                let request = try await server.next()
                try await server.send("<iq type='result' id='\(request.attributes["id"] ?? "")'><query xmlns='\(PresenceWire.rosterNamespace)'/></iq>")
                _ = try await roster
            }
            try await server.send(Self.encrypted("forged", extra: forged)
                + Self.carbon(Self.encrypted("forged-carbon"), extra: forged)
                + "<message from='bob@localhost/phone' id='end'><body>end</body></message>")
            var stamps: [String: Date?] = [:]
            for case .encryptedMessage(let message) in await collect(until: "end", from: &events) { stamps[message.id] = message.serverStamp }
            #expect(stamps["held"] == ArchiveQuery.timestamp("2026-10-01T09:00:00Z"), "\(ending)")
            #expect(stamps["forged"] == .some(nil), "\(ending)")
            #expect(stamps["forged-carbon"] == .some(nil), "\(ending)")
            await client.disconnect()
            await server.stop()
        }
    }

    /// A hibernation queue holds only what arrived after the previous stream's last contact, so a replayed message
    /// stamped earlier than that (less the margin) carries a delay its sender wrote.
    @Test func aResumedStreamTakesNoStampOlderThanThePreviousStreamsLastContact() async throws {
        let lastContact = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3_600).rounded())
        var saved = XMPPStreamManagementSnapshot(revision: 1, accountID: "alice@localhost", fullJID: "alice@localhost/r", streamID: "s1",
                                                 expiresAt: lastContact.addingTimeInterval(600), inboundHandled: 0, outboundSent: 0,
                                                 outboundAcknowledged: 0, journal: [], resumeTimeoutSeconds: 600)
        saved.availability = .active
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: Persistence(saved))
        var events = client.events.makeAsyncIterator()
        async let connected: Void = server.connect(client)
        try await server.authenticate()
        #expect(try await server.next().name == "resume")
        try await server.send("<resumed xmlns='urn:xmpp:sm:3' previd='s1' h='0'/>")
        try await connected
        func stamp(_ date: Date) -> String { Self.delay("alice@localhost", date.formatted(.iso8601)) }
        let queued = lastContact.addingTimeInterval(-60), backdated = lastContact.addingTimeInterval(-6 * 3_600)
        try await server.send(Self.encrypted("queued", extra: stamp(queued)) + Self.encrypted("backdated", extra: stamp(backdated))
            + "<message from='bob@localhost/phone' id='end'><body>end</body></message>")
        var stamps: [String: Date?] = [:]
        for case .encryptedMessage(let message) in await collect(until: "end", from: &events) { stamps[message.id] = message.serverStamp }
        #expect(stamps["queued"] == queued)
        #expect(stamps["backdated"] == .some(nil))
        await client.disconnect()
        await server.stop()
    }

    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        init(_ value: XMPPStreamManagementSnapshot?) { self.value = value }
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) { value = snapshot }
    }

    @Test func returnedStanzasAreRoutedBeforeContentAndNeverReachDecryption() async throws {
        let (server, client, iterator) = try await online()
        var events = iterator
        func bounce(_ id: String?, from: String = "nobody@localhost", error: String) throws -> String {
            let xml = try Self.encrypted(id ?? "x", from: from, extra: "<error type='cancel'>\(error)<text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>Visit evil.example</text></error>")
                .replacingOccurrences(of: "type='chat'", with: "type='error'")
            return id == nil ? xml.replacingOccurrences(of: " id='x'", with: "") : xml
        }
        let stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas"
        try await server.send(bounce("m1", error: "<service-unavailable xmlns='\(stanzas)'/>")
            + bounce("m2", from: "bob@localhost", error: "<not-acceptable xmlns='\(stanzas)'/><blocked xmlns='urn:xmpp:blocking:errors'/>")
            + bounce("m3", from: "carol@remote.example", error: "<made-up xmlns='\(stanzas)'/>")
            + bounce(nil, error: "<item-not-found xmlns='\(stanzas)'/>")
            + "<message from='bob@localhost/phone' id='end'><body>end</body></message>")
        let seen = await collect(until: "end", from: &events)
        // The echoed ciphertext is not a message, nor a failed decryption.
        #expect(!seen.contains { if case .encryptedMessage = $0 { true } else if case .encryptionFailure = $0 { true } else { false } })
        #expect(seen.compactMap { if case .messageError(let error) = $0 { error } else { nil } } == [
            XMPPMessageError(id: "m1", from: "nobody@localhost", condition: "service-unavailable", type: "cancel"),
            XMPPMessageError(id: "m2", from: "bob@localhost", condition: "not-acceptable", type: "cancel", blockedByUs: true),
            XMPPMessageError(id: "m3", from: "carol@remote.example", condition: "undefined-condition", type: "cancel")
        ])
        await client.disconnect()
        await server.stop()
    }

    @Test func aRoomThatReturnsOurMessageAsNotAcceptableIsNoLongerJoined() async throws {
        let (server, client, iterator) = try await online()
        var events = iterator
        let room = "room@rooms.localhost"
        async let joining = client.joinGroupRoom(room, nickname: "alice")
        // Discovery and the affiliation lists, read twice (nothing is cached yet), then the join presence.
        for _ in 0..<2 {
            let disco = try await server.next()
            try await server.send("<iq type='result' from='\(room)' id='\(disco.attributes["id"] ?? "")'><query xmlns='\(GroupChatWire.disco)'><feature var='muc_nonanonymous'/><feature var='muc_membersonly'/><feature var='urn:xmpp:sid:0'/></query></iq>")
            for affiliation in ["member", "admin", "owner"] {
                let query = try await server.next()
                let item = affiliation == "owner" ? "<item affiliation='owner' jid='alice@localhost'/>" : ""
                try await server.send("<iq type='result' from='\(room)' id='\(query.attributes["id"] ?? "")'><query xmlns='\(GroupChatWire.admin)'>\(item)</query></iq>")
            }
        }
        #expect(try await server.next().name == "presence")
        _ = try await joining
        try await server.send("<presence from='\(room)/alice' to='alice@localhost/r'><x xmlns='\(GroupChatWire.user)'><item affiliation='owner' jid='alice@localhost/r'/><status code='110'/></x></presence>")
        while let event = await events.next() { if case .groupPresence = event { break } }
        #expect(try await client.groupRoomSnapshot(room)?.joined == true)
        // A server restart or a kick we never saw: the room answers our next message as from a non-occupant.
        try await server.send("<message from='\(room)' to='alice@localhost/r' type='error' id='g1'><error type='cancel'><not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>"
            + "<message from='bob@localhost/phone' id='end'><body>end</body></message>")
        let seen = await collect(until: "end", from: &events)
        #expect(seen.contains(.groupPresence(room: room)))
        #expect(seen.contains(.messageError(XMPPMessageError(id: "g1", from: room, condition: "not-acceptable", type: "cancel"))))
        #expect(try await client.groupRoomSnapshot(room)?.joined == false)
        await client.disconnect()
        await server.stop()
    }
}
