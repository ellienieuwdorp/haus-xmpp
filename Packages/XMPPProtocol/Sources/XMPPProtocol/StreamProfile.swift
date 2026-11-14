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
    /// XEP-0388 with Bind 2, when offered; nil in profiles saved before SASL2.
    public let sasl2: XMPPSASL2Offer?
    /// XEP-0440 channel binding types, sorted; nil in profiles saved before them.
    public let channelBindings: [String]?

    public init(endpoint: XMPPEndpoint, mechanisms: [String], streamManagement: Bool, refusedEarlyData: Date? = nil,
                sasl2: XMPPSASL2Offer? = nil, channelBindings: [String]? = nil) {
        self.endpoint = endpoint; self.mechanisms = mechanisms.sorted(); self.streamManagement = streamManagement
        self.refusedEarlyData = refusedEarlyData; self.sasl2 = sasl2; self.channelBindings = channelBindings?.sorted()
    }
}

/// One stream profile per account; nil forgets it.
public protocol XMPPStreamProfileStore: Sendable {
    func streamProfile(account: String) -> XMPPStreamProfile?
    func saveStreamProfile(_ profile: XMPPStreamProfile?, account: String)
}

// A remembered offer that no longer matches the features: forgotten, not held against the server.
struct StaleProfile: Error {}

// XEP-0305 quickstart. SCRAM goes ahead, never PLAIN; over SASL2 a FAST proof too, as the token is the TLS-verified
// server's own secret. The features must choose what was sent, so a stale offer never picks a weaker mechanism.
struct StreamQuickstart: Equatable {
    enum Kind: Equatable { case sasl1(SASLNegotiation.Mechanism), sasl2(XMPPSASL2Offer) }
    let kind: Kind
    let streamManagement: Bool
    let channelBinding: Bool

    // A SASL2 quickstart picks its credential once the stream is open, with the binding data and token in hand.
    init?(_ profile: XMPPStreamProfile?, endpoint: XMPPEndpoint, password: String, pin: XMPPAuthenticationPin, sasl2: Bool) {
        guard let profile, profile.endpoint == endpoint else { return nil }
        channelBinding = profile.channelBindings?.contains(ChannelBinding.type) == true
        streamManagement = profile.streamManagement
        if sasl2, let offer = profile.sasl2 {
            kind = .sasl2(offer)
            return
        }
        guard !pin.sasl2,
              let mechanism = try? SASLNegotiation.choose(offered: Set(profile.mechanisms), preparable: SASLprep.prepare(password) != nil,
                                                          pin: pin, binds: channelBinding),
              mechanism != .plain else { return nil }
        kind = .sasl1(mechanism)
    }

    var mechanism: SASLNegotiation.Mechanism? { if case .sasl1(let mechanism) = kind { mechanism } else { nil } }
}
