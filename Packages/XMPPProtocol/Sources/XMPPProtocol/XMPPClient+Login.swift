import Foundation

// Sign-in from the first stream features to online: SASL, the restart, bind or resume, and the XEP-0198 enable.
extension XMPPClient {
    func handleFeatures(_ node: XMLNode) async throws {
        guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams" else { throw XMPPClientError.unexpectedProtocol }
        committed = true
        let mechanisms = node.child("mechanisms", namespace: SASLNegotiation.namespace)?.children
            .filter { $0.name == "mechanism" && $0.namespace == SASLNegotiation.namespace }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        offeredMechanisms = mechanisms
        if let quickstart {
            // The `<auth>` already sent must be what this offer chooses; anything else is a stale profile.
            let chosen = try SASLNegotiation.choose(offered: Set(mechanisms), preparable: SASLprep.prepare(password) != nil,
                                                    requireSCRAM: requireSCRAM)
            guard chosen == quickstart.mechanism else { throw StaleProfile() }
            phase = .authentication
            try emit(.state(.authenticating))
            return
        }
        let negotiation = try SASLNegotiation(offered: Set(mechanisms), username: username, password: password, requireSCRAM: requireSCRAM,
                                              nonce: scramNonce())
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
        let resumable = ["true", "1"].contains(node.attributes["resume"] ?? "false")
        let id = node.attributes["id"]
        guard !resumable || id.map(validArchiveID) == true else { throw XMPPClientError.unexpectedProtocol }
        let timeout = node.attributes["max"].flatMap(Self.smCount).map { min($0, StreamManagement.maxResumeTimeout) }
        try await streamManagement?.enable(accountID: username + "@" + domain, fullJID: boundJID,
                                           streamID: resumable ? id : nil, resumeTimeoutSeconds: resumable ? timeout : nil)
        try await becomeOnline(token: token)
    }

    func handleResumption(_ node: XMLNode, token: UUID) async throws {
        guard node.namespace == "urn:xmpp:sm:3" else { throw XMPPClientError.unexpectedProtocol }
        pipelined = false
        if node.name == "failed" {
            // A failed resume never triggers blind retransmission; MAM reconciles uncertain sends.
            resumeSnapshot = nil
            try await startBinding(resource: resource)
        } else {
            guard node.name == "resumed", let snapshot = resumeSnapshot,
                  node.attributes["previd"] == snapshot.streamID,
                  let h = Self.smCount(node.attributes["h"]), let streamManagement else { throw XMPPClientError.unexpectedProtocol }
            boundJID = JID.normalized(snapshot.fullJID) ?? snapshot.fullJID
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
    }

    func pinSCRAMNonce(_ nonce: String) { scramNonce = { nonce } }
    func pinClock(_ date: Date) { now = { date } }

    func connected(to endpoint: XMPPEndpoint) -> XMPPConnectedSession {
        password = ""
        learn(endpoint)
        return XMPPConnectedSession(endpoint: endpoint, authenticatedWithSCRAM: authenticatedWithSCRAM)
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
                                        refusedEarlyData: pipeliningAllowed ? nil : profile?.refusedEarlyData)
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
}
