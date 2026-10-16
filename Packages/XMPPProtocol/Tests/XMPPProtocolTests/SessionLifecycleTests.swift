import Foundation
import Testing
@testable import XMPPProtocol

/// Resume, bind, presence and the final acknowledgement over a real socket, against `LoopbackServer`.
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

    /// A hibernating session of `alice@localhost/haus-r1` that had handled three stanzas.
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

    /// Presence from a resumed session reaches every contact and the account's other resources, and the server pushes
    /// their hibernating sessions for it; their extensions would then resume and answer in kind. Only a change is sent.
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

    /// After an update that changed the feature list, contacts would keep the old caps until the next availability
    /// change. The first resume repeats presence once with the new `ver`; later resumes stay quiet again.
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

    /// Resumes the saved session with `availability` and disconnects; returns what the client wrote after `<resume/>`.
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

    /// The app's quiesce and the extension's stop cancel their event consumer before `disconnectAndWait`. What arrives
    /// in between must not end the connection, or the final `<a/>` is lost and the server pushes for its queue again.
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

    /// Binds fresh and enables `s2`; returns once the client is online.
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

    /// The away presence and a chat state written on the way to the background are acknowledged by the farewell, so
    /// the next resume replays nothing: replaying the presence would reach every contact and push their sessions.
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

    /// A probe on demand (the app was told the server pushed for this session): an answer keeps the stream, silence
    /// ends it so the owner reconnects.
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

    /// A server that counts stanzas we never sent gets the XEP-0198 error, and the session is retired: the next
    /// connect binds instead of resuming into the same count for the rest of the 72 h window.
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

    /// The same count on `<resumed/>` ends that connect; the session is retired so the next one binds.
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
