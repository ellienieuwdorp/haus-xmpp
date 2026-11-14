import Foundation
import Testing
@testable import XMPPProtocol

// RFC 9266 `tls-exporter` in SCRAM-PLUS and HT-SHA-256-EXPR, and the channel binding pin. Fixed vectors use the bytes
// 0…31 as binding data and were computed with Python's hashlib and hmac; the loopback tests check that the client binds
// to the exporter the server reads from its own end of the TLS 1.3 connection.
@Suite(.serialized)
struct ChannelBindingTests {
    static let binding = ChannelBinding(data: Data(0..<32))

    @Test func scramPlusMatchesAnIndependentComputation() throws {
        var sasl = try SASLNegotiation(offered: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"], username: "user", password: "pencil", pin: .none,
                                       channelBinding: Self.binding, nonce: RFC7677.clientNonce)
        #expect(sasl.mechanism == .scramSHA256Plus)
        #expect(String(decoding: sasl.initialResponse, as: UTF8.self) == "p=tls-exporter,,n=user,r=\(RFC7677.clientNonce)")
        let final = String(decoding: try sasl.respond(to: RFC7677.serverFirst), as: UTF8.self)
        #expect(final == "c=cD10bHMtZXhwb3J0ZXIsLAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f,"
                + "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=QC6CS20quADQRb3mT99YUH+n3VJxUvzuK0K0E1Vrs2M=")
        try sasl.complete(Data("v=2GiAgapEppLVlUXbxUDksL3VgYHzuqiK5tR4mhJGgvs=".utf8))
    }

    @Test func boundTokenProofsMatchAnIndependentComputation() throws {
        let token = XMPPFastToken(mechanism: "HT-SHA-256-EXPR", secret: "secret-token:fast-bound", expiry: SASL2Tests.now)
        let hashed = try #require(HashedToken(token: token, username: "user", channelBinding: Self.binding))
        let initiator = try #require(Data(base64Encoded: "FqZGpHJn6ekS1pkvoowCadDS/NnshHeDcKnun56j5nk="))
        #expect(hashed.initialResponse == Data("user".utf8) + Data([0]) + initiator)
        try hashed.verify(try #require(Data(base64Encoded: "vbEf3rueoTZXLRl/oSt3q1oqXZdGLVQwrCyz5E0E6pE=")))
        #expect(throws: XMPPClientError.authenticationFailed) { try hashed.verify(initiator) }
        // A bound token never signs in without binding data.
        #expect(HashedToken(token: token, username: "user", channelBinding: nil) == nil)
    }

    // With `tls-exporter` listed, SCRAM binds to this connection and a token is asked for HT-SHA-256-EXPR.
    @Test func aListedExporterBindsSCRAMToTheConnection() async throws {
        let server = try await LoopbackServer.start()
        let tokens = SASL2Tests.Tokens(nil)
        let (client, _, _) = try await SASL2Tests.client(server, tokens: tokens)
        let session = Task { try await SASL2Tests.connect(client, server) }
        try await server.expectOpening()
        let binding = try #require(await server.channelBinding())
        try await server.send(LoopbackServer.header + SASL2Tests.features(sasl2: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"],
                                                                          fast: ["HT-SHA-256-EXPR", "HT-SHA-256-NONE"], bindings: ["tls-exporter"]))
        let authenticate = try await server.next()
        #expect(authenticate.attributes["mechanism"] == "SCRAM-SHA-256-PLUS")
        #expect(authenticate.child("request-token", namespace: SASL2Tests.fast)?.attributes["mechanism"] == "HT-SHA-256-EXPR")
        try await server.send(SASL2Tests.challenge())
        let final = String(decoding: Data(base64Encoded: try await server.next().text) ?? Data(), as: UTF8.self)
        #expect(final.hasPrefix("c=\((Data("p=tls-exporter,,".utf8) + binding).base64EncodedString()),r="))
        // Prosody accepting this proof is the lab's to show (SASL2LabTests); here the server refuses it.
        try await server.send("<failure xmlns='\(SASL2Tests.sasl2)'><not-authorized xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>")
        await #expect(throws: XMPPClientError.authenticationFailed) { _ = try await session.value }
        await server.stop()
    }

    // A bound token signs in with the server's exporter for this connection and pins the account to binding.
    @Test func aBoundTokenSignsInAndPinsTheAccount() async throws {
        let server = try await LoopbackServer.start()
        let token = XMPPFastToken(mechanism: "HT-SHA-256-EXPR", secret: "secret-token:fast-bound", expiry: SASL2Tests.now.addingTimeInterval(60))
        let (client, _, _) = try await SASL2Tests.client(server, tokens: SASL2Tests.Tokens(token))
        let session = Task { try await SASL2Tests.connect(client, server, pin: XMPPAuthenticationPin(scram: true, sasl2: true)) }
        try await server.expectOpening()
        let binding = ChannelBinding(data: try #require(await server.channelBinding()))
        try await server.send(LoopbackServer.header + SASL2Tests.features(sasl2: ["SCRAM-SHA-256-PLUS"], fast: ["HT-SHA-256-EXPR"],
                                                                          bindings: ["tls-exporter"]))
        let authenticate = try await server.next()
        #expect(authenticate.attributes["mechanism"] == "HT-SHA-256-EXPR")
        let expected = try #require(HashedToken(token: token, username: "user", channelBinding: binding))
        #expect(Data(base64Encoded: authenticate.child("initial-response", namespace: SASL2Tests.sasl2)?.text ?? "") == expected.initialResponse)
        let proof = try #require(Self.responderProof(token, binding))
        try await server.send(SASL2Tests.success(additional: proof, inner: SASL2Tests.bound) + SASL2Tests.postFeatures)
        #expect(try await session.value.pin == XMPPAuthenticationPin(scram: true, sasl2: true, channelBinding: true))
        await client.disconnect()
        await server.stop()
    }

    // Pinned to channel binding, an offer without `tls-exporter` is a downgrade: no SCRAM without binding, no unbound token.
    @Test func aChannelBindingPinRefusesAnUnboundOffer() async throws {
        let server = try await LoopbackServer.start()
        let (client, _, _) = try await SASL2Tests.client(server, tokens: SASL2Tests.Tokens(SASL2Tests.token))
        let attempt = Task { try await SASL2Tests.connect(client, server, pin: XMPPAuthenticationPin(scram: true, sasl2: true, channelBinding: true)) }
        try await server.expectOpening()
        try await server.send(LoopbackServer.header + SASL2Tests.features(sasl2: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]))
        await #expect(throws: XMPPClientError.authenticationDowngrade) { _ = try await attempt.value }
        await server.stop()
    }

    @Test func pinsOnlyEverTurnOnAndChooseTheBindingMechanisms() throws {
        let pinned = XMPPAuthenticationPin(scram: true).union(XMPPAuthenticationPin(sasl2: true, channelBinding: true))
        #expect(pinned == XMPPAuthenticationPin(scram: true, sasl2: true, channelBinding: true))
        let all: Set<String> = ["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-1-PLUS", "SCRAM-SHA-256-PLUS"]
        #expect(try SASLNegotiation.choose(offered: all, preparable: true, pin: .none, binds: true) == .scramSHA256Plus)
        #expect(try SASLNegotiation.choose(offered: ["SCRAM-SHA-1-PLUS", "SCRAM-SHA-256"], preparable: true, pin: .none, binds: true) == .scramSHA1Plus)
        #expect(try SASLNegotiation.choose(offered: all, preparable: true, pin: .none, binds: false) == .scramSHA256)
        #expect(throws: XMPPClientError.authenticationDowngrade) {
            try SASLNegotiation.choose(offered: all, preparable: true, pin: XMPPAuthenticationPin(channelBinding: true), binds: false)
        }
        #expect(throws: XMPPClientError.authenticationUnavailable) {
            try SASLNegotiation.choose(offered: all, preparable: false, pin: XMPPAuthenticationPin(channelBinding: true), binds: true)
        }
    }

    @Test func aTokensDescriptionNeverShowsTheSecret() {
        #expect(!"\(SASL2Tests.token)".contains(SASL2Tests.token.secret))
        #expect(!String(reflecting: SASL2Tests.token).contains(SASL2Tests.token.secret))
    }

    // The server's side of the HMAC, whose arithmetic the fixed vector above pins.
    private static func responderProof(_ token: XMPPFastToken, _ binding: ChannelBinding) -> Data? {
        let server = HashedToken(token: XMPPFastToken(mechanism: "HT-SHA-256-EXPR", secret: token.secret, expiry: token.expiry),
                                 username: "user", channelBinding: binding)
        return server?.responderProof
    }
}
