import Foundation
import Testing
@testable import XMPPProtocol

/// The exact presence and XEP-0352 client-state text the iPhone app, its notification extension and its notification
/// actions write, for every way they announce the user. The iOS cases were pinned byte for byte on the client from
/// before client state was separated from presence (they passed unchanged there, with `.away` implying `<inactive/>`),
/// so they show the iOS wire did not change. The desktop cases at the end pair the two the other ways.
@Suite(.serialized)
struct ClientStateWireTests {
    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        init(_ value: XMPPStreamManagementSnapshot?) { self.value = value }
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
    }

    private static let since = Date(timeIntervalSince1970: 1_790_000_000)
    private static let active = "<active xmlns='urn:xmpp:csi:0'/>"
    private static let inactive = "<inactive xmlns='urn:xmpp:csi:0'/>"
    private static let available = "<presence>" + EntityCapabilities.presenceElement + "</presence>"
    private static let idle = "<presence>" + EntityCapabilities.presenceElement
        + "<idle xmlns='urn:xmpp:idle:1' since='2026-09-21T14:13:20Z'/></presence>"
    private static let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"
    private static let smOnly = "<sm xmlns='urn:xmpp:sm:3'/>"

    /// Binds fresh with stream management; returns the byte mark taken just before the server confirms it, so what
    /// follows is the client's own announcement.
    private func bindFresh(_ client: XMPPClient, on server: LoopbackServer, features: String? = nil) async throws -> Int {
        try await client.configureStreamManagement(persistence: Persistence(nil))
        async let online: Void = server.connect(client)
        if let features { try await server.authenticate(features: features) } else { try await server.authenticate() }
        let bind = try await server.next()
        try #require(bind.child("bind", namespace: Self.bindNamespace) != nil)
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(Self.bindNamespace)'><jid>alice@localhost/r</jid></bind></iq>")
        #expect(try await server.next().name == "enable")
        let mark = await server.mark()
        try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true'/>")
        try await online
        return mark
    }

    /// Resumes a saved session whose last announcement was `saved`; returns the mark taken before `<resumed/>`.
    private func resume(_ client: XMPPClient, on server: LoopbackServer, saved: XMPPAvailability) async throws -> Int {
        var snapshot = XMPPStreamManagementSnapshot(revision: 1, accountID: "alice@localhost", fullJID: "alice@localhost/haus-r1",
                                                    streamID: "s1", expiresAt: nil, inboundHandled: 3, outboundSent: 0,
                                                    outboundAcknowledged: 0, journal: [])
        snapshot.availability = saved
        snapshot.capabilities = EntityCapabilities.verification
        try await client.configureStreamManagement(persistence: Persistence(snapshot))
        async let online: Void = server.connect(client)
        try await server.authenticate()
        #expect(try await server.next().name == "resume")
        let mark = await server.mark()
        try await server.send("<resumed xmlns='urn:xmpp:sm:3' previd='s1' h='0'/>")
        try await online
        return mark
    }

    /// Closes the connection and returns what the client wrote after `mark`, up to the farewell's `<r/>`.
    private func announced(_ client: XMPPClient, on server: LoopbackServer, since mark: Int) async throws -> String {
        async let closed: Void = client.disconnectAndWait()
        _ = try await server.remainder()
        await closed
        let text = await server.written(since: mark)
        await server.stop()
        return text.components(separatedBy: "<r xmlns='urn:xmpp:sm:3'/>").first ?? text
    }

    /// Waits until `count` frames arrived, so a mark taken next starts after them.
    private func drain(_ server: LoopbackServer, _ names: [String]) async throws {
        for name in names { #expect(try await server.next().name == name) }
    }

    // MARK: The app in front, and its scene going to the background

    @Test func aFreshStreamInFrontSendsPlainPresenceOnly() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        let mark = try await bindFresh(client, on: server)
        #expect(try await announced(client, on: server, since: mark) == Self.available)
    }

    @Test func goingToTheBackgroundSendsIdlePresenceThenInactive() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        _ = try await bindFresh(client, on: server)
        try await drain(server, ["presence"])
        let mark = await server.mark()
        try await client.setAvailability(.away(since: Self.since), clientActive: false)
        #expect(try await announced(client, on: server, since: mark) == Self.idle + Self.inactive)
    }

    @Test func returningToTheFrontSendsActiveThenPlainPresence() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.away(since: Self.since), clientActive: false)
        _ = try await bindFresh(client, on: server)
        try await drain(server, ["presence", "inactive"])
        let mark = await server.mark()
        try await client.setAvailability(.active, clientActive: true)
        #expect(try await announced(client, on: server, since: mark) == Self.active + Self.available)
    }

    @Test func clientStateAloneWritesOnlyTheNonza() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        _ = try await bindFresh(client, on: server)
        try await drain(server, ["presence"])
        let mark = await server.mark()
        try await client.setClientActive(false)
        try await client.setClientActive(true)
        #expect(try await announced(client, on: server, since: mark) == Self.inactive + Self.active)
    }

    // MARK: The extension and notification actions, which connect away

    @Test func aFreshStreamAwaySendsIdlePresenceThenInactive() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.away(since: Self.since), clientActive: false)
        let mark = try await bindFresh(client, on: server)
        #expect(try await announced(client, on: server, since: mark) == Self.idle + Self.inactive)
    }

    @Test func aFreshStreamAwayWithoutLastSeenOmitsTheIdleTime() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.away(since: nil), clientActive: false)
        let mark = try await bindFresh(client, on: server)
        #expect(try await announced(client, on: server, since: mark) == Self.available + Self.inactive)
    }

    // MARK: Resumed streams

    @Test func resumingAwayOverAwayRestatesOnlyInactive() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.away(since: Self.since), clientActive: false)
        let mark = try await resume(client, on: server, saved: .away(since: Self.since))
        #expect(try await announced(client, on: server, since: mark) == Self.inactive)
    }

    @Test func resumingAwayOverActiveSendsIdlePresenceThenInactive() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.away(since: Self.since), clientActive: false)
        let mark = try await resume(client, on: server, saved: .active)
        #expect(try await announced(client, on: server, since: mark) == Self.idle + Self.inactive)
    }

    @Test func resumingInFrontOverAwaySendsActiveThenPlainPresence() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        let mark = try await resume(client, on: server, saved: .away(since: Self.since))
        #expect(try await announced(client, on: server, since: mark) == Self.active + Self.available)
    }

    @Test func resumingInFrontOverActiveRestatesOnlyActive() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        let mark = try await resume(client, on: server, saved: .active)
        #expect(try await announced(client, on: server, since: mark) == Self.active)
    }

    // MARK: The desktop's other pairings

    @Test func idleWithAWindowOnScreenSendsActiveThenIdlePresence() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        _ = try await bindFresh(client, on: server)
        try await drain(server, ["presence"])
        let mark = await server.mark()
        try await client.setAvailability(.away(since: Self.since), clientActive: true)
        #expect(try await announced(client, on: server, since: mark) == Self.active + Self.idle)
    }

    @Test func presentWithNoWindowSendsPlainPresenceThenInactive() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.away(since: Self.since), clientActive: false)
        _ = try await bindFresh(client, on: server)
        try await drain(server, ["presence", "inactive"])
        let mark = await server.mark()
        try await client.setAvailability(.active, clientActive: false)
        #expect(try await announced(client, on: server, since: mark) == Self.available + Self.inactive)
    }

    /// A Mac launched with no window binds inactive while the user is at the machine.
    @Test func aFreshStreamWithNoWindowBindsAvailableThenInactive() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.active, clientActive: false)
        let mark = try await bindFresh(client, on: server)
        #expect(try await announced(client, on: server, since: mark) == Self.available + Self.inactive)
    }

    /// The window hid while the stream was still binding: the new stream starts with it.
    @Test func clientStateSetBeforeBindingIsWhatTheStreamStartsWith() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setClientActive(false)
        let mark = try await bindFresh(client, on: server)
        #expect(try await announced(client, on: server, since: mark) == Self.available + Self.inactive)
    }

    @Test func resumingIdleWithAWindowRestatesActiveAndSendsTheIdlePresence() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.away(since: Self.since), clientActive: true)
        let mark = try await resume(client, on: server, saved: .active)
        #expect(try await announced(client, on: server, since: mark) == Self.active + Self.idle)
    }

    // MARK: A server without CSI

    @Test func withoutClientStateIndicationOnlyPresenceIsWritten() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.setAvailability(.away(since: Self.since), clientActive: false)
        let mark = try await bindFresh(client, on: server, features: Self.smOnly)
        try await drain(server, ["presence"])
        await #expect(throws: XMPPNotificationError.clientStateUnavailable) { try await client.setClientActive(true) }
        let back = await server.mark()
        try await client.setAvailability(.active, clientActive: true)
        #expect(try await announced(client, on: server, since: back) == Self.available)
        #expect(await server.written(since: mark).hasPrefix(Self.idle + Self.available))
    }
}
