import Foundation
#if canImport(os)
import os
#endif

// One connection attempt's sign-in state; a new attempt keeps only the configuration.
struct SASL2Login {
    var configuration: XMPPSASL2Configuration?
    var attempt: SASL2Attempt?
    var offer: XMPPSASL2Offer?
    var channelBindings: [String] = []
    // Nil on TLS 1.2 or a stack that does not expose the exporter.
    var channelBinding: ChannelBinding?
    var achievedPin = XMPPAuthenticationPin.none
    // The `<features/>` after a SASL2 `<success/>`, which Prosody sends after replaying a resumed session's stanzas.
    var awaitingFeatures = false
    var carbonsEnabled = false
}

// One SASL2 `<authenticate>` and the credential answering for it.
struct SASL2Attempt {
    enum Credential {
        case password(SASLNegotiation)
        case token(HashedToken)
    }
    var credential: Credential
    let request: SASL2Wire.Authenticate
}

extension SASL2Wire.Authenticate {
    struct Shape: Equatable {
        let mechanism: String, usesToken: Bool, requestsToken: String?, resumes: Bool, enablesStreamManagement: Bool, enablesCarbons: Bool
    }
    var shape: Shape {
        Shape(mechanism: mechanism, usesToken: usesToken, requestsToken: requestsToken, resumes: resume != nil,
              enablesStreamManagement: enablesStreamManagement, enablesCarbons: enablesCarbons)
    }
}

// XEP-0388 sign-in: one `<authenticate>` carries the credential, the XEP-0198 resume, and a Bind 2 request with
// `<enable/>` and carbons, so a resumed or bound session follows the `<success/>` with no restart.
extension XMPPClient {
    /// XEP-0280 carbons were enabled inside this stream's Bind 2 request.
    public var carbonsEnabledInline: Bool { signIn.carbonsEnabled }

    /// Both answers in one actor hop: setup that waits a hop longer misses the flight its first queries could share.
    public var onlineSession: (resumed: Bool, carbonsEnabledInline: Bool) { (sessionResumed, signIn.carbonsEnabled) }

    // Only ever written inside TLS: `from` names the account for SASL2 and FAST.
    func streamOpening() -> String {
        let from = signIn.configuration == nil ? "" : " from='\(xmlEscaped(username + "@" + domain))'"
        return "<stream:stream to='\(xmlEscaped(domain))'\(from) xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"
    }

    func takesPostAuthenticationFeatures(_ node: XMLNode) -> Bool {
        guard signIn.awaitingFeatures, phase == .online, node.name == "features", node.namespace == "http://etherx.jabber.org/streams" else { return false }
        signIn.awaitingFeatures = false
        if node.child("csi", namespace: PushNotifications.clientStateNamespace) != nil { csiOffered = true }
        return true
    }

    var bindsChannel: Bool { signIn.channelBinding != nil && signIn.channelBindings.contains(ChannelBinding.type) }

    // What goes behind the stream header, from the remembered profile; nil sends the header alone. PLAIN never goes
    // ahead, nor a SCRAM-PLUS this connection cannot bind.
    func authenticationAhead() throws -> String? {
        guard let quickstart else { return nil }
        let binds = quickstart.channelBinding && signIn.channelBinding != nil
        switch quickstart.kind {
        case .sasl1(let mechanism):
            guard !mechanism.binds || binds else { return nil }
            let negotiation = try SASLNegotiation(offered: [mechanism.rawValue], username: username, password: password, pin: pin,
                                                  channelBinding: binds ? signIn.channelBinding : nil, nonce: scramNonce())
            sasl = negotiation
            return Self.authXML(negotiation)
        case .sasl2(let offer):
            guard let attempt = try? makeSASL2Attempt(offer: offer, binds: binds) else { return nil }
            if case .password(let negotiation) = attempt.credential, negotiation.mechanism == .plain { return nil }
            signIn.attempt = attempt
            return attempt.request.xml
        }
    }

    // A saved token the offer and the pin allow goes first; otherwise the password, asking for a token.
    func makeSASL2Attempt(offer: XMPPSASL2Offer, binds: Bool, afterTokenFailure: Bool = false) throws -> SASL2Attempt {
        guard let configuration = signIn.configuration else { throw XMPPClientError.unexpectedProtocol }
        let account = username + "@" + domain, binding = binds ? signIn.channelBinding : nil
        var hashed: HashedToken?
        if !afterTokenFailure, let tokens = configuration.tokens, let saved = tokens.fastToken(account: account) {
            if saved.expiry <= now() { tokens.saveFastToken(nil, account: account) }
            else if offer.fast.contains(saved.mechanism), !pin.channelBinding || saved.mechanism == HashedToken.bound {
                hashed = HashedToken(token: saved, username: username, channelBinding: binding)
            }
        }
        let credential: SASL2Attempt.Credential
        let mechanism: String, initialResponse: Data
        if let hashed {
            credential = .token(hashed); mechanism = hashed.mechanism; initialResponse = hashed.initialResponse
        } else {
            let negotiation = try SASLNegotiation(offered: Set(offer.mechanisms), username: username, password: password, pin: pin,
                                                  channelBinding: binding, nonce: scramNonce())
            credential = .password(negotiation); mechanism = negotiation.mechanism.rawValue; initialResponse = negotiation.initialResponse
        }
        var request = SASL2Wire.Authenticate(mechanism: mechanism, initialResponse: initialResponse, clientID: configuration.clientID,
                                             software: configuration.software, tag: configuration.tag)
        request.usesToken = hashed != nil
        if hashed == nil, configuration.tokens != nil {
            let wanted = (binding != nil ? [HashedToken.bound] : []) + (pin.channelBinding ? [] : [HashedToken.unbound])
            request.requestsToken = wanted.first { offer.fast.contains($0) }
        }
        let streamManagement = streamManagement != nil
        if streamManagement, offer.resumes { request.resume = resumeXML() }
        request.enablesStreamManagement = streamManagement && offer.bindFeatures.contains(SASL2Wire.smNamespace)
        request.enablesCarbons = configuration.enablesCarbons && offer.bindFeatures.contains(SASL2Wire.carbonsNamespace)
        return SASL2Attempt(credential: credential, request: request)
    }

    func handleSASL2(_ node: XMLNode, token: UUID) async throws {
        guard node.namespace == SASL2Wire.namespace, var attempt = signIn.attempt else { throw XMPPClientError.unexpectedProtocol }
        switch node.name {
        case "challenge":
            guard case .password(var negotiation) = attempt.credential else { throw XMPPClientError.unexpectedProtocol }
            let response = try negotiation.respond(to: SASLNegotiation.decode(node.text))
            attempt.credential = .password(negotiation)
            signIn.attempt = attempt
            try await write(SASL2Wire.response(response))
        case "success": try await completeSASL2(node, attempt: attempt, token: token)
        case "failure":
            // XEP-0484 §3.4: a refused token is discarded and the password tried on the same stream, which a failure
            // leaves unauthenticated and unchanged (XEP-0388 §2.6).
            if case .token = attempt.credential, let offer = signIn.offer {
                signIn.configuration?.tokens?.saveFastToken(nil, account: username + "@" + domain)
                #if canImport(os)
                Logger(subsystem: "haus.xmpp.ios", category: "xmpp").notice("FAST token refused; signing in with the password")
                #endif
                let retry = try makeSASL2Attempt(offer: offer, binds: bindsChannel, afterTokenFailure: true)
                signIn.attempt = retry
                try await write(retry.request.xml)
                return
            }
            throw SASLNegotiation.error(forFailure: node)
        // Tasks (second factors, password changes, XEP-0480 upgrades) are never requested; a server that asks for one
        // anyway gets no answer it could use.
        case "continue": throw XMPPClientError.authenticationUnavailable
        default: throw XMPPClientError.unexpectedProtocol
        }
    }

    private func completeSASL2(_ success: XMLNode, attempt: SASL2Attempt, token: UUID) async throws {
        let additional = try success.child("additional-data", namespace: SASL2Wire.namespace).map { try SASLNegotiation.decode($0.text) } ?? Data()
        let account = username + "@" + domain
        let tokenMechanism: String?
        switch attempt.credential {
        case .password(var negotiation):
            try negotiation.complete(additional)
            authenticatedWithSCRAM = negotiation.usesSCRAM
            signIn.achievedPin = XMPPAuthenticationPin(scram: negotiation.usesSCRAM, sasl2: true, channelBinding: negotiation.mechanism.binds)
            tokenMechanism = attempt.request.requestsToken
        case .token(let hashed):
            try hashed.verify(additional)
            signIn.achievedPin = XMPPAuthenticationPin(sasl2: true, channelBinding: hashed.mechanism == HashedToken.bound)
            tokenMechanism = hashed.mechanism
        }
        signIn.attempt = nil
        // XEP-0484 §3.3: the server keeps the previous token until the new one is used.
        if let tokenMechanism, let issued = SASL2Wire.token(in: success, mechanism: tokenMechanism) {
            signIn.configuration?.tokens?.saveFastToken(issued, account: account)
        }
        guard let identifier = success.child("authorization-identifier", namespace: SASL2Wire.namespace)?.text, let identity = JID(identifier),
              identity.bare == JID.normalizedBare(account) else { throw XMPPIdentityError.boundAccountMismatch }
        let bindFeatures = signIn.offer?.bindFeatures ?? []
        csiOffered = bindFeatures.contains(SASL2Wire.csiNamespace)
        signIn.awaitingFeatures = true
        if let resumed = success.child("resumed", namespace: SASL2Wire.smNamespace) {
            guard attempt.request.resume != nil else { throw XMPPClientError.unexpectedProtocol }
            smOffered = true
            phase = .resumingSM
            try await resume(resumed, token: token)
            return
        }
        // A failed resume never triggers blind retransmission; MAM reconciles uncertain sends.
        if success.child("failed", namespace: SASL2Wire.smNamespace) != nil { resumeSnapshot = nil }
        guard success.child("bound", namespace: SASL2Wire.bindNamespace) != nil, identity.localpart != nil,
              identity.resourcepart != nil else { throw XMPPClientError.bindingFailed }
        let bound = success.child("bound", namespace: SASL2Wire.bindNamespace)
        boundJID = identity.full
        signIn.carbonsEnabled = attempt.request.enablesCarbons
        if attempt.request.enablesStreamManagement, let enabled = bound?.child("enabled", namespace: SASL2Wire.smNamespace) {
            smOffered = true
            try await enableStreamManagement(enabled)
        } else { smOffered = false }
        try await becomeOnline(token: token)
    }
}
