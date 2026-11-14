import Foundation

/// What a successful `connect` used; the caller remembers both for the next connection.
public struct XMPPConnectedSession: Sendable, Equatable {
    public let endpoint: XMPPEndpoint
    public let authenticatedWithSCRAM: Bool
    /// The pin the account had, with what this sign-in proved added.
    public let pin: XMPPAuthenticationPin

    public init(endpoint: XMPPEndpoint, authenticatedWithSCRAM: Bool, pin: XMPPAuthenticationPin? = nil) {
        self.endpoint = endpoint; self.authenticatedWithSCRAM = authenticatedWithSCRAM
        self.pin = pin ?? XMPPAuthenticationPin(scram: authenticatedWithSCRAM)
    }
}

// Sign-in from the first stream features to online: SASL, the restart, bind or resume, and the XEP-0198 enable.
extension XMPPClient {
    func handleFeatures(_ node: XMLNode) async throws {
        guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams" else { throw XMPPClientError.unexpectedProtocol }
        committed = true
        let mechanisms = node.child("mechanisms", namespace: SASLNegotiation.namespace)?.children
            .filter { $0.name == "mechanism" && $0.namespace == SASLNegotiation.namespace }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        offeredMechanisms = mechanisms
        signIn.channelBindings = ChannelBinding.offered(node)
        signIn.offer = SASL2Wire.offer(node)
        let offer = signIn.configuration == nil ? nil : signIn.offer
        if let quickstart {
            // What already went ahead must be what this offer chooses; anything else is a stale profile.
            switch quickstart.kind {
            case .sasl1(let sent):
                let chosen = try SASLNegotiation.choose(offered: Set(mechanisms), preparable: SASLprep.prepare(password) != nil,
                                                        pin: pin, binds: bindsChannel)
                guard chosen == sent else { throw StaleProfile() }
                phase = .authentication
            case .sasl2:
                guard let offer, let sent = signIn.attempt,
                      try makeSASL2Attempt(offer: offer, binds: bindsChannel).request.shape == sent.request.shape else { throw StaleProfile() }
                phase = .sasl2
            }
            try emit(.state(.authenticating))
            return
        }
        if let offer {
            let attempt = try makeSASL2Attempt(offer: offer, binds: bindsChannel)
            signIn.attempt = attempt
            phase = .sasl2
            try emit(.state(.authenticating))
            try await write(attempt.request.xml)
            return
        }
        // Only a server that lists Bind 2 counts as offering SASL2.
        if pin.sasl2 { throw XMPPClientError.authenticationDowngrade }
        let negotiation = try SASLNegotiation(offered: Set(mechanisms), username: username, password: password, pin: pin,
                                              channelBinding: bindsChannel ? signIn.channelBinding : nil, nonce: scramNonce())
        sasl = negotiation
        phase = .authentication
        try emit(.state(.authenticating))
        try await write(Self.authXML(negotiation))
    }

    func handleSASL(_ node: XMLNode) async throws {
        guard node.namespace == SASLNegotiation.namespace, var negotiation = sasl else { throw XMPPClientError.unexpectedProtocol }
        switch node.name {
        case "challenge":
            let response = try negotiation.respond(to: SASLNegotiation.decode(node.text))
            sasl = negotiation
            try await write("<response xmlns='\(SASLNegotiation.namespace)'>\(response.base64EncodedString())</response>")
        case "success":
            try negotiation.complete(SASLNegotiation.decode(node.text))
            sasl = nil
            authenticatedWithSCRAM = negotiation.usesSCRAM
            signIn.achievedPin = XMPPAuthenticationPin(scram: negotiation.usesSCRAM, channelBinding: negotiation.mechanism.binds)
            phase = .authenticatedFeatures
            framer = XMLStreamFramer()
            try await writeTogether([streamOpening()] + afterRestart())
        case "failure": throw SASLNegotiation.error(forFailure: node)
        default: throw XMPPClientError.unexpectedProtocol
        }
    }

    func handleAuthenticatedFeatures(_ node: XMLNode) async throws {
        guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams",
              node.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind") != nil else { throw XMPPClientError.bindingFailed }
        smOffered = node.child("sm", namespace: "urn:xmpp:sm:3") != nil
        csiOffered = node.child("csi", namespace: PushNotifications.clientStateNamespace) != nil
        switch restartAhead {
        case .resume:
            guard smOffered else { throw StaleProfile() }
            phase = .resumingSM
        case .bind(let enable):
            guard smOffered || !enable else { throw StaleProfile() }
            phase = .binding
            try emit(.state(.binding))
        case nil:
            if smOffered, let xml = resumeXML() {
                phase = .resumingSM
                try await write(xml)
            } else { try await startBinding(resource: resource) }
        }
    }

    func handleBinding(_ node: XMLNode, token: UUID) async throws {
        if earlyEnables > 0, node.namespace == "urn:xmpp:sm:3", node.name == "failed" { earlyEnables -= 1; return }
        if node.name == "iq", node.namespace == "jabber:client", node.attributes["id"] == bindID,
           node.attributes["type"] == "error", !bindRetried {
            // RFC 6120 §7.7.2: a conflict or refused resource. Let the server pick one rather than fail the
            // session.
            bindRetried = true
            try await startBinding(resource: nil)
            return
        }
        let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"
        guard node.name == "iq", node.namespace == "jabber:client", node.attributes["id"] == bindID,
              node.attributes["type"] == "result", let jid = node.child("bind", namespace: bindNamespace)?.child("jid", namespace: bindNamespace)?.text,
              !jid.isEmpty else { throw XMPPClientError.bindingFailed }
        // The server picks the resource and the canonical spelling, never another account (RFC 6120 §7.7).
        guard let bound = JID(jid), bound.localpart != nil, bound.resourcepart != nil,
              bound.bare == JID.normalizedBare(username + "@" + domain) else { throw XMPPIdentityError.boundAccountMismatch }
        boundJID = bound.full
        if smOffered, streamManagement != nil {
            phase = .enablingSM
            if earlyEnables == 0 { try await write(Self.enableXML) }
        } else { try await becomeOnline(token: token) }
    }

    func handleEnabled(_ node: XMLNode, token: UUID) async throws {
        // The resource is stable, so the server may route to it before `<enabled/>`. Those stanzas are uncounted by
        // the server and dropped here; archives cover them.
        if node.namespace == "jabber:client", ["message", "presence", "iq"].contains(node.name) { return }
        if earlyEnables > 0, node.namespace == "urn:xmpp:sm:3", node.name == "failed" {
            earlyEnables -= 1
            if earlyEnables == 0 { try await write(Self.enableXML) }
            return
        }
        guard node.namespace == "urn:xmpp:sm:3", node.name == "enabled" else { throw XMPPClientError.unexpectedProtocol }
        pipelined = false; earlyEnables = 0
        try await enableStreamManagement(node)
        try await becomeOnline(token: token)
    }

    // An `<enabled/>`, in order or inside Bind 2's `<bound/>`.
    func enableStreamManagement(_ node: XMLNode) async throws {
        let resumable = ["true", "1"].contains(node.attributes["resume"] ?? "false")
        let id = node.attributes["id"]
        guard !resumable || id.map(validArchiveID) == true else { throw XMPPClientError.unexpectedProtocol }
        let timeout = node.attributes["max"].flatMap(Self.smCount).map { min($0, StreamManagement.maxResumeTimeout) }
        try await streamManagement?.enable(accountID: username + "@" + domain, fullJID: boundJID,
                                           streamID: resumable ? id : nil, resumeTimeoutSeconds: resumable ? timeout : nil)
    }

    func handleResumption(_ node: XMLNode, token: UUID) async throws {
        guard node.namespace == "urn:xmpp:sm:3" else { throw XMPPClientError.unexpectedProtocol }
        pipelined = false
        if node.name == "failed" {
            // A failed resume never triggers blind retransmission; MAM reconciles uncertain sends.
            resumeSnapshot = nil
            try await startBinding(resource: resource)
        } else {
            guard node.name == "resumed" else { throw XMPPClientError.unexpectedProtocol }
            try await resume(node, token: token)
        }
    }

    // A `<resumed/>`, in order or inside SASL2's `<success/>`.
    func resume(_ node: XMLNode, token: UUID) async throws {
        guard let snapshot = resumeSnapshot, node.attributes["previd"] == snapshot.streamID,
              let h = Self.smCount(node.attributes["h"]), let streamManagement else { throw XMPPClientError.unexpectedProtocol }
        boundJID = JID.normalized(snapshot.fullJID) ?? snapshot.fullJID
        restoreGroupRooms(from: snapshot)
        let replay = try await acknowledge(h, resumed: true, streamManagement)
        try emit(.streamAcknowledged)
        guard try await streamManagement.permitsReplay() else { throw XMPPStreamManagementError.invalidState }
        // IQs are never replayed: their continuations failed on disconnect and setup re-runs.
        for entry in replay {
            guard entry.kind != .iq, let xml = entry.xml else { continue }
            try await rawWrite(xml, expectedGeneration: token)
        }
        try await becomeOnline(token: token, resumed: true)
    }

    func pinSCRAMNonce(_ nonce: String) { scramNonce = { nonce } }
    func pinClock(_ date: Date) { now = { date } }

    func connected(to endpoint: XMPPEndpoint) -> XMPPConnectedSession {
        password = ""
        learn(endpoint)
        return XMPPConnectedSession(endpoint: endpoint, authenticatedWithSCRAM: authenticatedWithSCRAM, pin: pin.union(signIn.achievedPin))
    }

    // The endpoint once more when an attempt that sent ahead failed, with nothing sent ahead from then on.
    func retrying(_ failure: CandidateFailure, _ endpoint: XMPPEndpoint) -> [XMPPEndpoint] {
        guard failure.retryWithoutPipelining, pipeliningAllowed else { return [] }
        pipeliningAllowed = false
        return [endpoint]
    }

    // A server that refused early data within the week gets the plain order.
    func loadProfile() {
        profile = profiles?.streamProfile(account: username + "@" + domain)
        pipeliningAllowed = profile?.refusedEarlyData.map { now().timeIntervalSince($0) >= Self.plainOrderAfterRefusal } ?? true
    }

    static let plainOrderAfterRefusal: TimeInterval = 7 * 24 * 60 * 60

    // The server answered what went ahead wrongly or not at all; the features are learned again in the plain order.
    func refuseEarlyData() {
        guard let attemptEndpoint else { return }
        profile = XMPPStreamProfile(endpoint: attemptEndpoint, mechanisms: [], streamManagement: false, refusedEarlyData: now())
        profiles?.saveStreamProfile(profile, account: username + "@" + domain)
    }

    func forgetProfile() {
        guard profile != nil else { return }
        profile = nil
        profiles?.saveStreamProfile(nil, account: username + "@" + domain)
    }

    func learn(_ endpoint: XMPPEndpoint) {
        let learned = XMPPStreamProfile(endpoint: endpoint, mechanisms: offeredMechanisms, streamManagement: smOffered,
                                        refusedEarlyData: pipeliningAllowed ? nil : profile?.refusedEarlyData, sasl2: signIn.offer,
                                        channelBindings: signIn.channelBindings.isEmpty ? nil : signIn.channelBindings)
        guard learned != profile else { return }
        profile = learned
        profiles?.saveStreamProfile(learned, account: username + "@" + domain)
    }

    // nil asks the server to assign a resource. With stream management offered, `<enable/>` rides behind the bind: the
    // server reads it once the resource is bound (XEP-0198 §3 only asks that it follow binding).
    func startBinding(resource: String?) async throws {
        phase = .binding
        try emit(.state(.binding))
        let enableAhead = pipeliningAllowed && smOffered && streamManagement != nil
        if enableAhead { pipelined = true; earlyEnables += 1 }
        try await writeTogether([bindXML(resource: resource)] + (enableAhead ? [Self.enableXML] : []))
    }

    func bindXML(resource: String?) -> String {
        bindID = UUID().uuidString
        let requested = resource.map { "<resource>\(xmlEscaped($0))</resource>" } ?? ""
        return "<iq type='set' id='\(bindID)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\(requested)</bind></iq>"
    }

    // No `max`: Prosody ignores it and other servers cap it anyway.
    static let enableXML = "<enable xmlns='urn:xmpp:sm:3' resume='true'/>"

    static func authXML(_ negotiation: SASLNegotiation) -> String {
        "<auth xmlns='\(SASLNegotiation.namespace)' mechanism='\(negotiation.mechanism.rawValue)'>\(SASLNegotiation.encode(negotiation.initialResponse))</auth>"
    }

    func resumeXML() -> String? {
        guard streamManagement != nil, let snapshot = resumeSnapshot, let id = snapshot.streamID else { return nil }
        return "<resume xmlns='urn:xmpp:sm:3' previd='\(xmlEscaped(id))' h='\(UInt32(truncatingIfNeeded: snapshot.inboundHandled))'/>"
    }

    // With a profile, what the restarted stream's features lead to goes behind its header; the features still check it.
    func afterRestart() -> [String] {
        guard let quickstart, pipeliningAllowed else { return [] }
        let streamManagement = quickstart.streamManagement && self.streamManagement != nil
        if streamManagement, let xml = resumeXML() {
            restartAhead = .resume
            return [xml]
        }
        restartAhead = .bind(enable: streamManagement)
        if streamManagement { earlyEnables += 1 }
        return [bindXML(resource: resource)] + (streamManagement ? [Self.enableXML] : [])
    }

    // Elements written in one send, before stream management counts anything, so none is journaled.
    func writeTogether(_ elements: [String]) async throws {
        let token = generation
        await writeGate.enter()
        do {
            try await rawWrite(elements.joined(), expectedGeneration: token)
            await writeGate.leave()
        } catch { await writeGate.leave(); throw error }
    }

    /// `haus-` and 16 random hex digits: nothing about the user or device.
    public static func makeResource() -> String {
        "haus-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }

    public static func validResource(_ resource: String) -> Bool {
        (1...64).contains(resource.utf8.count) && resource.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
