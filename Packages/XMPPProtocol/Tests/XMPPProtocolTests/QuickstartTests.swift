import Foundation
import Testing
@testable import XMPPProtocol

// The steps a remembered stream profile sends ahead, and every way back to the plain order, against `LoopbackServer`.
// Each test proves an early element by reading it before the server wrote what it would otherwise wait for.
@Suite(.serialized)
struct QuickstartTests {
    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        init(_ value: XMPPStreamManagementSnapshot?) { self.value = value }
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
    }

    // Records every save, nil included.
    private final class ProfileStore: XMPPStreamProfileStore, @unchecked Sendable {
        private let lock = NSLock()
        private var current: XMPPStreamProfile?
        private var history: [XMPPStreamProfile?] = []
        init(_ profile: XMPPStreamProfile?) { current = profile }
        func streamProfile(account: String) -> XMPPStreamProfile? { lock.withLock { current } }
        func saveStreamProfile(_ profile: XMPPStreamProfile?, account: String) {
            lock.withLock { current = profile; history.append(profile) }
        }
        var saves: [XMPPStreamProfile?] { lock.withLock { history } }
    }

    private static let sasl = "urn:ietf:params:xml:ns:xmpp-sasl"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"

    private static func profile(_ server: LoopbackServer, _ mechanisms: [String], streamManagement: Bool = true,
                                refused: Date? = nil) -> XMPPStreamProfile {
        XMPPStreamProfile(endpoint: XMPPEndpoint(host: "127.0.0.1", port: server.port, security: .directTLS), mechanisms: mechanisms,
                          streamManagement: streamManagement, refusedEarlyData: refused)
    }

    private static func features(_ mechanisms: [String]) -> String {
        "<stream:features><mechanisms xmlns='\(sasl)'>" + mechanisms.map { "<mechanism>\($0)</mechanism>" }.joined()
            + "</mechanisms></stream:features>"
    }

    private static func boundFeatures(streamManagement: Bool = true) -> String {
        "<stream:features><bind xmlns='\(bindNamespace)'/>" + (streamManagement ? "<sm xmlns='urn:xmpp:sm:3'/>" : "") + "</stream:features>"
    }

    private static func bound(_ bind: XMPPProtocol.XMLNode, account: String = "user@localhost", resource: String = "haus-q1") -> String {
        "<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(bindNamespace)'><jid>\(account)/\(resource)</jid></bind></iq>"
    }

    private static func requested(_ bind: XMPPProtocol.XMLNode) -> String? {
        bind.child("bind", namespace: bindNamespace)?.child("resource", namespace: bindNamespace)?.text
    }

    private static func client(_ server: LoopbackServer, profile: XMPPStreamProfile?,
                               snapshot: XMPPStreamManagementSnapshot? = nil) async throws -> (XMPPClient, ProfileStore, Persistence) {
        let client = server.client(), store = ProfileStore(profile), persistence = Persistence(snapshot)
        await client.pinSCRAMNonce(ScriptedSCRAM.clientNonce)
        await client.pinClock(now)
        try await client.configureStreamProfiles(store)
        try await client.configureStreamManagement(persistence: persistence)
        try await client.configureResource("haus-q1")
        return (client, store, persistence)
    }

    private static func connect(_ client: XMPPClient, _ server: LoopbackServer) async throws {
        try await client.connect(host: "127.0.0.1", port: server.port, domain: LoopbackServer.domain, username: "user", password: "pencil")
    }

    // A full SCRAM exchange after the client's `<auth>`, ending with the restarted stream's header.
    private static func completeSCRAM(_ server: LoopbackServer, auth: XMPPProtocol.XMLNode, before challenge: String = "") async throws {
        #expect(auth.text == ScriptedSCRAM.clientFirst)
        try await server.send(challenge + ScriptedSCRAM.challenge)
        let response = try await server.next()
        #expect(response.name == "response" && response.text == ScriptedSCRAM.clientFinal)
        try await server.sendSuccess(ScriptedSCRAM.success)
        try await server.expectOpening()
    }

    // Bind and enable in the plain order, then the initial presence.
    private static func bindInOrder(_ server: LoopbackServer, streamManagement: Bool = true) async throws {
        try await server.send(LoopbackServer.header + boundFeatures(streamManagement: streamManagement))
        let bind = try await server.next()
        try await server.send(bound(bind))
        if streamManagement {
            #expect(try await server.next().name == "enable")
            try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true'/>")
        }
        #expect(try await server.next().name == "presence")
    }

    @Test func aRememberedProfileSendsAuthWithTheHeaderAndBindAndEnableWithTheRestart() async throws {
        let server = try await LoopbackServer.start()
        let remembered = Self.profile(server, ["PLAIN", "SCRAM-SHA-256"])
        let (client, store, persistence) = try await Self.client(server, profile: remembered)
        async let online: Void = Self.connect(client, server)
        try await server.expectOpening()
        let auth = try await server.next()
        #expect(auth.name == "auth" && auth.attributes["mechanism"] == "SCRAM-SHA-256")
        try await Self.completeSCRAM(server, auth: auth, before: LoopbackServer.header + Self.features(["PLAIN", "SCRAM-SHA-256"]))
        let bind = try await server.next()
        #expect(bind.name == "iq" && Self.requested(bind) == "haus-q1")
        #expect(try await server.next().name == "enable")
        try await server.send(LoopbackServer.header + Self.boundFeatures() + Self.bound(bind)
                              + "<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
        #expect(await persistence.value?.streamID == "s2")
        #expect(store.saves.isEmpty)
        await client.disconnect()
        await server.stop()
    }

    // A profile names SCRAM-SHA-1, the server now offers SCRAM-SHA-256 as well: the features choose, so the early
    // `<auth>` is wrong. The client dials again in the plain order and remembers the new offer.
    @Test func aStaleMechanismIsForgottenAndTheEndpointRetriedInThePlainOrder() async throws {
        let server = try await LoopbackServer.start()
        let (client, store, _) = try await Self.client(server, profile: Self.profile(server, ["SCRAM-SHA-1"]))
        let offer = ["SCRAM-SHA-1", "SCRAM-SHA-256"]
        async let online: Void = Self.connect(client, server)
        try await server.expectOpening()
        #expect(try await server.next().attributes["mechanism"] == "SCRAM-SHA-1")
        await server.expectReconnect()
        try await server.send(LoopbackServer.header + Self.features(offer))
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features(offer))
        let auth = try await server.next()
        #expect(auth.attributes["mechanism"] == "SCRAM-SHA-256")
        try await Self.completeSCRAM(server, auth: auth)
        try await Self.bindInOrder(server)
        try await online
        #expect(await server.connections == 2)
        #expect(store.saves == [nil, Self.profile(server, offer)])
        await client.disconnect()
        await server.stop()
    }

    // A refusal of the early `<auth>` may be the early data's fault, so it is never the answer: the plain order is. The
    // endpoint then stays in the plain order for a week, so a server that always refuses costs one reconnect, not one each time.
    @Test(arguments: [true, false])
    func aRefusedEarlyLoginIsRetriedOnceAndOnlyThePlainOrderCanFailIt(_ secondSucceeds: Bool) async throws {
        let server = try await LoopbackServer.start()
        let offer = ["SCRAM-SHA-256"]
        let (client, store, _) = try await Self.client(server, profile: Self.profile(server, offer))
        let connecting = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        #expect(try await server.next().name == "auth")
        await server.expectReconnect()
        try await server.send(LoopbackServer.header + Self.features(offer) + "<failure xmlns='\(Self.sasl)'><not-authorized/></failure>")
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features(offer))
        let auth = try await server.next()
        if secondSucceeds {
            try await Self.completeSCRAM(server, auth: auth)
            try await Self.bindInOrder(server)
            try await connecting.value
            #expect(store.saves == [Self.profile(server, [], streamManagement: false, refused: Self.now),
                                    Self.profile(server, offer, refused: Self.now)])
        } else {
            try await server.send("<failure xmlns='\(Self.sasl)'><not-authorized/></failure>")
            await #expect(throws: XMPPClientError.authenticationFailed) { try await connecting.value }
            #expect(store.saves == [Self.profile(server, [], streamManagement: false, refused: Self.now)])
        }
        #expect(await server.connections == 2)
        await client.disconnect()
        await server.stop()
    }

    // The early `<enable/>` needs stream management; features without it send the client back to the plain order,
    // which binds without enabling.
    @Test func aServerThatDroppedStreamManagementIsRetriedWithoutTheEarlyEnable() async throws {
        let server = try await LoopbackServer.start()
        let offer = ["SCRAM-SHA-256"]
        let (client, store, persistence) = try await Self.client(server, profile: Self.profile(server, offer))
        async let online: Void = Self.connect(client, server)
        try await server.expectOpening()
        let early = try await server.next()
        try await Self.completeSCRAM(server, auth: early, before: LoopbackServer.header + Self.features(offer))
        #expect(try await server.next().name == "iq")
        #expect(try await server.next().name == "enable")
        await server.expectReconnect()
        try await server.send(LoopbackServer.header + Self.boundFeatures(streamManagement: false))
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features(offer))
        try await Self.completeSCRAM(server, auth: try await server.next())
        try await Self.bindInOrder(server, streamManagement: false)
        try await online
        #expect(store.saves == [nil, Self.profile(server, offer, streamManagement: false)])
        #expect(await persistence.value == nil)
        await client.disconnect()
        await server.stop()
    }

    // `<resume>` rides behind the restart; a refusal binds on the same connection, with `<enable/>` behind the bind.
    @Test func anEarlyResumeThatFailsBindsOnTheSameConnection() async throws {
        let server = try await LoopbackServer.start()
        let offer = ["SCRAM-SHA-256"]
        let saved = XMPPStreamManagementSnapshot(revision: 1, accountID: "user@localhost", fullJID: "user@localhost/haus-q1",
                                                 streamID: "s1", expiresAt: nil, inboundHandled: 3, outboundSent: 0,
                                                 outboundAcknowledged: 0, journal: [])
        let (client, _, persistence) = try await Self.client(server, profile: Self.profile(server, offer), snapshot: saved)
        async let online: Void = Self.connect(client, server)
        try await server.expectOpening()
        let early = try await server.next()
        try await Self.completeSCRAM(server, auth: early, before: LoopbackServer.header + Self.features(offer))
        let resume = try await server.next()
        #expect(resume.name == "resume" && resume.attributes["previd"] == "s1" && resume.attributes["h"] == "3")
        try await server.send(LoopbackServer.header + Self.boundFeatures() + "<failed xmlns='urn:xmpp:sm:3'/>")
        let bind = try await server.next()
        #expect(try await server.next().name == "enable")
        try await server.send(Self.bound(bind) + "<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
        #expect(await server.connections == 1)
        #expect(await persistence.value?.streamID == "s2")
        await client.disconnect()
        await server.stop()
    }

    // Without a profile only `<enable/>` goes ahead, behind the bind. A refused bind refuses it too (XEP-0198: no
    // enable before binding); the client takes that `<failed/>`, binds a server-assigned resource and enables again.
    @Test func aRefusedBindTakesTheEarlyEnablesFailureAndEnablesAfterTheNextBind() async throws {
        let server = try await LoopbackServer.start()
        let (client, store, persistence) = try await Self.client(server, profile: nil)
        async let online: Void = server.connect(client)
        try await server.authenticate()
        let first = try await server.next()
        #expect(Self.requested(first) == "haus-q1")
        #expect(try await server.next().name == "enable")
        let stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas"
        try await server.send("<iq type='error' id='\(first.attributes["id"] ?? "")'><error type='cancel'><conflict xmlns='\(stanzas)'/></error></iq>"
                              + "<failed xmlns='urn:xmpp:sm:3'><unexpected-request xmlns='\(stanzas)'/></failed>")
        let second = try await server.next()
        #expect(second.name == "iq" && Self.requested(second) == nil)
        #expect(try await server.next().name == "enable")
        try await server.send(Self.bound(second, account: "alice@localhost", resource: "assigned")
                              + "<enabled xmlns='urn:xmpp:sm:3' id='s3' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
        #expect(await persistence.value?.fullJID == "alice@localhost/assigned")
        #expect(store.saves == [Self.profile(server, ["PLAIN"])])
        await client.disconnect()
        await server.stop()
    }

    // A server that handles IQs off its stream reader can read the early `<enable/>` before the bind finished and
    // refuse it, before or after the bind's answer. The client enables in order on the same stream.
    @Test(arguments: [true, false])
    func anEarlyEnableRefusedBeforeTheBindFinishedIsSentAgainInOrder(_ refusalFirst: Bool) async throws {
        let server = try await LoopbackServer.start()
        let (client, _, persistence) = try await Self.client(server, profile: nil)
        async let online: Void = server.connect(client)
        try await server.authenticate()
        let bind = try await server.next()
        #expect(try await server.next().name == "enable")
        let refusal = "<failed xmlns='urn:xmpp:sm:3'><unexpected-request xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>"
        let result = Self.bound(bind, account: "alice@localhost")
        try await server.send(refusalFirst ? refusal + result : result + refusal)
        #expect(try await server.next().name == "enable")
        try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='s4' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
        #expect(await server.connections == 1)
        #expect(await persistence.value?.streamID == "s4")
        await client.disconnect()
        await server.stop()
    }

    @Test(arguments: [6, 8])
    func aRefusalKeepsTheEndpointInThePlainOrderForAWeek(_ daysAgo: Int) async throws {
        let server = try await LoopbackServer.start()
        let offer = ["SCRAM-SHA-256"]
        let refused = Self.now.addingTimeInterval(-Double(daysAgo) * 24 * 60 * 60)
        let (client, store, _) = try await Self.client(server, profile: Self.profile(server, offer, refused: refused))
        let ahead = daysAgo > 7
        async let online: Void = Self.connect(client, server)
        try await server.expectOpening()
        #expect(await server.pending == (ahead ? 1 : 0))
        if !ahead { try await server.send(LoopbackServer.header + Self.features(offer)) }
        let auth = try await server.next()
        try await Self.completeSCRAM(server, auth: auth, before: ahead ? LoopbackServer.header + Self.features(offer) : "")
        if !ahead { try await server.send(LoopbackServer.header + Self.boundFeatures()) }
        let bind = try await server.next()
        #expect(await server.pending == (ahead ? 1 : 0))
        try await server.send((ahead ? LoopbackServer.header + Self.boundFeatures() : "") + Self.bound(bind))
        #expect(try await server.next().name == "enable")
        try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='s5' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
        #expect(store.saves == (ahead ? [Self.profile(server, offer)] : []))
        await client.disconnect()
        await server.stop()
    }

    // PLAIN would put the password ahead of the features, so a PLAIN-only profile sends nothing early.
    @Test func aPlainOnlyProfileWaitsForTheFeatures() {
        let endpoint = XMPPEndpoint(host: "127.0.0.1", port: 5223, security: .directTLS)
        let plain = XMPPStreamProfile(endpoint: endpoint, mechanisms: ["PLAIN"], streamManagement: true)
        #expect(StreamQuickstart(plain, endpoint: endpoint, password: "loopback", requireSCRAM: false) == nil)
        let scram = XMPPStreamProfile(endpoint: endpoint, mechanisms: ["PLAIN", "SCRAM-SHA-1"], streamManagement: true)
        #expect(StreamQuickstart(scram, endpoint: endpoint, password: "loopback", requireSCRAM: false)?.mechanism == .scramSHA1)
        // Another endpoint, or a password SCRAM cannot prepare, sends nothing early either.
        #expect(StreamQuickstart(scram, endpoint: XMPPEndpoint(host: "127.0.0.1", port: 5222, security: .startTLS), password: "loopback",
                                 requireSCRAM: false) == nil)
        #expect(StreamQuickstart(scram, endpoint: endpoint, password: "\u{0627}\u{0644}", requireSCRAM: false) == nil)
    }
}

// The server's half of the RFC 7677 SCRAM-SHA-256 example (user `user`, password `pencil`), replayed against a client
// whose nonce is pinned to the example's, so the client's own SCRAM checks a real server signature.
private enum ScriptedSCRAM {
    static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
    static let clientFirst = Data("n,,n=user,r=rOprNGfwEbeRWgbNEkqO".utf8).base64EncodedString()
    static let clientFinal = Data("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=".utf8)
        .base64EncodedString()
    static let challenge = "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
        + Data("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8).base64EncodedString() + "</challenge>"
    static let success = "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
        + Data("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=".utf8).base64EncodedString() + "</success>"
}
