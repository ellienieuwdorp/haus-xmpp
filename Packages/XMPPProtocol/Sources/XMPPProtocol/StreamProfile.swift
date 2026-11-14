import Foundation

/// What an account's server offered on one endpoint, read inside verified TLS on a connection that came online. The
/// next connection to that endpoint sends its first steps ahead of the features; the features still decide.
public struct XMPPStreamProfile: Sendable, Equatable, Codable {
    public let endpoint: XMPPEndpoint
    /// Offered before authentication, sorted.
    public let mechanisms: [String]
    /// XEP-0198, offered after authentication.
    public let streamManagement: Bool
    /// When the endpoint last refused what went ahead; nothing goes ahead for a week after.
    public let refusedEarlyData: Date?

    public init(endpoint: XMPPEndpoint, mechanisms: [String], streamManagement: Bool, refusedEarlyData: Date? = nil) {
        self.endpoint = endpoint; self.mechanisms = mechanisms.sorted(); self.streamManagement = streamManagement
        self.refusedEarlyData = refusedEarlyData
    }
}

/// One stream profile per account; nil forgets it.
public protocol XMPPStreamProfileStore: Sendable {
    func streamProfile(account: String) -> XMPPStreamProfile?
    func saveStreamProfile(_ profile: XMPPStreamProfile?, account: String)
}

// A remembered offer that no longer matches the features: forgotten, not held against the server.
struct StaleProfile: Error {}

// XEP-0305 quickstart: a server reads a stream in order. Only SCRAM goes ahead, so no secret precedes the features,
// and the features must choose the mechanism sent, so a remembered offer never picks a weaker one than the server's.
struct StreamQuickstart: Equatable {
    let mechanism: SASLNegotiation.Mechanism
    let streamManagement: Bool

    init?(_ profile: XMPPStreamProfile?, endpoint: XMPPEndpoint, password: String, requireSCRAM: Bool) {
        guard let profile, profile.endpoint == endpoint,
              let mechanism = try? SASLNegotiation.choose(offered: Set(profile.mechanisms), preparable: SASLprep.prepare(password) != nil,
                                                          requireSCRAM: requireSCRAM),
              mechanism != .plain else { return nil }
        self.mechanism = mechanism; streamManagement = profile.streamManagement
    }
}
