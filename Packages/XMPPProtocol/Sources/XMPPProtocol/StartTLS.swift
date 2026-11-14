import Foundation
import Network
import Security

// Both modes verify TLS the same way: the account domain as SNI and service identity, TLS 1.2 or later, system trust
// (or only the explicit lab CA).
enum XMPPTransport {
    static func parameters(for security: XMPPTransportSecurity, domain: String, startTLSAhead: Bool = false, labCertificateAuthority: Data?,
                           queue: DispatchQueue) -> NWParameters {
        let tls = tlsOptions(domain: domain, labCertificateAuthority: labCertificateAuthority, queue: queue)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 30; tcp.keepaliveInterval = 10; tcp.keepaliveCount = 3
        switch security {
        case .directTLS:
            // XEP-0368: lets a server sharing 443 with HTTPS route the connection.
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "xmpp-client")
            return NWParameters(tls: tls, tcp: tcp)
        case .startTLS:
            let parameters = NWParameters(tls: nil, tcp: tcp)
            let framer = NWProtocolFramer.Options(definition: StartTLSFramer.definition)
            framer[StartTLSFramer.domainKey] = domain
            framer[StartTLSFramer.tlsKey] = tls
            framer[StartTLSFramer.aheadKey] = startTLSAhead
            parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
            return parameters
        }
    }

    static func tlsOptions(domain: String, labCertificateAuthority: Data?, queue: DispatchQueue) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, domain)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let certificateData = labCertificateAuthority
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            // XMPP service identity is the account domain, not an SRV/IP transport endpoint.
            guard SecTrustSetPolicies(trustRef, SecPolicyCreateSSL(true, domain as CFString)) == errSecSuccess else { complete(false); return }
            if let certificateData {
                guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
                      SecTrustSetAnchorCertificates(trustRef, [certificate] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trustRef, true) == errSecSuccess else { complete(false); return }
            }
            complete(SecTrustEvaluateWithError(trustRef, nil))
        }, queue)
        return tls
    }

    static let startTLSRefused = NWError.posix(.EPROTONOSUPPORT)

    // RFC 9266: 32 bytes exported under "EXPORTER-Channel-Binding" with an empty context, TLS 1.3 only (TLS 1.2 would
    // need the extended master secret, which the metadata cannot confirm).
    static func channelBinding(_ connection: NWConnection) -> ChannelBinding? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let metadata = tls.securityProtocolMetadata
        guard sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata) == .TLSv13 else { return nil }
        let label = "EXPORTER-Channel-Binding"
        guard let secret = label.withCString({ sec_protocol_metadata_create_secret(metadata, label.utf8.count, $0, 32) }) else { return nil }
        let data = Data(secret as DispatchData)
        return data.count == 32 ? ChannelBinding(data: data) : nil
    }
}

// RFC 6120 §5 as a framer (`nw_framer_prepend_application_protocol`): it negotiates in plaintext while the connection
// prepares, then adds TLS above itself, so `.ready` follows the handshake and the client never sees a plaintext byte.
// Fails closed on anything but `<proceed/>`; bytes after it in the same read are an injection attempt.
final class StartTLSFramer: NWProtocolFramerImplementation {
    static let label = "XMPP STARTTLS"
    static let definition = NWProtocolFramer.Definition(implementation: StartTLSFramer.self)
    static let domainKey = "domain", tlsKey = "tls", aheadKey = "ahead"
    private static let tlsNamespace = "urn:ietf:params:xml:ns:xmpp-tls"
    private static let startTLS = "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
    private var parser = XMLStreamFramer(maximumBytes: 65_536)
    private var awaitingProceed = false
    private var sentStartTLS = false
    // Set once TLS is prepended or the connection failed; no further plaintext is read.
    private var finished = false

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let domain = framer.options[Self.domainKey] as? String else {
            framer.markFailed(error: .posix(.EINVAL)); return .willMarkReady
        }
        var opening = "<?xml version='1.0'?><stream:stream to='\(xmlEscaped(domain))' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"
        // Written ahead, `<starttls/>` is read after the server sent its features, which must still offer it.
        if framer.options[Self.aheadKey] as? Bool == true {
            opening += Self.startTLS
            sentStartTLS = true
        }
        framer.writeOutput(data: Data(opening.utf8))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while !finished {
            var chunk = Data()
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65_536) { buffer, _ in
                guard let buffer, !buffer.isEmpty else { return 0 }
                chunk = Data(buffer)
                return buffer.count
            }
            guard parsed, !chunk.isEmpty else { return 0 }
            do { try negotiate(chunk, framer: framer) }
            catch {
                finished = true
                framer.markFailed(error: error as? NWError ?? .posix(.EBADMSG))
            }
        }
        return 0
    }

    private func negotiate(_ chunk: Data, framer: NWProtocolFramer.Instance) throws {
        let frames = try parser.feed(chunk)
        for (index, frame) in frames.enumerated() {
            guard case .element(let node) = frame else {
                if frame == .opened { continue }
                throw NWError.posix(.EBADMSG)
            }
            if !awaitingProceed {
                // Pre-TLS features are unauthenticated: only the offer of STARTTLS is read from them.
                guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams" else { throw NWError.posix(.EBADMSG) }
                guard node.child("starttls", namespace: Self.tlsNamespace) != nil else { throw XMPPTransport.startTLSRefused }
                awaitingProceed = true
                if !sentStartTLS { framer.writeOutput(data: Data(Self.startTLS.utf8)) }
                continue
            }
            guard node.namespace == Self.tlsNamespace else { throw NWError.posix(.EBADMSG) }
            guard node.name == "proceed" else { throw XMPPTransport.startTLSRefused }
            guard index == frames.count - 1, !parser.hasBufferedInput else { throw NWError.posix(.EBADMSG) }
            guard let tls = framer.options[Self.tlsKey] as? NWProtocolTLS.Options else { throw NWError.posix(.EINVAL) }
            try framer.prependApplicationProtocol(options: tls)
            finished = true
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
            return
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        // `passThroughOutput` takes over once TLS is in place, so this is application data before TLS: never send it.
        framer.markFailed(error: .posix(.EBADMSG))
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
