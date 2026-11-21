import Foundation
import Testing
@testable import XMPPProtocol

// Resume, bind, presence and the final acknowledgement over a real socket, against `LoopbackServer`.
@Suite(.serialized)
struct SessionLifecycleTests {
    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        init(_ value: XMPPStreamManagementSnapshot?) { self.value = value }
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
    }

    private static let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"

    // A hibernating session of `alice@localhost/haus-r1` that had handled three stanzas.
    private static func saved(availability: XMPPAvailability?) -> XMPPStreamManagementSnapshot {
        var snapshot = XMPPStreamManagementSnapshot(revision: 1, accountID: "alice@localhost", fullJID: "alice@localhost/haus-r1",
                                                    streamID: "s1", expiresAt: nil, inboundHandled: 3, outboundSent: 0,
                                                    outboundAcknowledged: 0, journal: [])
        snapshot.availability = availability
        snapshot.capabilities = EntityCapabilities.verification
        return snapshot
    }

    @Test func refusedResumeBindsTheInstallationResourceOnTheSameConnection() async throws {
        let server = try await LoopbackServer.start()
        let persistence = Persistence(Self.saved(availability: .active))
        let client = server.client()
        try await client.configureStreamManagement(persistence: persistence)
        try await client.configureResource("haus-r1")
        async let online: Void = server.connect(client)
        try await server.authenticate()
        let resume = try await server.next()
        #expect(resume.name == "resume" && resume.attributes["previd"] == "s1" && resume.attributes["h"] == "3")
        try await server.send("<failed xmlns='urn:xmpp:sm:3'/>")
        let bind = try await server.next()
        #expect(bind.child("bind", namespace: Self.bindNamespace)?.child("resource", namespace: Self.bindNamespace)?.text == "haus-r1")
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(Self.bindNamespace)'><jid>alice@localhost/haus-r1</jid></bind></iq>")
        let enable = try await server.next()
        // No `max`: the server's own window applies.
        #expect(enable.name == "enable" && enable.attributes["resume"] == "true" && enable.attributes["max"] == nil)
        try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true' max='600'/>")
        #expect(try await server.next().name == "presence")
        try await online
        #expect(await !client.sessionResumed)
        let saved = try #require(await persistence.value)
        #expect(saved.streamID == "s2" && saved.fullJID == "alice@localhost/haus-r1")
        #expect(saved.inboundHandled == 0 && saved.resumeTimeoutSeconds == 600)
        await client.disconnect()
        await server.stop()
    }

    // Presence from a resumed session reaches every contact and the account's other resources, and the server pushes
    // their hibernating sessions for it; their extensions would then resume and answer in kind. Only a change is sent.
    @Test func resumedSessionRepeatsPresenceOnlyWhenItChanged() async throws {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let persistence = Persistence(Self.saved(availability: .away(since: since)))
        // The extension resumes what the app left away; its own reading of the time carries a fraction.
        var written = try await resume(persistence, availability: .away(since: since.addingTimeInterval(0.4)))
        #expect(written.map(\.name) == ["inactive", "r", "iq", "a"])
        // Back in front: announced once, and remembered for the next resume.
        written = try await resume(persistence, availability: .active)
        #expect(written.map(\.name) == ["active", "presence", "r", "iq", "a"])
        #expect(written.first { $0.name == "presence" }?.child("idle", namespace: PresenceWire.idleNamespace) == nil)
        #expect(await persistence.value?.availability == .active)
        written = try await resume(persistence, availability: .active)
        #expect(written.map(\.name) == ["active", "r", "iq", "a"])
    }

    // After an update that changed the feature list, contacts would keep the old caps until the next availability
    // change. The first resume repeats presence once with the new `ver`; later resumes stay quiet again.
    @Test func resumeAfterAnUpdateAnnouncesTheNewCapabilitiesOnce() async throws {
        var older = Self.saved(availability: .active)
        older.capabilities = nil
        let persistence = Persistence(older)
        var written = try await resume(persistence, availability: .active)
        #expect(written.map(\.name) == ["active", "presence", "r", "iq", "a"])
        let caps = written.first { $0.name == "presence" }?.child("c", namespace: "http://jabber.org/protocol/caps")
        #expect(caps?.attributes["ver"] == EntityCapabilities.verification)
        #expect(await persistence.value?.capabilities == EntityCapabilities.verification)
        written = try await resume(persistence, availability: .active)
        #expect(written.map(\.name) == ["active", "r", "iq", "a"])
    }

    // Resumes the saved session with `availability` and disconnects; returns what the client wrote after `<resume/>`.
    private func resume(_ persistence: Persistence, availability: XMPPAvailability) async throws -> [XMPPProtocol.XMLNode] {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: persistence)
        try await client.setAvailability(availability, clientActive: availability == .active)
        async let online: Void = server.connect(client)
        try await server.authenticate()
        #expect(try await server.next().name == "resume")
        // The server received everything the previous connection sent: nothing is replayed.
        let sent = await persistence.value?.outboundSent ?? 0
        try await server.send("<resumed xmlns='urn:xmpp:sm:3' previd='s1' h='\(sent)'/>")
        try await online
        #expect(await client.sessionResumed)
        async let closed: Void = client.disconnectAndWait()
        let written = try await server.remainder()
        await closed
        await server.stop()
        return written
    }

    // The app's quiesce and the extension's stop cancel their event consumer before `disconnectAndWait`. What arrives
    // in between must not end the connection, or the final `<a/>` is lost and the server pushes for its queue again.
    @Test func finalAcknowledgementSurvivesTheOwnerStoppingItsConsumerFirst() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: Persistence(nil))
        let consumer = Task { for await _ in client.events {} }
        async let online: Void = server.connect(client)
        try await server.authenticate()
        let bind = try await server.next()
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(Self.bindNamespace)'><jid>alice@localhost/r</jid></bind></iq>")
        #expect(try await server.next().name == "enable")
        try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
        consumer.cancel()
        await consumer.value
        // A contact's presence needs nothing durable and counts; the message was never consumed and does not.
        try await server.send("<presence from='bob@localhost/phone'/>"
            + "<message from='bob@localhost/phone' to='alice@localhost/r' type='chat' id='m1'><body>hi</body></message>"
            + "<r xmlns='urn:xmpp:sm:3'/>")
        #expect(try await server.next().attributes["h"] == "1")
        async let closed: Void = client.disconnectAndWait()
        let written = try await server.remainder()
        await closed
        #expect(written.last?.name == "a" && written.last?.attributes["h"] == "1")
        await server.stop()
    }

    // Binds fresh and enables `s2`; returns once the client is online.
    private func bindFresh(_ client: XMPPClient, on server: LoopbackServer) async throws {
        async let online: Void = server.connect(client)
        try await server.authenticate()
        let bind = try await server.next()
        try #require(bind.name == "iq" && bind.child("bind", namespace: Self.bindNamespace) != nil)
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(Self.bindNamespace)'><jid>alice@localhost/r</jid></bind></iq>")
        #expect(try await server.next().name == "enable")
        try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
    }

    // The away presence and a chat state written on the way to the background are acknowledged by the farewell, so
    // the next resume replays nothing: replaying the presence would reach every contact and push their sessions.
    @Test func farewellRequestsAnAcknowledgementBeforeItsPing() async throws {
        let server = try await LoopbackServer.start()
        let persistence = Persistence(nil)
        let client = server.client()
        try await client.configureStreamManagement(persistence: persistence)
        try await bindFresh(client, on: server)
        try await client.sendChatState(.paused, to: "bob@localhost")
        async let away: Void = client.setAvailability(.away(since: Date(timeIntervalSince1970: 1_790_000_000)), clientActive: false)
        #expect(try await server.next().name == "message")
        #expect(try await server.next().name == "presence")
        #expect(try await server.next().name == "inactive")
        try await away
        async let closed: Void = client.disconnectAndWait()
        #expect(try await server.next().name == "r")
        try await server.send("<a xmlns='urn:xmpp:sm:3' h='3'/>")
        let written = try await server.remainder()
        await closed
        #expect(written.map(\.name) == ["iq", "a"])
        let saved = try #require(await persistence.value)
        // Only the farewell ping's slot is left, and an IQ is never replayed.
        #expect(saved.outboundAcknowledged == 3 && saved.journal.map(\.kind) == [.iq])
        await server.stop()
    }

    // Out of time, the owner cannot wait on a silent server: the hard close ends the farewell and every pending request
    // at once, writes nothing more and leaves the session saved, so the next connect resumes it.
    @Test func hardCloseEndsAStuckFarewellAndKeepsTheSessionResumable() async throws {
        let server = try await LoopbackServer.start()
        let persistence = Persistence(nil)
        let client = server.client()
        try await client.configureStreamManagement(persistence: persistence)
        try await bindFresh(client, on: server)
        let pending = Task { try await client.requestIQ(type: "get", to: nil, payload: "<ping xmlns='urn:xmpp:ping'/>", timeout: .seconds(60)) }
        #expect(try await server.next().name == "iq")
        let closing = Task { await client.disconnectAndWait() }
        #expect(try await server.next().name == "r")
        #expect(try await server.next().name == "iq")
        let mark = await server.mark()
        await client.disconnect()
        await closing.value
        // Its own limit is a minute away: only the closed socket ends it now.
        await #expect(throws: XMPPClientError.connectionClosed) { try await pending.value }
        #expect(try await server.remainder().isEmpty)
        #expect(await !server.written(since: mark).contains("</stream:stream>"))
        #expect(await persistence.value?.streamID == "s2")
        #expect(await !client.isOnline)
        await server.stop()
    }

    // A probe on demand (the app was told the server pushed for this session): an answer keeps the stream, silence
    // ends it so the owner reconnects.
    @Test func livenessProbeKeepsAnAnsweringStreamAndEndsASilentOne() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: Persistence(nil))
        try await bindFresh(client, on: server)
        async let answered = client.probeLiveness(within: .seconds(2))
        #expect(try await server.next().name == "r")
        try await server.send("<a xmlns='urn:xmpp:sm:3' h='1'/>")
        #expect(await answered)
        #expect(await client.isOnline)
        async let silent = client.probeLiveness(within: .milliseconds(300))
        #expect(try await server.next().name == "r")
        #expect(await !silent)
        #expect(await !client.isOnline)
        await server.stop()
    }

    // The background grace waits for this: a message counts until the server's `<a/>` covers it; presence never does.
    @Test func aMessageAwaitsAcknowledgementUntilTheServerCountsIt() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: Persistence(nil))
        try await bindFresh(client, on: server)
        // The initial presence occupies the first slot.
        #expect(await !client.awaitsAcknowledgement())
        _ = try await client.sendMessage(to: "bob@localhost", body: "hi", id: "m1")
        #expect(try await server.next().name == "message")
        #expect(await client.awaitsAcknowledgement())
        // The client handles stanzas in order, so its answer to the `<r/>` means the `<a/>` is in.
        try await server.send("<a xmlns='urn:xmpp:sm:3' h='2'/><r xmlns='urn:xmpp:sm:3'/>")
        #expect(try await server.next().name == "a")
        #expect(await !client.awaitsAcknowledgement())
        await client.disconnect()
        #expect(await !client.awaitsAcknowledgement())
        await server.stop()
    }

    // A stanza past the depth or attribute limit is counted and dropped, and a request among them is refused, so the
    // stream survives and the server has nothing to redeliver.
    @Test func oversizedStanzasAreCountedAndTheStreamStays() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: Persistence(nil))
        try await bindFresh(client, on: server)
        let deep = String(repeating: "<x xmlns='urn:example'>", count: 70) + String(repeating: "</x>", count: 70)
        let wide = (1...129).map { " a\($0)='v'" }.joined()
        try await server.send("<message from='bob@localhost/phone' to='alice@localhost/r' type='chat' id='m1'><body>hi</body>\(deep)</message>"
            + "<iq from='bob@localhost/phone' to='alice@localhost/r' type='get' id='q1'><query\(wide)/></iq>"
            + "<r xmlns='urn:xmpp:sm:3'/>")
        let refusal = try await server.next()
        #expect(refusal.name == "iq" && refusal.attributes["type"] == "error" && refusal.attributes["id"] == "q1")
        #expect(refusal.attributes["to"] == "bob@localhost/phone")
        let condition = refusal.child("error", namespace: "jabber:client")?.child("policy-violation", namespace: "urn:ietf:params:xml:ns:xmpp-stanzas")
        #expect(condition != nil && refusal.child("error", namespace: "jabber:client")?.attributes["type"] == "modify")
        let ack = try await server.next()
        #expect(ack.name == "a" && ack.attributes["h"] == "2")
        #expect(await client.isOnline)
        await client.disconnect()
        await server.stop()
    }

    // A deadline cannot wait for the farewell: abort cancels the socket without the actor, and the stream ends as for
    // any socket failure, so a disconnect still reaches the consumer.
    @Test func abortEndsTheStreamWithoutAFarewell() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: Persistence(nil))
        let ended = Task {
            for await event in client.events { if case .state(.disconnected) = event { return true } }
            return false
        }
        try await bindFresh(client, on: server)
        client.abort()
        #expect(await ended.value)
        #expect(await !client.isOnline)
        #expect(try await server.remainder().isEmpty)
        await server.stop()
    }

    // A server that counts stanzas we never sent gets the XEP-0198 error, and the session is retired: the next
    // connect binds instead of resuming into the same count for the rest of the 72 h window.
    @Test func acknowledgementAboveWhatWasSentRetiresTheSession() async throws {
        let persistence = Persistence(nil)
        do {
            let server = try await LoopbackServer.start()
            let client = server.client()
            try await client.configureStreamManagement(persistence: persistence)
            try await bindFresh(client, on: server)
            try await server.send("<a xmlns='urn:xmpp:sm:3' h='5'/>")
            let error = try await server.next()
            #expect(error.name == "error" && error.namespace == "http://etherx.jabber.org/streams")
            let count = error.child("handled-count-too-high", namespace: "urn:xmpp:sm:3")
            #expect(error.child("undefined-condition", namespace: "urn:ietf:params:xml:ns:xmpp-streams") != nil)
            #expect(count?.attributes["h"] == "5" && count?.attributes["send-count"] == "1")
            await server.stop()
        }
        #expect(await persistence.value?.streamID == nil)
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: persistence)
        try await bindFresh(client, on: server)
        #expect(await persistence.value?.streamID == "s2")
        await client.disconnect()
        await server.stop()
    }

    // The same count on `<resumed/>` ends that connect; the session is retired so the next one binds.
    @Test func resumedCountAboveWhatWasSentRetiresTheSession() async throws {
        let persistence = Persistence(Self.saved(availability: .active))
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: persistence)
        let online = Task { try await server.connect(client) }
        try await server.authenticate()
        #expect(try await server.next().name == "resume")
        try await server.send("<resumed xmlns='urn:xmpp:sm:3' previd='s1' h='2'/>")
        let error = try await server.next()
        #expect(error.child("handled-count-too-high", namespace: "urn:xmpp:sm:3")?.attributes["send-count"] == "0")
        await #expect(throws: XMPPStreamManagementError.invalidAcknowledgement) { try await online.value }
        #expect(await persistence.value?.streamID == nil)
        await server.stop()
    }
}
