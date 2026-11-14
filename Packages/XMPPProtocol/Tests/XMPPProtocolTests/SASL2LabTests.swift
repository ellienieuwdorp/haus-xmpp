import Foundation
import Testing
@testable import XMPPProtocol

// SASL2, Bind 2, inline resumption and FAST against the lab Prosody. Needs HAUS_LAB_SASL2_ACCOUNT (a disposable
// account's {"jid", "password"}) and HAUS_LAB_CA; HAUS_LAB_DIRECT_TLS_PORT defaults to 5223, and HAUS_LAB_SASL2=0 means
// the lab runs without the modules, so the same client must sign in the RFC 6120 way.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_SASL2_ACCOUNT"] != nil), .serialized)
struct SASL2LabTests {
    private struct Credentials: Decodable { let jid: String; let password: String }
    private let env = ProcessInfo.processInfo.environment
    private var offersSASL2: Bool { env["HAUS_LAB_SASL2"] != "0" }

    private func credentials() throws -> Credentials {
        try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env["HAUS_LAB_SASL2_ACCOUNT"]))))
    }

    private func certificateAuthority() throws -> Data {
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        return try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
    }

    private func connect(_ persistence: SASL2Tests.Persistence, tokens: SASL2Tests.Tokens, profiles: SASL2Tests.Profiles, clientID: UUID,
                         pin: XMPPAuthenticationPin) async throws -> (XMPPClient, XMPPConnectedSession) {
        let account = try credentials()
        let parts = account.jid.split(separator: "@").map(String.init)
        let client = XMPPClient(labCertificateAuthority: try certificateAuthority())
        try await client.configureStreamManagement(persistence: persistence)
        try await client.configureStreamProfiles(profiles)
        try await client.configureSASL2(XMPPSASL2Configuration(clientID: clientID, enablesCarbons: true, tokens: tokens))
        let session = try await client.connect(host: "localhost", port: env["HAUS_LAB_DIRECT_TLS_PORT"].flatMap(UInt16.init) ?? 5223,
                                               domain: parts[1], username: parts[0], password: account.password, pin: pin)
        return (client, session)
    }

    @Test func passwordThenBoundTokenWithInlineResumeAndAFallbackWhenTheTokenIsRefused() async throws {
        let account = try credentials()
        let persistence = SASL2Tests.Persistence(nil), tokens = SASL2Tests.Tokens(nil), profiles = SASL2Tests.Profiles(nil)
        let clientID = UUID()
        let (first, signedIn) = try await connect(persistence, tokens: tokens, profiles: profiles, clientID: clientID, pin: .none)
        let bound = try #require(await persistence.value)
        await first.disconnectAndWait()
        guard offersSASL2 else {
            #expect(signedIn.pin == XMPPAuthenticationPin(scram: true, channelBinding: true))
            #expect(tokens.saved == nil && profiles.saved?.sasl2 == nil)
            return
        }
        // SCRAM-SHA-256-PLUS over TLS 1.3, a token for HT-SHA-256-EXPR, a resource derived from the client id.
        #expect(signedIn.pin == XMPPAuthenticationPin(scram: true, sasl2: true, channelBinding: true))
        #expect(tokens.saved?.mechanism == "HT-SHA-256-EXPR")
        #expect(bound.fullJID.hasPrefix(account.jid + "/Haus~"))
        #expect(await first.carbonsEnabledInline)

        // The token and the resume go ahead with the stream header, from the remembered profile.
        let (second, resumed) = try await connect(persistence, tokens: tokens, profiles: profiles, clientID: clientID, pin: signedIn.pin)
        #expect(await second.sessionResumed)
        #expect(resumed.pin.channelBinding)
        #expect(await persistence.value?.fullJID == bound.fullJID)
        await second.disconnectAndWait()

        // A token the server does not know is deleted and the password signs in on the same stream, asking for another.
        let unknown = try #require(tokens.saved)
        tokens.saveFastToken(XMPPFastToken(mechanism: unknown.mechanism, secret: "secret-token:fast-unknown", expiry: unknown.expiry),
                             account: account.jid)
        let (third, fallback) = try await connect(persistence, tokens: tokens, profiles: profiles, clientID: clientID, pin: resumed.pin)
        #expect(await third.sessionResumed)
        #expect(fallback.authenticatedWithSCRAM)
        #expect(tokens.saved != nil && tokens.saved?.secret != "secret-token:fast-unknown")
        await third.disconnectAndWait()
    }
}
