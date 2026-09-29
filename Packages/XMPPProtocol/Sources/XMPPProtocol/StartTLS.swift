import Foundation
import Network
import Security

/// Transport parameters for either security mode. Both use the same TLS verification: the account domain as SNI and
/// service identity, TLS 1.2 or later, system trust (or only the explicit lab CA).
enum XMPPTransport {
    static func parameters(for security: XMPPTransportSecurity, domain: String, labCertificateAuthority: Data?, queue: DispatchQueue) -> NWParameters {
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

    /// How the framer reports a server that does not offer, or refuses, STARTTLS.
    static let startTLSRefused = NWError.posix(.EPROTONOSUPPORT)
}

/// RFC 6120 §5 as a Network.framework framer, in the pattern `nw_framer_prepend_application_protocol` documents:
/// the framer runs the plaintext negotiation itself while the connection is still preparing, then adds TLS above
/// itself and marks ready. The connection reports `.ready` only after the TLS handshake, so the client sees
/// exactly what direct TLS gives it and never reads or writes a plaintext byte.
///
/// Fail closed: features without `<starttls/>`, `<failure/>`, a stream error or any other element fails the
/// connection. Nothing except the stream header and `<starttls/>` is sent before TLS. Bytes that follow `<proceed/>`
/// in the same read are an injection attempt and fail the connection; later ones reach TLS as garbage and fail the
/// handshake. Each framer instance (Happy Eyeballs may race several) keeps its own state.
final class StartTLSFramer: NWProtocolFramerImplementation {
    static let label = "XMPP STARTTLS"
    static let definition = NWProtocolFramer.Definition(implementation: StartTLSFramer.self)
    static let domainKey = "domain", tlsKey = "tls"
    private static let tlsNamespace = "urn:ietf:params:xml:ns:xmpp-tls"
    private var parser = XMLStreamFramer(maximumBytes: 65_536)
    private var awaitingProceed = false
    /// Set once TLS is prepended or the connection failed; no further plaintext is read.
    private var finished = false

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let domain = framer.options[Self.domainKey] as? String else {
            framer.markFailed(error: .posix(.EINVAL)); return .willMarkReady
        }
        framer.writeOutput(data: Data("<?xml version='1.0'?><stream:stream to='\(xmlEscaped(domain))' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>".utf8))
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
                framer.writeOutput(data: Data("<starttls xmlns='\(Self.tlsNamespace)'/>".utf8))
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
