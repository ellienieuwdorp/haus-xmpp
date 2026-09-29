import CommonCrypto
import CryptoKit
import Foundation

/// One SASL exchange over RFC 6120 §6 (SASL1). Mechanisms, strongest first: SCRAM-SHA-256, SCRAM-SHA-1
/// (RFC 5802, RFC 7677), then PLAIN. Every mechanism runs only inside a verified TLS stream; PLAIN is refused
/// once the account has authenticated with SCRAM. Channel binding (-PLUS) is not implemented, so SCRAM sends
/// the GS2 flag `n` ("client does not support binding"), which a server offering -PLUS accepts.
struct SASLNegotiation {
    static let namespace = "urn:ietf:params:xml:ns:xmpp-sasl"
    enum Mechanism: String { case scramSHA256 = "SCRAM-SHA-256", scramSHA1 = "SCRAM-SHA-1", plain = "PLAIN" }

    let mechanism: Mechanism
    private var scram: SCRAM?
    /// The first message, sent with `<auth/>`: PLAIN's credentials or SCRAM's client-first.
    let initialResponse: Data

    /// Throws `authenticationDowngrade` when SCRAM is required but not offered, `authenticationUnavailable` when
    /// nothing usable is offered.
    init(offered: Set<String>, username: String, password: String, requireSCRAM: Bool, nonce: String = SCRAM.makeNonce()) throws {
        let prepared = SASLprep.prepare(password)
        let variant = [SCRAM.Variant.sha256, .sha1].first { offered.contains($0.mechanism.rawValue) }
        if let prepared, let variant {
            let scram = SCRAM(variant: variant, username: username, password: prepared, nonce: nonce)
            mechanism = variant.mechanism; self.scram = scram
            initialResponse = Data(scram.clientFirst.utf8)
        } else if requireSCRAM {
            // A password SCRAM accepted before prepares the same way again, so a missing SCRAM is the server's doing.
            throw variant == nil ? XMPPClientError.authenticationDowngrade : XMPPClientError.authenticationUnavailable
        } else if offered.contains(Mechanism.plain.rawValue) {
            mechanism = .plain
            initialResponse = Data(("\0" + username + "\0" + password).utf8)
        } else { throw XMPPClientError.authenticationUnavailable }
    }

    var usesSCRAM: Bool { scram != nil }

    /// Answers a `<challenge/>`: SCRAM's server-first, or a server-final sent as a challenge (answered empty).
    mutating func respond(to challenge: Data) throws -> Data {
        guard var scram else { throw XMPPClientError.unexpectedProtocol }
        defer { self.scram = scram }
        return try scram.respond(to: challenge)
    }

    /// `<success/>` counts only once the server has proven it knows the password: a SCRAM success without a valid
    /// server signature is a failed login, whether the signature is missing or wrong.
    mutating func complete(_ additionalData: Data) throws {
        guard var scram else { return }
        defer { self.scram = scram }
        try scram.complete(additionalData)
    }

    /// RFC 6120 §6.5. Only conditions a new password could fix stop the account; transient ones are retried.
    static func error(forFailure node: XMLNode) -> XMPPClientError {
        let condition = node.children.first { $0.namespace == namespace && $0.name != "text" }?.name
        switch condition {
        case "temporary-auth-failure", "aborted": return .authenticationRetryable
        case "invalid-mechanism", "mechanism-too-weak", "encryption-required": return .authenticationUnavailable
        // not-authorized, credentials-expired, account-disabled, invalid-authzid and anything unrecognised:
        // retrying a rejected login unattended risks a server-side lockout.
        default: return .authenticationFailed
        }
    }

    /// SASL payloads are base64; `=` is an empty response (RFC 6120 §6.4.2).
    static func decode(_ text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "=" { return Data() }
        guard let data = Data(base64Encoded: trimmed) else { throw XMPPClientError.unexpectedProtocol }
        return data
    }

    static func encode(_ data: Data) -> String { data.isEmpty ? "=" : data.base64EncodedString() }
}

/// RFC 5802 client. Hashing, HMAC and the constant-time signature check come from CryptoKit; PBKDF2 from CommonCrypto.
struct SCRAM {
    enum Variant {
        case sha256, sha1
        var mechanism: SASLNegotiation.Mechanism { self == .sha256 ? .scramSHA256 : .scramSHA1 }
    }
    /// RFC 5802 §5.1 and RFC 7677 ask servers for at least 4096; the ceiling keeps a hostile count from stalling the
    /// notification extension's budget (Prosody's default is 10,000).
    static let iterations = 4096...1_000_000
    private enum State { case awaitingServerFirst, awaitingServerFinal(authMessage: Data, serverKey: SymmetricKey), verified }

    let variant: Variant
    let clientFirst: String
    private let clientFirstBare: String
    private let nonce: String
    private var password: String
    private var state = State.awaitingServerFirst

    init(variant: Variant, username: String, password: String, nonce: String) {
        self.variant = variant; self.password = password; self.nonce = nonce
        let name = username.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
        clientFirstBare = "n=\(name),r=\(nonce)"
        clientFirst = "n,," + clientFirstBare
    }

    /// 24 random bytes; base64 contains no `,`, so it is a valid SCRAM nonce.
    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
    }

    mutating func respond(to challenge: Data) throws -> Data {
        switch state {
        case .awaitingServerFirst: return try clientFinal(serverFirst: challenge)
        case .awaitingServerFinal:
            try complete(challenge)
            return Data()
        case .verified: throw XMPPClientError.unexpectedProtocol
        }
    }

    mutating func complete(_ additionalData: Data) throws {
        switch state {
        case .awaitingServerFirst: throw XMPPClientError.authenticationFailed
        case .awaitingServerFinal(let authMessage, let serverKey):
            // `e=`, or a missing, malformed or wrong `v=`, fails the login.
            guard let message = String(data: additionalData, encoding: .utf8), message.hasPrefix("v="),
                  let signature = Data(base64Encoded: String(message.dropFirst(2).prefix { $0 != "," })),
                  verify(signature, authMessage: authMessage, key: serverKey) else { throw XMPPClientError.authenticationFailed }
            state = .verified
        case .verified:
            guard additionalData.isEmpty else { throw XMPPClientError.unexpectedProtocol }
        }
    }

    private mutating func clientFinal(serverFirst data: Data) throws -> Data {
        // r= first (a leading m= is reserved and must fail), then s= and i=; later extensions are ignored.
        guard let serverFirst = String(data: data, encoding: .utf8) else { throw XMPPClientError.authenticationUnavailable }
        let attributes = serverFirst.split(separator: ",", omittingEmptySubsequences: false)
        guard attributes.count >= 3, attributes[0].hasPrefix("r="), attributes[1].hasPrefix("s="), attributes[2].hasPrefix("i=") else {
            throw XMPPClientError.authenticationUnavailable
        }
        let combinedNonce = String(attributes[0].dropFirst(2))
        guard combinedNonce.hasPrefix(nonce), combinedNonce.count > nonce.count,
              let salt = Data(base64Encoded: String(attributes[1].dropFirst(2))), !salt.isEmpty,
              let count = Int(attributes[2].dropFirst(2)), Self.iterations.contains(count) else { throw XMPPClientError.authenticationUnavailable }
        let salted = try saltedPassword(salt: salt, iterations: count)
        password = ""
        let withoutProof = "c=biws,r=\(combinedNonce)" // biws = base64("n,,")
        let authMessage = Data("\(clientFirstBare),\(serverFirst),\(withoutProof)".utf8)
        let clientKey = mac(Data("Client Key".utf8), key: salted)
        let signature = mac(authMessage, key: SymmetricKey(data: digest(clientKey)))
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
        state = .awaitingServerFinal(authMessage: authMessage, serverKey: SymmetricKey(data: mac(Data("Server Key".utf8), key: salted)))
        return Data("\(withoutProof),p=\(proof.base64EncodedString())".utf8)
    }

    private func saltedPassword(salt: Data, iterations: Int) throws -> SymmetricKey {
        let length = variant == .sha256 ? SHA256.byteCount : Insecure.SHA1.byteCount
        let prf = CCPseudoRandomAlgorithm(variant == .sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1)
        let secret = Data(password.utf8)
        var output = Data(count: length)
        let status = output.withUnsafeMutableBytes { out in
            secret.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count, prf, UInt32(iterations),
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw XMPPClientError.authenticationUnavailable }
        return SymmetricKey(data: output)
    }

    private func mac(_ data: Data, key: SymmetricKey) -> Data {
        variant == .sha256 ? Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
                           : Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
    }
    private func digest(_ data: Data) -> Data {
        variant == .sha256 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data))
    }
    /// CryptoKit compares in constant time.
    private func verify(_ signature: Data, authMessage: Data, key: SymmetricKey) -> Bool {
        variant == .sha256 ? HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: authMessage, using: key)
                           : HMAC<Insecure.SHA1>.isValidAuthenticationCode(signature, authenticating: authMessage, using: key)
    }
}

/// RFC 4013 SASLprep of a password, as far as Foundation can do it faithfully: the B.1 and C.1.2 mappings, NFKC and
/// the C.1.2–C.9 prohibitions. Limits: there is no bidirectional-text table, so any right-to-left script returns nil,
/// and NFKC uses the system's Unicode version rather than 3.2. nil means "cannot prepare": the caller uses PLAIN, which
/// the server prepares, unless the account requires SCRAM. Printable ASCII is returned unchanged.
enum SASLprep {
    static func prepare(_ password: String) -> String? {
        if password.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) { return password }
        var mapped = String.UnicodeScalarView()
        for scalar in password.unicodeScalars where !mapsToNothing(scalar.value) {
            mapped.append(nonASCIISpace(scalar.value) ? " " : scalar)
        }
        let normalized = String(mapped).precomposedStringWithCompatibilityMapping
        guard !normalized.isEmpty, !normalized.unicodeScalars.contains(where: { prohibited($0.value) || rightToLeft($0.value) }) else { return nil }
        return normalized
    }

    private static func mapsToNothing(_ v: UInt32) -> Bool { // RFC 3454 B.1
        [0x00AD, 0x034F, 0x1806, 0x2060, 0xFEFF].contains(v) || (0x180B...0x180D).contains(v)
            || (0x200B...0x200D).contains(v) || (0xFE00...0xFE0F).contains(v)
    }
    private static func nonASCIISpace(_ v: UInt32) -> Bool { // C.1.2
        [0x00A0, 0x1680, 0x202F, 0x205F, 0x3000].contains(v) || (0x2000...0x200B).contains(v)
    }
    private static func prohibited(_ v: UInt32) -> Bool {
        if nonASCIISpace(v) || v < 0x20 || (0x7F...0x9F).contains(v) { return true } // C.1.2, C.2.1, C.2.2 controls
        if [0x06DD, 0x070F, 0x180E, 0x200C, 0x200D, 0x2028, 0x2029, 0xFEFF, 0xE0001].contains(v) { return true } // C.2.2, C.9
        let ranges: [ClosedRange<UInt32>] = [0x2060...0x2063, 0x206A...0x206F, 0xFFF9...0xFFFD, 0x1D173...0x1D17A, // C.2.2, C.6
            0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD, // C.3
            0xFDD0...0xFDEF, // C.4
            0x2FF0...0x2FFB, // C.7
            0x0340...0x0341, 0x200E...0x200F, 0x202A...0x202E, // C.8
            0xE0020...0xE007F] // C.9
        return ranges.contains { $0.contains(v) } || (v & 0xFFFE) == 0xFFFE // C.4, the last two code points of every plane
    }
    private static func rightToLeft(_ v: UInt32) -> Bool {
        let ranges: [ClosedRange<UInt32>] = [0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFE, 0x10800...0x10FFF, 0x1E800...0x1EFFF]
        return ranges.contains { $0.contains(v) }
    }
}
