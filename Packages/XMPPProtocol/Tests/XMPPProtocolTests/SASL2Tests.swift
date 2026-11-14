import Foundation
import Testing
@testable import XMPPProtocol

// SASL2 with Bind 2, inline stream management and FAST, and the RFC 6120 fallback, against `LoopbackServer`. The SCRAM
// exchange is RFC 7677's (user, pencil), so the server's answers are fixed text.
@Suite(.serialized)
struct SASL2Tests {
    actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        init(_ value: XMPPStreamManagementSnapshot?) { self.value = value }
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
    }

    final class Tokens: XMPPFastTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var current: XMPPFastToken?
        private var history: [XMPPFastToken?] = []
        init(_ token: XMPPFastToken?) { current = token }
        func fastToken(account: String) -> XMPPFastToken? { lock.withLock { account == "user@localhost" ? current : nil } }
        func saveFastToken(_ token: XMPPFastToken?, account: String) { lock.withLock { current = token; history.append(token) } }
        var saved: XMPPFastToken? { lock.withLock { current } }
        var saves: [XMPPFastToken?] { lock.withLock { history } }
    }

    final class Profiles: XMPPStreamProfileStore, @unchecked Sendable {
        private let lock = NSLock()
        private var current: XMPPStreamProfile?
        init(_ profile: XMPPStreamProfile?) { current = profile }
        func streamProfile(account: String) -> XMPPStreamProfile? { lock.withLock { current } }
        func saveStreamProfile(_ profile: XMPPStreamProfile?, account: String) { lock.withLock { current = profile } }
        var saved: XMPPStreamProfile? { lock.withLock { current } }
    }

    static let sasl2 = "urn:xmpp:sasl:2", bind2 = "urn:xmpp:bind:0", fast = "urn:xmpp:fast:0", sm = "urn:xmpp:sm:3"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let clientID = UUID(uuid: (0x6A, 0x3F, 0x2C, 0x1E, 0x8B, 0x7D, 0x4E, 0x5F, 0x9A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F, 0x6A, 0x7B))
    static let token = XMPPFastToken(mechanism: "HT-SHA-256-NONE", secret: "secret-token:fast-abc", expiry: now.addingTimeInterval(86_400))
    static let boundJID = "user@localhost/Haus~q1"

    static func features(sasl2 mechanisms: [String]? = ["SCRAM-SHA-256", "PLAIN"], fast: [String] = ["HT-SHA-256-NONE"],
                         bindFeatures: [String] = ["urn:xmpp:carbons:2", "urn:xmpp:csi:0", "urn:xmpp:sm:3"], resumes: Bool = true,
                         sasl1: [String] = ["SCRAM-SHA-256", "PLAIN"], bindings: [String] = []) -> String {
        var xml = "<stream:features>"
        if let mechanisms {
            xml += "<authentication xmlns='\(sasl2)'>" + mechanisms.map { "<mechanism>\($0)</mechanism>" }.joined() + "<inline>"
            xml += "<bind xmlns='\(bind2)'><inline>" + bindFeatures.map { "<feature var='\($0)'/>" }.joined() + "</inline></bind>"
            if resumes { xml += "<sm xmlns='\(sm)'/>" }
            if !fast.isEmpty { xml += "<fast xmlns='\(Self.fast)'>" + fast.map { "<mechanism>\($0)</mechanism>" }.joined() + "</fast>" }
            xml += "</inline></authentication>"
        }
        xml += "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>" + sasl1.map { "<mechanism>\($0)</mechanism>" }.joined() + "</mechanisms>"
        if !bindings.isEmpty {
            xml += "<sasl-channel-binding xmlns='urn:xmpp:sasl-cb:0'>" + bindings.map { "<channel-binding type='\($0)'/>" }.joined()
                + "</sasl-channel-binding>"
        }
        return xml + "</stream:features>"
    }

    static let postFeatures = "<stream:features><limits xmlns='urn:xmpp:stream-limits:0'><max-bytes>10000</max-bytes></limits></stream:features>"

    static func client(_ server: LoopbackServer, tokens: Tokens? = Tokens(nil), profile: XMPPStreamProfile? = nil,
                       snapshot: XMPPStreamManagementSnapshot? = nil, sasl2: Bool = true) async throws -> (XMPPClient, Persistence, Profiles) {
        let client = server.client(), persistence = Persistence(snapshot), profiles = Profiles(profile)
        await client.pinSCRAMNonce(RFC7677.clientNonce)
        await client.pinClock(now)
        try await client.configureStreamManagement(persistence: persistence)
        try await client.configureStreamProfiles(profiles)
        try await client.configureResource("haus-q1")
        if sasl2 { try await client.configureSASL2(XMPPSASL2Configuration(clientID: clientID, enablesCarbons: true, tokens: tokens)) }
        return (client, persistence, profiles)
    }

    static func connect(_ client: XMPPClient, _ server: LoopbackServer, pin: XMPPAuthenticationPin = .none) async throws -> XMPPConnectedSession {
        try await client.connect(host: "127.0.0.1", port: server.port, domain: LoopbackServer.domain, username: "user", password: "pencil", pin: pin)
    }

    static func snapshot(streamID: String = "s1") -> XMPPStreamManagementSnapshot {
        XMPPStreamManagementSnapshot(revision: 1, accountID: "user@localhost", fullJID: boundJID, streamID: streamID,
                                     expiresAt: now.addingTimeInterval(300), inboundHandled: 7, outboundSent: 0, outboundAcknowledged: 0,
                                     journal: [], resumeTimeoutSeconds: 300)
    }

    // HMAC-SHA-256 over "Initiator" and "Responder" keyed with `token`'s secret, computed with Python's hmac module.
    static let initiator = Data(base64Encoded: "MaQPleIiWJr7jCjCEhGUE8mfFTDtEUWPLM0UGYjucJ4=") ?? Data()
    static let responder = Data(base64Encoded: "kP0GDjSVGqRF4nKLtIi3QlXFuDVf6mGFRvdYjlQnogQ=") ?? Data()

    static func success(additional: Data?, identifier: String = boundJID, inner: String) -> String {
        let data = additional.map { "<additional-data>\($0.base64EncodedString())</additional-data>" } ?? ""
        return "<success xmlns='\(sasl2)'>\(data)<authorization-identifier>\(identifier)</authorization-identifier>\(inner)</success>"
    }

    static let bound = "<bound xmlns='\(bind2)'><enabled xmlns='\(sm)' id='s2' resume='1' max='600'/><enabled xmlns='urn:xmpp:carbons:2'/></bound>"
    static let issued = "<token xmlns='\(fast)' expiry='2027-01-15T08:00:00Z' token='secret-token:fast-new'/>"

    static func parsed(_ features: String) throws -> XMPPProtocol.XMLNode {
        var framer = XMLStreamFramer()
        for case .element(let node) in try framer.feed(Data((LoopbackServer.header + features).utf8)) { return node }
        throw LoopbackServer.Failure(description: "no features")
    }

    static func challenge() -> String { "<challenge xmlns='\(sasl2)'>\(RFC7677.serverFirst.base64EncodedString())</challenge>" }

    // The SCRAM exchange after `<authenticate>`, answered with `inner` in the success.
    static func completeSCRAM(_ server: LoopbackServer, inner: String) async throws {
        try await server.send(challenge())
        let response = try await server.next()
        #expect(response.name == "response" && response.namespace == sasl2 && response.text == RFC7677.clientFinal.base64EncodedString())
        try await server.send(success(additional: RFC7677.serverFinal, inner: inner) + postFeatures)
    }

    @Test func aFreshSignInBindsEnablesCarbonsAndStreamManagementAndAsksForAToken() async throws {
        let server = try await LoopbackServer.start()
        let tokens = Tokens(nil)
        let (client, persistence, profiles) = try await Self.client(server, tokens: tokens)
        let session = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        #expect(await server.written(since: 0).contains("from='user@localhost'"))
        try await server.send(LoopbackServer.header + Self.features())
        let authenticate = try await server.next()
        #expect(authenticate.name == "authenticate" && authenticate.namespace == Self.sasl2)
        #expect(authenticate.attributes["mechanism"] == "SCRAM-SHA-256")
        #expect(authenticate.child("initial-response", namespace: Self.sasl2)?.text == RFC7677.clientFirst.base64EncodedString())
        #expect(authenticate.child("user-agent", namespace: Self.sasl2)?.attributes["id"] == Self.clientID.uuidString.lowercased())
        #expect(authenticate.child("request-token", namespace: Self.fast)?.attributes["mechanism"] == "HT-SHA-256-NONE")
        #expect(authenticate.child("resume", namespace: Self.sm) == nil)
        let bind = try #require(authenticate.child("bind", namespace: Self.bind2))
        #expect(bind.child("tag", namespace: Self.bind2)?.text == "Haus")
        #expect(bind.child("enable", namespace: Self.sm)?.attributes["resume"] == "true")
        #expect(bind.child("enable", namespace: "urn:xmpp:carbons:2") != nil)
        try await Self.completeSCRAM(server, inner: Self.bound + Self.issued)
        // Online at once: presence follows the success with no restart and no bind request.
        #expect(try await server.next().name == "presence")
        let connected = try await session.value
        #expect(connected.pin == XMPPAuthenticationPin(scram: true, sasl2: true))
        #expect(await client.carbonsEnabledInline)
        #expect(await persistence.value?.streamID == "s2")
        #expect(await persistence.value?.fullJID == Self.boundJID)
        #expect(tokens.saved?.secret == "secret-token:fast-new" && tokens.saved?.mechanism == "HT-SHA-256-NONE")
        #expect(profiles.saved?.sasl2?.fast == ["HT-SHA-256-NONE"])
        await client.disconnect()
        await server.stop()
    }

    @Test func anInlineResumeRestoresTheSessionWithoutBinding() async throws {
        let server = try await LoopbackServer.start()
        let (client, persistence, _) = try await Self.client(server, snapshot: Self.snapshot())
        let session = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features())
        let authenticate = try await server.next()
        let resume = try #require(authenticate.child("resume", namespace: Self.sm))
        #expect(resume.attributes["previd"] == "s1" && resume.attributes["h"] == "7")
        #expect(authenticate.child("bind", namespace: Self.bind2) != nil)
        // Stanzas the server replays may come before the features that follow the success.
        try await Self.completeSCRAM(server, inner: "<resumed xmlns='\(Self.sm)' previd='s1' h='0'/>")
        _ = try await session.value
        #expect(await client.sessionResumed)
        #expect(await persistence.value?.streamID == "s1")
        await client.disconnect()
        await server.stop()
    }

    @Test func aFailedInlineResumeTakesTheBindInTheSameSuccess() async throws {
        let server = try await LoopbackServer.start()
        let (client, persistence, _) = try await Self.client(server, snapshot: Self.snapshot())
        let session = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features())
        #expect(try await server.next().child("resume", namespace: Self.sm) != nil)
        try await Self.completeSCRAM(server, inner: "<failed xmlns='\(Self.sm)' h='3'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>"
                                     + Self.bound)
        #expect(try await server.next().name == "presence")
        _ = try await session.value
        #expect(await !client.sessionResumed)
        #expect(await persistence.value?.streamID == "s2")
        await client.disconnect()
        await server.stop()
    }

    @Test func aSavedTokenSignsInInOneExchangeAndARotatedOneReplacesIt() async throws {
        let server = try await LoopbackServer.start()
        let tokens = Tokens(Self.token)
        let (client, _, _) = try await Self.client(server, tokens: tokens)
        let session = Task { try await Self.connect(client, server, pin: XMPPAuthenticationPin(scram: true)) }
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features())
        let authenticate = try await server.next()
        #expect(authenticate.attributes["mechanism"] == "HT-SHA-256-NONE")
        #expect(authenticate.child("fast", namespace: Self.fast) != nil && authenticate.child("request-token", namespace: Self.fast) == nil)
        let initial = try #require(Data(base64Encoded: authenticate.child("initial-response", namespace: Self.sasl2)?.text ?? ""))
        #expect(initial == Data("user".utf8) + Data([0]) + Self.initiator)
        try await server.send(Self.success(additional: Self.responder, inner: Self.bound + Self.issued) + Self.postFeatures)
        #expect(try await server.next().name == "presence")
        let connected = try await session.value
        #expect(connected.pin == XMPPAuthenticationPin(scram: true, sasl2: true))
        #expect(tokens.saved == XMPPFastToken(mechanism: "HT-SHA-256-NONE", secret: "secret-token:fast-new",
                                              expiry: try #require(SASL2Wire.date("2027-01-15T08:00:00Z"))))
        await client.disconnect()
        await server.stop()
    }

    // The server must prove it holds the token too; without that the stream is not the account's server.
    @Test func aSuccessWithoutTheServersTokenProofFails() async throws {
        let server = try await LoopbackServer.start()
        let (client, _, _) = try await Self.client(server, tokens: Tokens(Self.token))
        let session = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features())
        _ = try await server.next()
        try await server.send(Self.success(additional: Data(repeating: 7, count: 32), inner: Self.bound) + Self.postFeatures)
        await #expect(throws: XMPPClientError.authenticationFailed) { _ = try await session.value }
        await server.stop()
    }

    @Test func aRefusedTokenIsDeletedAndThePasswordTriedOnTheSameStream() async throws {
        let server = try await LoopbackServer.start()
        let tokens = Tokens(Self.token)
        let (client, _, _) = try await Self.client(server, tokens: tokens, snapshot: Self.snapshot())
        let session = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features())
        #expect(try await server.next().attributes["mechanism"] == "HT-SHA-256-NONE")
        try await server.send("<failure xmlns='\(Self.sasl2)'><credentials-expired xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>")
        let retry = try await server.next()
        #expect(retry.attributes["mechanism"] == "SCRAM-SHA-256")
        #expect(retry.child("request-token", namespace: Self.fast)?.attributes["mechanism"] == "HT-SHA-256-NONE")
        #expect(retry.child("resume", namespace: Self.sm) != nil)
        #expect(tokens.saves.first == .some(nil))
        try await Self.completeSCRAM(server, inner: Self.bound + Self.issued)
        _ = try await session.value
        #expect(await server.connections == 1)
        #expect(tokens.saved?.secret == "secret-token:fast-new")
        await client.disconnect()
        await server.stop()
    }

    @Test func anExpiredTokenIsDeletedUnsentAndAnUnofferedOneLeftUnused() async throws {
        for (token, offered, deleted) in [
            (XMPPFastToken(mechanism: "HT-SHA-256-NONE", secret: "old", expiry: Self.now), ["HT-SHA-256-NONE"], true),
            (Self.token, ["HT-SHA-256-ENDP"], false),
        ] {
            let server = try await LoopbackServer.start()
            let tokens = Tokens(token)
            let (client, _, _) = try await Self.client(server, tokens: tokens)
            let session = Task { try await Self.connect(client, server) }
            try await server.expectOpening()
            try await server.send(LoopbackServer.header + Self.features(fast: offered))
            let authenticate = try await server.next()
            #expect(authenticate.attributes["mechanism"] == "SCRAM-SHA-256")
            #expect(authenticate.child("fast", namespace: Self.fast) == nil)
            // Neither HT-SHA-256-EXPR nor -NONE is offered, so no token is asked for.
            #expect((authenticate.child("request-token", namespace: Self.fast) == nil) == (offered == ["HT-SHA-256-ENDP"]))
            #expect((tokens.saved == nil) == deleted)
            try await Self.completeSCRAM(server, inner: Self.bound)
            _ = try await session.value
            await client.disconnect()
            await server.stop()
        }
    }

    // A SASL2 client meets a server with RFC 6120 SASL only and signs in the old way; a pinned account does not.
    @Test func aServerWithoutSASL2GetsRFC6120SASLUnlessTheAccountUsedSASL2() async throws {
        let server = try await LoopbackServer.start()
        let (client, persistence, _) = try await Self.client(server)
        let session = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features(sasl2: nil))
        let auth = try await server.next()
        #expect(auth.name == "auth" && auth.attributes["mechanism"] == "SCRAM-SHA-256")
        try await server.send("<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(RFC7677.serverFirst.base64EncodedString())</challenge>")
        #expect(try await server.next().name == "response")
        try await server.sendSuccess("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(RFC7677.serverFinal.base64EncodedString())</success>")
        try await server.expectOpening()
        let legacyBind = "urn:ietf:params:xml:ns:xmpp-bind"
        try await server.send(LoopbackServer.header + "<stream:features><bind xmlns='\(legacyBind)'/><sm xmlns='\(Self.sm)'/></stream:features>")
        let bind = try await server.next()
        #expect(try await server.next().name == "enable")
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(legacyBind)'><jid>user@localhost/haus-q1</jid></bind></iq>"
                              + "<enabled xmlns='\(Self.sm)' id='s3' resume='true'/>")
        #expect(try await server.next().name == "presence")
        let connected = try await session.value
        #expect(connected.pin == XMPPAuthenticationPin(scram: true))
        #expect(await persistence.value?.streamID == "s3")
        await client.disconnect()
        await server.stop()

        let pinned = try await LoopbackServer.start()
        let (refused, _, _) = try await Self.client(pinned)
        let attempt = Task { try await Self.connect(refused, pinned, pin: XMPPAuthenticationPin(scram: true, sasl2: true)) }
        try await pinned.expectOpening()
        let mark = await pinned.mark()
        try await pinned.send(LoopbackServer.header + Self.features(sasl2: nil))
        await #expect(throws: XMPPClientError.authenticationDowngrade) { _ = try await attempt.value }
        #expect(await !pinned.written(since: mark).contains("auth"))
        await pinned.stop()
    }

    @Test func aRememberedSASL2OfferSendsTheTokenWithTheHeader() async throws {
        let server = try await LoopbackServer.start()
        let offer = try #require(SASL2Wire.offer(try Self.parsed(Self.features())))
        let profile = XMPPStreamProfile(endpoint: XMPPEndpoint(host: "127.0.0.1", port: server.port, security: .directTLS),
                                        mechanisms: ["PLAIN", "SCRAM-SHA-256"], streamManagement: true, sasl2: offer)
        let (client, _, _) = try await Self.client(server, tokens: Tokens(Self.token), profile: profile, snapshot: Self.snapshot())
        let session = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        // Read before the server wrote its features: the whole sign-in went with the header.
        let authenticate = try await server.next()
        #expect(authenticate.attributes["mechanism"] == "HT-SHA-256-NONE" && authenticate.child("resume", namespace: Self.sm) != nil)
        try await server.send(LoopbackServer.header + Self.features()
                              + Self.success(additional: Self.responder, identifier: "user@localhost",
                                             inner: "<resumed xmlns='\(Self.sm)' previd='s1' h='0'/>") + Self.postFeatures)
        _ = try await session.value
        #expect(await client.sessionResumed)
        await client.disconnect()
        await server.stop()
    }

    // A remembered SASL2 offer the server no longer makes: forgotten, and the endpoint dialled again in the plain order.
    @Test func aStaleSASL2ProfileIsRetriedInThePlainOrder() async throws {
        let server = try await LoopbackServer.start()
        let offer = XMPPSASL2Offer(mechanisms: ["SCRAM-SHA-256"], bindFeatures: [Self.sm], resumes: true, fast: [])
        let profile = XMPPStreamProfile(endpoint: XMPPEndpoint(host: "127.0.0.1", port: server.port, security: .directTLS),
                                        mechanisms: ["SCRAM-SHA-256"], streamManagement: true, sasl2: offer)
        let (client, _, profiles) = try await Self.client(server, profile: profile)
        let session = Task { try await Self.connect(client, server) }
        try await server.expectOpening()
        #expect(try await server.next().name == "authenticate")
        await server.expectReconnect()
        try await server.send(LoopbackServer.header + Self.features(fast: ["HT-SHA-256-NONE"]))
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + Self.features(fast: ["HT-SHA-256-NONE"]))
        let authenticate = try await server.next()
        #expect(authenticate.child("request-token", namespace: Self.fast) != nil)
        try await Self.completeSCRAM(server, inner: Self.bound)
        _ = try await session.value
        #expect(await server.connections == 2)
        #expect(profiles.saved?.sasl2?.fast == ["HT-SHA-256-NONE"] && profiles.saved?.refusedEarlyData == nil)
        await client.disconnect()
        await server.stop()
    }
}

// RFC 7677 §3, the exchange the client's pinned nonce reproduces.
enum RFC7677 {
    static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
    static let clientFirst = Data("n,,n=user,r=rOprNGfwEbeRWgbNEkqO".utf8)
    static let serverFirst = Data("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8)
    static let clientFinal = Data("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=".utf8)
    static let serverFinal = Data("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=".utf8)
}
