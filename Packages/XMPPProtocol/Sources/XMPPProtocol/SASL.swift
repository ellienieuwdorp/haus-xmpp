import CommonCrypto
import CryptoKit
import Foundation

/// What an account's earlier sign-ins proved its server offers; a stream that offers less is a downgrade and gets no
/// credential. Each part only ever turns on, and signing out lifts it.
public struct XMPPAuthenticationPin: Sendable, Equatable, Codable {
    /// SCRAM succeeded: PLAIN is refused.
    public var scram: Bool
    /// XEP-0388 SASL2 with XEP-0386 Bind 2 succeeded: a stream without them is refused.
    public var sasl2: Bool
    /// `tls-exporter` channel binding (RFC 9266, TLS 1.3) succeeded: only a mechanism that binds is used.
    public var channelBinding: Bool

    public init(scram: Bool = false, sasl2: Bool = false, channelBinding: Bool = false) {
        self.scram = scram; self.sasl2 = sasl2; self.channelBinding = channelBinding
    }

    public static let none = XMPPAuthenticationPin()

    public func union(_ other: XMPPAuthenticationPin) -> XMPPAuthenticationPin {
        XMPPAuthenticationPin(scram: scram || other.scram, sasl2: sasl2 || other.sasl2, channelBinding: channelBinding || other.channelBinding)
    }
}

// RFC 9266 `tls-exporter`, used only when the server lists it (XEP-0440).
struct ChannelBinding: Equatable {
    static let type = "tls-exporter"
    static let namespace = "urn:xmpp:sasl-cb:0"
    let data: Data

    static func offered(_ features: XMLNode) -> [String] {
        features.child("sasl-channel-binding", namespace: namespace)?.children
            .filter { $0.name == "channel-binding" && $0.namespace == namespace }.compactMap { $0.attributes["type"] }.sorted() ?? []
    }
}

// RFC 6120 §6 and XEP-0388, strongest first: SCRAM-SHA-256-PLUS, SCRAM-SHA-1-PLUS, SCRAM-SHA-256, SCRAM-SHA-1, PLAIN,
// only inside verified TLS. Unbound SCRAM sends GS2 flag `n` (cannot bind here), which a server offering -PLUS accepts.
struct SASLNegotiation {
    static let namespace = "urn:ietf:params:xml:ns:xmpp-sasl"
    enum Mechanism: String {
        case scramSHA256Plus = "SCRAM-SHA-256-PLUS", scramSHA1Plus = "SCRAM-SHA-1-PLUS"
        case scramSHA256 = "SCRAM-SHA-256", scramSHA1 = "SCRAM-SHA-1", plain = "PLAIN"
        var binds: Bool { self == .scramSHA256Plus || self == .scramSHA1Plus }
    }

    let mechanism: Mechanism
    private var scram: SCRAM?
    // PLAIN's credentials or SCRAM's client-first.
    let initialResponse: Data

    init(offered: Set<String>, username: String, password: String, pin: XMPPAuthenticationPin, channelBinding: ChannelBinding? = nil,
         nonce: String = SCRAM.makeNonce()) throws {
        let prepared = SASLprep.prepare(password)
        mechanism = try Self.choose(offered: offered, preparable: prepared != nil, pin: pin, binds: channelBinding != nil)
        switch mechanism {
        case .scramSHA256Plus, .scramSHA1Plus, .scramSHA256, .scramSHA1:
            let variant: SCRAM.Variant = mechanism == .scramSHA256 || mechanism == .scramSHA256Plus ? .sha256 : .sha1
            let scram = SCRAM(variant: variant, username: username, password: prepared ?? "", nonce: nonce,
                              channelBinding: mechanism.binds ? channelBinding : nil)
            self.scram = scram
            initialResponse = Data(scram.clientFirst.utf8)
        case .plain:
            initialResponse = Data(("\0" + username + "\0" + password).utf8)
        }
    }

    // The one rule for every offer, the server's or a remembered one.
    static func choose(offered: Set<String>, preparable: Bool, pin: XMPPAuthenticationPin, binds: Bool) throws -> Mechanism {
        let order: [Mechanism] = (binds ? [.scramSHA256Plus, .scramSHA1Plus] : []) + (pin.channelBinding ? [] : [.scramSHA256, .scramSHA1])
        let best = order.first { offered.contains($0.rawValue) }
        if preparable, let best { return best }
        // A password SCRAM accepted before prepares the same way again, so a missing SCRAM is the server's doing.
        if pin.scram || pin.channelBinding { throw best == nil ? XMPPClientError.authenticationDowngrade : XMPPClientError.authenticationUnavailable }
        if offered.contains(Mechanism.plain.rawValue) { return .plain }
        throw XMPPClientError.authenticationUnavailable
    }

    var usesSCRAM: Bool { scram != nil }

    // A server-final sent as a challenge is answered empty.
    mutating func respond(to challenge: Data) throws -> Data {
        guard var scram else { throw XMPPClientError.unexpectedProtocol }
        defer { self.scram = scram }
        return try scram.respond(to: challenge)
    }

    // A SCRAM success without a valid server signature is a failed login.
    mutating func complete(_ additionalData: Data) throws {
        guard var scram else { return }
        defer { self.scram = scram }
        try scram.complete(additionalData)
    }

    // RFC 6120 §6.5: only conditions a new password could fix stop the account; transient ones are retried.
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

    // `=` is an empty response (RFC 6120 §6.4.2).
    static func decode(_ text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "=" { return Data() }
        guard let data = Data(base64Encoded: trimmed) else { throw XMPPClientError.unexpectedProtocol }
        return data
    }

    static func encode(_ data: Data) -> String { data.isEmpty ? "=" : data.base64EncodedString() }
}

// RFC 5802. Hashing, HMAC and constant-time comparison from CryptoKit; PBKDF2 from CommonCrypto.
struct SCRAM {
    enum Variant { case sha256, sha1 }
    // RFC 5802 §5.1 and RFC 7677 ask for at least 4096; the ceiling keeps a hostile count from stalling the
    // notification extension (Prosody's default is 10,000).
    static let iterations = 4096...1_000_000
    private enum State { case awaitingServerFirst, awaitingServerFinal(authMessage: Data, serverKey: SymmetricKey), verified }

    let variant: Variant
    let clientFirst: String
    private let clientFirstBare: String
    private let channelBindingInput: Data
    private let nonce: String
    private var password: String
    private var state = State.awaitingServerFirst

    init(variant: Variant, username: String, password: String, nonce: String, channelBinding: ChannelBinding? = nil) {
        self.variant = variant; self.password = password; self.nonce = nonce
        let name = username.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
        let header = channelBinding == nil ? "n,," : "p=\(ChannelBinding.type),,"
        clientFirstBare = "n=\(name),r=\(nonce)"
        clientFirst = header + clientFirstBare
        channelBindingInput = Data(header.utf8) + (channelBinding?.data ?? Data())
    }

    // Base64 contains no `,`, so this is a valid SCRAM nonce.
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
        // r= first (a leading m= must fail), then s= and i=; extensions are ignored. A violation is the server's fault:
        // nothing is sent and the login fails.
        guard let serverFirst = String(data: data, encoding: .utf8) else { throw XMPPClientError.unexpectedProtocol }
        let attributes = serverFirst.split(separator: ",", omittingEmptySubsequences: false)
        guard attributes.count >= 3, attributes[0].hasPrefix("r="), attributes[1].hasPrefix("s="), attributes[2].hasPrefix("i=") else {
            throw XMPPClientError.unexpectedProtocol
        }
        let combinedNonce = String(attributes[0].dropFirst(2))
        guard combinedNonce.hasPrefix(nonce), combinedNonce.count > nonce.count,
              let salt = Data(base64Encoded: String(attributes[1].dropFirst(2))), !salt.isEmpty,
              let count = Int(attributes[2].dropFirst(2)), Self.iterations.contains(count) else { throw XMPPClientError.unexpectedProtocol }
        let salted = try saltedPassword(salt: salt, iterations: count)
        password = ""
        let withoutProof = "c=\(channelBindingInput.base64EncodedString()),r=\(combinedNonce)"
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
    private func verify(_ signature: Data, authMessage: Data, key: SymmetricKey) -> Bool {
        variant == .sha256 ? HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: authMessage, using: key)
                           : HMAC<Insecure.SHA1>.isValidAuthenticationCode(signature, authenticating: authMessage, using: key)
    }
}

// RFC 4013 SASLprep as far as Foundation allows: B.1 and C.1.2 mappings, NFKC, C.1.2–C.9 prohibitions. Without a
// bidi table any right-to-left script gives nil, and NFKC uses the system's Unicode, not 3.2. nil means the caller
// uses PLAIN (the server prepares it) unless SCRAM is required.
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

// draft-schmaus-kitten-sasl-ht-09 for XEP-0484: identity, NUL, HMAC-SHA-256(token, "Initiator" ‖ binding data); the
// server answers with "Responder". EXPR binds to `tls-exporter`, NONE to nothing.
struct HashedToken {
    static let bound = "HT-SHA-256-EXPR", unbound = "HT-SHA-256-NONE"

    let mechanism: String
    let initialResponse: Data
    private let key: SymmetricKey
    private let channelBinding: Data

    init?(token: XMPPFastToken, username: String, channelBinding: ChannelBinding?) {
        switch token.mechanism {
        case Self.bound: guard let channelBinding else { return nil }; self.channelBinding = channelBinding.data
        case Self.unbound: self.channelBinding = Data()
        default: return nil
        }
        mechanism = token.mechanism
        key = SymmetricKey(data: Data(token.secret.utf8))
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data("Initiator".utf8) + self.channelBinding, using: key))
        initialResponse = Data(username.utf8) + Data([0]) + proof
    }

    var responderProof: Data { Data(HMAC<SHA256>.authenticationCode(for: Data("Responder".utf8) + channelBinding, using: key)) }

    func verify(_ additionalData: Data) throws {
        guard HMAC<SHA256>.isValidAuthenticationCode(additionalData, authenticating: Data("Responder".utf8) + channelBinding, using: key) else {
            throw XMPPClientError.authenticationFailed
        }
    }
}
