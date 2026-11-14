import Foundation

/// A XEP-0484 FAST token: a credential equal to a password for this account and client. Its description never shows
/// the secret, so logging one by accident leaks nothing.
public struct XMPPFastToken: Sendable, Equatable, Codable, CustomStringConvertible {
    /// The HT mechanism the server bound it to.
    public let mechanism: String
    public let secret: String
    public let expiry: Date

    public init(mechanism: String, secret: String, expiry: Date) {
        self.mechanism = mechanism; self.secret = secret; self.expiry = expiry
    }

    public var description: String { "FAST token (\(mechanism), expires \(expiry.formatted(.iso8601)))" }
}

/// One FAST token per account, kept only where the account's password is kept; nil deletes it.
public protocol XMPPFastTokenStore: Sendable {
    func fastToken(account: String) -> XMPPFastToken?
    func saveFastToken(_ token: XMPPFastToken?, account: String)
}

/// SASL2 (XEP-0388) with Bind 2 (XEP-0386), XEP-0198 inside it and FAST (XEP-0484). Without it the client uses RFC 6120
/// SASL only.
public struct XMPPSASL2Configuration: Sendable {
    /// The XEP-0388 `<user-agent>` id, a UUID v4 kept per installation and account. A Bind 2 server derives the
    /// resource from it, and FAST tokens are issued to it.
    public let clientID: UUID
    public let software: String
    /// The XEP-0386 `<tag>`, the readable start of the resource the server assigns.
    public let tag: String
    /// XEP-0280 carbons on a fresh Bind 2 session, without a separate request.
    public let enablesCarbons: Bool
    /// Where FAST tokens live; nil uses none.
    public let tokens: (any XMPPFastTokenStore)?

    public init(clientID: UUID, software: String = "Haus XMPP", tag: String = "Haus", enablesCarbons: Bool,
                tokens: (any XMPPFastTokenStore)?) {
        self.clientID = clientID; self.software = software; self.tag = tag; self.enablesCarbons = enablesCarbons; self.tokens = tokens
    }
}

/// What a server offered for SASL2 on one endpoint, read before authentication.
public struct XMPPSASL2Offer: Sendable, Equatable, Codable {
    public let mechanisms: [String]
    /// XEP-0386 inline features (`urn:xmpp:sm:3`, `urn:xmpp:carbons:2`, `urn:xmpp:csi:0`).
    public let bindFeatures: [String]
    /// XEP-0198 resumption inside `<authenticate>`.
    public let resumes: Bool
    /// XEP-0484 mechanisms.
    public let fast: [String]

    public init(mechanisms: [String], bindFeatures: [String], resumes: Bool, fast: [String]) {
        self.mechanisms = mechanisms.sorted(); self.bindFeatures = bindFeatures.sorted(); self.resumes = resumes; self.fast = fast.sorted()
    }
}

enum SASL2Wire {
    static let namespace = "urn:xmpp:sasl:2"
    static let bindNamespace = "urn:xmpp:bind:0"
    static let fastNamespace = "urn:xmpp:fast:0"
    static let smNamespace = "urn:xmpp:sm:3"
    static let carbonsNamespace = "urn:xmpp:carbons:2"
    static let csiNamespace = "urn:xmpp:csi:0"

    // SASL2 counts only with Bind 2: this client never binds the RFC 6120 way after a SASL2 success.
    static func offer(_ features: XMLNode) -> XMPPSASL2Offer? {
        guard let authentication = features.child("authentication", namespace: namespace) else { return nil }
        let mechanisms = authentication.children.filter { $0.name == "mechanism" && $0.namespace == namespace }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let inline = authentication.child("inline", namespace: namespace)
        guard !mechanisms.isEmpty, let bind = inline?.child("bind", namespace: bindNamespace) else { return nil }
        let bindFeatures = bind.child("inline", namespace: bindNamespace)?.children
            .filter { $0.name == "feature" && $0.namespace == bindNamespace }.compactMap { $0.attributes["var"] } ?? []
        let fast = inline?.child("fast", namespace: fastNamespace)?.children
            .filter { $0.name == "mechanism" && $0.namespace == fastNamespace }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        return XMPPSASL2Offer(mechanisms: mechanisms, bindFeatures: bindFeatures, resumes: inline?.child("sm", namespace: smNamespace) != nil,
                              fast: fast)
    }

    struct Authenticate {
        var mechanism: String
        var initialResponse: Data
        var clientID: UUID
        var software: String
        var tag: String
        var usesToken = false
        var requestsToken: String?
        var resume: String?
        var enablesStreamManagement = false
        var enablesCarbons = false

        var xml: String {
            var parts = ["<initial-response>\(SASLNegotiation.encode(initialResponse))</initial-response>",
                         "<user-agent id='\(clientID.uuidString.lowercased())'><software>\(xmlEscaped(software))</software></user-agent>"]
            if usesToken { parts.append("<fast xmlns='\(fastNamespace)'/>") }
            if let requestsToken { parts.append("<request-token xmlns='\(fastNamespace)' mechanism='\(xmlEscaped(requestsToken))'/>") }
            if let resume { parts.append(resume) }
            var bind = "<tag>\(xmlEscaped(tag))</tag>"
            if enablesStreamManagement { bind += "<enable xmlns='\(smNamespace)' resume='true'/>" }
            if enablesCarbons { bind += "<enable xmlns='\(carbonsNamespace)'/>" }
            parts.append("<bind xmlns='\(bindNamespace)'>\(bind)</bind>")
            return "<authenticate xmlns='\(namespace)' mechanism='\(xmlEscaped(mechanism))'>\(parts.joined())</authenticate>"
        }
    }

    static func response(_ data: Data) -> String { "<response xmlns='\(namespace)'>\(SASLNegotiation.encode(data))</response>" }

    // XEP-0484 `<token/>` in a `<success/>`; one without a usable secret or expiry is ignored.
    static func token(in success: XMLNode, mechanism: String) -> XMPPFastToken? {
        guard let token = success.child("token", namespace: fastNamespace), let secret = token.attributes["token"], !secret.isEmpty,
              secret.utf8.count <= 4_096, let expiry = token.attributes["expiry"].flatMap(Self.date) else { return nil }
        return XMPPFastToken(mechanism: mechanism, secret: secret, expiry: expiry)
    }

    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}
