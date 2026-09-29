import Foundation
import Testing
@testable import XMPPProtocol

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
private func data(_ text: String) -> Data { Data(text.utf8) }

/// RFC 5802 §5 (SCRAM-SHA-1) and RFC 7677 §3 (SCRAM-SHA-256) example exchanges.
private struct Vector {
    let offered: String, nonce: String, serverFirst: String, clientFinal: String, serverFinal: String
    static let sha1 = Vector(offered: "SCRAM-SHA-1", nonce: "fyko+d2lbbFgONRv9qkxdawL",
        serverFirst: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096",
        clientFinal: "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=",
        serverFinal: "v=rmF9pqV8S7suAoZWja4dJRkFsKQ=")
    static let sha256 = Vector(offered: "SCRAM-SHA-256", nonce: "rOprNGfwEbeRWgbNEkqO",
        serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        clientFinal: "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")

    func negotiation() throws -> SASLNegotiation {
        try SASLNegotiation(offered: [offered, "PLAIN"], username: "user", password: "pencil", requireSCRAM: false, nonce: nonce)
    }
}

@Test(arguments: [Vector.sha1, Vector.sha256])
private func scramMatchesTheRFCExchange(_ vector: Vector) throws {
    var sasl = try vector.negotiation()
    #expect(sasl.mechanism.rawValue == vector.offered)
    #expect(text(sasl.initialResponse) == "n,,n=user,r=\(vector.nonce)")
    #expect(text(try sasl.respond(to: data(vector.serverFirst))) == vector.clientFinal)
    try sasl.complete(data(vector.serverFinal))
    // A server that delivers the server-final as a challenge gets an empty response, then an empty success.
    var viaChallenge = try vector.negotiation()
    _ = try viaChallenge.respond(to: data(vector.serverFirst))
    #expect(try viaChallenge.respond(to: data(vector.serverFinal)).isEmpty)
    try viaChallenge.complete(Data())
}

@Test(arguments: ["", "v=rmF9pqV8S7suAoZWja4dJRkFsKQ", "v=AAAApqV8S7suAoZWja4dJRkFsKQ=", "e=invalid-proof", "v="])
private func successWithoutTheServerSignatureIsAFailedLogin(_ serverFinal: String) throws {
    var sasl = try Vector.sha1.negotiation()
    _ = try sasl.respond(to: data(Vector.sha1.serverFirst))
    #expect(throws: XMPPClientError.authenticationFailed) { try sasl.complete(data(serverFinal)) }
}

@Test(arguments: [
    "r=someoneelse3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096", // nonce does not extend ours
    "r=fyko+d2lbbFgONRv9qkxdawL,s=QSXCR+Q6sek8bf92,i=4096", // nothing added by the server
    "m=ext,r=fyko+d2lbbFgONRv9qkxdawL3rfc,s=QSXCR+Q6sek8bf92,i=4096", // reserved mandatory extension
    "r=fyko+d2lbbFgONRv9qkxdawL3rfc,s=QSXCR+Q6sek8bf92,i=1024", // too few iterations
    "r=fyko+d2lbbFgONRv9qkxdawL3rfc,s=QSXCR+Q6sek8bf92,i=4000000", // enough to stall the extension
    "r=fyko+d2lbbFgONRv9qkxdawL3rfc,i=4096,s=QSXCR+Q6sek8bf92", // attribute order
])
private func rejectsUnsafeServerFirstMessages(_ serverFirst: String) throws {
    var sasl = try Vector.sha1.negotiation()
    #expect(throws: XMPPClientError.authenticationUnavailable) { try sasl.respond(to: data(serverFirst)) }
}

@Test func choosesTheStrongestMechanismAndRefusesADowngrade() throws {
    let cases: [(Set<String>, String, Bool, Result<String, XMPPClientError>)] = [
        (["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-256-PLUS"], "pencil", false, .success("SCRAM-SHA-256")),
        (["PLAIN", "SCRAM-SHA-1"], "pencil", false, .success("SCRAM-SHA-1")),
        (["PLAIN"], "pencil", false, .success("PLAIN")),
        (["PLAIN"], "pencil", true, .failure(.authenticationDowngrade)),
        (["PLAIN", "SCRAM-SHA-256-PLUS"], "pencil", true, .failure(.authenticationDowngrade)),
        (["SCRAM-SHA-1", "SCRAM-SHA-256"], "pencil", true, .success("SCRAM-SHA-256")),
        (["DIGEST-MD5"], "pencil", false, .failure(.authenticationUnavailable)),
        // A password SASLprep cannot prepare here is left to the server, never sent through SCRAM unprepared.
        (["PLAIN", "SCRAM-SHA-256"], "\u{05D0}\u{05D1}", false, .success("PLAIN")),
        (["PLAIN", "SCRAM-SHA-256"], "\u{05D0}\u{05D1}", true, .failure(.authenticationUnavailable)),
    ]
    for (offered, password, requireSCRAM, expected) in cases {
        let chosen = Result { try SASLNegotiation(offered: offered, username: "user", password: password, requireSCRAM: requireSCRAM).mechanism.rawValue }
            .mapError { $0 as! XMPPClientError }
        #expect(chosen == expected, "\(offered) required: \(requireSCRAM)")
    }
}

@Test func onlyCredentialConditionsStopTheAccount() {
    let cases: [(String, XMPPClientError)] = [
        ("not-authorized", .authenticationFailed), ("credentials-expired", .authenticationFailed),
        ("account-disabled", .authenticationFailed), ("invalid-authzid", .authenticationFailed),
        ("temporary-auth-failure", .authenticationRetryable), ("aborted", .authenticationRetryable),
        ("mechanism-too-weak", .authenticationUnavailable), ("invalid-mechanism", .authenticationUnavailable),
        ("some-future-condition", .authenticationFailed),
    ]
    for (condition, expected) in cases {
        let failure = XMLNode(name: "failure", namespace: SASLNegotiation.namespace, attributes: [:], children: [
            XMLNode(name: "text", namespace: SASLNegotiation.namespace, attributes: [:], text: "Try again later"),
            XMLNode(name: condition, namespace: SASLNegotiation.namespace, attributes: [:])])
        #expect(SASLNegotiation.error(forFailure: failure) == expected, "\(condition)")
    }
}

/// RFC 4013 §3 examples, plus this implementation's documented limit for right-to-left text.
@Test func saslprepMapsNormalizesAndProhibits() {
    let cases: [(String, String?)] = [
        ("user", "user"), ("I\u{00AD}X", "IX"), ("\u{00AA}", "a"), ("\u{2168}", "IX"),
        ("pass\u{00A0}word", "pass word"), ("pässwörd 🔑", "pässwörd 🔑"),
        ("\u{0007}", nil), ("tab\there", nil), ("\u{E000}", nil), ("\u{0627}\u{0031}", nil), ("\u{0627}", nil),
    ]
    for (input, expected) in cases { #expect(SASLprep.prepare(input) == expected, "\(input.unicodeScalars.map { String($0.value, radix: 16) })") }
}
