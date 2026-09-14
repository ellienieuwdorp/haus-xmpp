import Foundation
import Network
import Security

public enum XMPPConnectionState: Sendable, Equatable {
    case disconnected(String?)
    case connecting
    case authenticating
    case binding
    case online(jid: String)
}

public struct XMPPMessage: Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String?
    public let body: String
    /// Untrusted sender-provided identifier, scoped by the application to its provenance.
    public let originID: String?
    public let type: String?

    public init(id: String, from: String, to: String?, body: String, originID: String? = nil, type: String? = nil) {
        self.id = id; self.from = from; self.to = to; self.body = body
        self.originID = originID; self.type = type
    }
}

/// A caller-resolved direct-chat reply target plus a bounded plaintext fallback snapshot.
/// IDs must come from the original wire message, never a generated local database ID.
/// A nil ID emits only the quoted body, without structured reply/fallback metadata.
public struct XMPPReply: Sendable, Equatable {
    public let id: String?
    public let to: String
    public let body: String

    public init(id: String? = nil, to: String, body: String) {
        self.id = id; self.to = to; self.body = body
    }
}

public enum XMPPEvent: Sendable, Equatable {
    case state(XMPPConnectionState)
    case message(XMPPMessage)
}

public enum XMPPClientError: Error, Sendable {
    case invalidConfiguration, alreadyConnected, notConnected, authenticationUnavailable
    case authenticationFailed, bindingFailed, unexpectedProtocol, connectionClosed, timedOut, eventConsumerTooSlow
}

/// Early direct-TLS protocol laboratory. Does not implement OMEMO, STARTTLS, SM or MAM.
/// PLAIN is permitted only inside validated TLS. Never use this API as an encryption fallback.
public actor XMPPClient {
    public nonisolated let events: AsyncStream<XMPPEvent>
    private let continuation: AsyncStream<XMPPEvent>.Continuation
    private let labCertificateAuthority: Data?
    private var connection: NWConnection?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var phase: Phase = .idle
    private var framer = XMLStreamFramer()
    private var domain = ""
    private var username = ""
    private var password = ""
    private var bindID = ""
    private var handshake: CheckedContinuation<Void, Error>?
    private let queue = DispatchQueue(label: "xmpp.transport")
    private enum Phase { case idle, features, authentication, authenticatedFeatures, binding, online }

    /// A DER CA certificate is exclusively for the explicit local lab. System trust is the default.
    public init(labCertificateAuthority: Data? = nil) {
        self.labCertificateAuthority = labCertificateAuthority
        let pair = AsyncStream<XMPPEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = pair.stream
        continuation = pair.continuation
    }

    public func connect(host: String, port: UInt16 = 5223, domain: String, username: String, password: String) async throws {
        guard connection == nil else { throw XMPPClientError.alreadyConnected }
        guard !host.isEmpty, !domain.isEmpty, !username.isEmpty, !password.isEmpty,
              !username.contains("\0"), !password.contains("\0"), !domain.contains(where: { $0.isWhitespace }),
              let endpointPort = NWEndpoint.Port(rawValue: port) else { throw XMPPClientError.invalidConfiguration }
        self.domain = domain; self.username = username; self.password = password
        framer = XMLStreamFramer()
        phase = .features
        generation = UUID()
        let token = generation
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
        let conn = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: tls))
        connection = conn
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            await self?.timeout(token)
        }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try emit(.state(.connecting))
                try await Self.start(conn, queue: queue)
                guard generation == token, connection != nil else { throw XMPPClientError.connectionClosed }
                try await write(streamOpening())
                guard generation == token, connection != nil else { throw XMPPClientError.connectionClosed }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    handshake = continuation
                    reader = Task { [weak self] in await self?.readLoop(conn, token: token) }
                }
            } onCancel: {
                Task { await self.cancel(token) }
            }
        } catch {
            if generation == token { finish("TLS connection failed") }
            throw error
        }
    }

    public func disconnect() {
        finish(nil)
    }

    /// Completion means only that the local socket accepted the write, not server or peer delivery.
    /// Retrying an uncertain write must preserve the same caller-supplied ID.
    @discardableResult public func sendMessage(to: String, body: String, id: String = UUID().uuidString, reply: XMPPReply? = nil) async throws -> String {
        guard phase == .online else { throw XMPPClientError.notConnected }
        try await write(Self.messageXML(to: to, body: body, id: id, reply: reply))
        return id
    }

    /// Pure preflight for durable enqueueing; does not require a connected session.
    public static func validateMessage(to: String, body: String, id: String, reply: XMPPReply? = nil) throws {
        guard !to.isEmpty, to.utf8.count <= 3_071, !to.contains(where: { $0.isWhitespace }),
              !body.isEmpty, body.utf8.count <= 65_536,
              validMessageID(id), validXMLText(to), validXMLText(body) else { throw XMPPClientError.invalidConfiguration }
        if let reply {
            guard reply.id.map(validMessageID) ?? true, !reply.to.isEmpty, reply.to.utf8.count <= 3_071,
                  !reply.to.contains(where: { $0.isWhitespace }), validXMLText(reply.to),
                  !reply.body.isEmpty, reply.body.utf8.count <= 16_384, validXMLText(reply.body),
                  replyFallback(reply.body).utf8.count + body.utf8.count <= 65_536 else { throw XMPPClientError.invalidConfiguration }
        }
    }

    static func messageXML(to: String, body: String, id: String, reply: XMPPReply? = nil) throws -> String {
        try validateMessage(to: to, body: body, id: id, reply: reply)
        let escapedID = xmlEscaped(id)
        var wireBody = body
        var extensionXML = ""
        if let reply {
            let fallback = replyFallback(reply.body)
            wireBody = fallback + body
            if let replyID = reply.id {
                extensionXML = "<reply xmlns='urn:xmpp:reply:0' to='\(xmlEscaped(reply.to))' id='\(xmlEscaped(replyID))'/><fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='\(fallback.unicodeScalars.count)'/></fallback>"
            }
        }
        return "<message to='\(xmlEscaped(to))' type='chat' id='\(escapedID)'><body>\(xmlEscaped(wireBody))</body><origin-id xmlns='urn:xmpp:sid:0' id='\(escapedID)'/>\(extensionXML)</message>"
    }

    private static func replyFallback(_ body: String) -> String {
        // XML normalizes literal CR/CRLF to LF; normalize before counting fallback offsets.
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n"
    }

    private static func validMessageID(_ id: String) -> Bool {
        // Keep attribute normalization from changing a caller's durable identifier.
        !id.isEmpty && id.utf8.count <= 1_024 && !id.contains(where: { $0.isWhitespace }) && validXMLText(id)
    }

    private static func validXMLText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
            (0x10000...0x10FFFF).contains($0.value)
        }
    }

    static func parsedMessage(_ node: XMLNode) -> XMPPMessage? {
        guard node.name == "message", node.namespace == "jabber:client",
              node.attributes["type"] == nil || node.attributes["type"] == "chat" || node.attributes["type"] == "normal",
              let from = node.attributes["from"], !from.isEmpty,
              let body = node.child("body", namespace: "jabber:client")?.text, !body.isEmpty else { return nil }
        let origins = node.children.filter { $0.name == "origin-id" && $0.namespace == "urn:xmpp:sid:0" }
        // Multiple origin IDs are ambiguous; never pick one based on XML order.
        let candidate = origins.count == 1 ? origins[0].attributes["id"] : nil
        let originID = candidate.flatMap { validMessageID($0) ? $0 : nil }
        return XMPPMessage(id: node.attributes["id"] ?? UUID().uuidString, from: from,
                           to: node.attributes["to"], body: body, originID: originID, type: node.attributes["type"])
    }

    private func readLoop(_ conn: NWConnection, token: UUID) async {
        do {
            while generation == token && !Task.isCancelled {
                let data = try await Self.receive(conn)
                guard generation == token else { return }
                for frame in try framer.feed(data) {
                    guard generation == token else { return }
                    switch frame {
                    case .opened: break
                    case .closed: throw XMPPClientError.connectionClosed
                    case .element(let node): try await handle(node, token: token)
                    }
                }
            }
        } catch {
            if generation == token { finish(Self.safeDescription(error), error: error) }
        }
    }

    private func handle(_ node: XMLNode, token: UUID) async throws {
        if node.name == "error", node.namespace == "http://etherx.jabber.org/streams" { throw XMPPClientError.unexpectedProtocol }
        switch phase {
        case .features:
            guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams" else { throw XMPPClientError.unexpectedProtocol }
            let mechanisms = node.child("mechanisms", namespace: "urn:ietf:params:xml:ns:xmpp-sasl")
            guard mechanisms?.children.contains(where: { $0.name == "mechanism" && $0.namespace == "urn:ietf:params:xml:ns:xmpp-sasl" && $0.text == "PLAIN" }) == true else { throw XMPPClientError.authenticationUnavailable }
            phase = .authentication
            try emit(.state(.authenticating))
            let payload = Data(("\0" + username + "\0" + password).utf8).base64EncodedString()
            password = ""
            try await write("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>\(payload)</auth>")
        case .authentication:
            guard node.namespace == "urn:ietf:params:xml:ns:xmpp-sasl", node.name == "success" else { throw XMPPClientError.authenticationFailed }
            phase = .authenticatedFeatures
            framer = XMLStreamFramer()
            try await write(streamOpening())
        case .authenticatedFeatures:
            guard node.name == "features", node.namespace == "http://etherx.jabber.org/streams",
                  node.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind") != nil else { throw XMPPClientError.bindingFailed }
            phase = .binding
            bindID = UUID().uuidString
            try emit(.state(.binding))
            try await write("<iq type='set' id='\(bindID)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>ios-lab-\(UUID().uuidString.prefix(8))</resource></bind></iq>")
        case .binding:
            guard node.name == "iq", node.namespace == "jabber:client", node.attributes["id"] == bindID,
                  node.attributes["type"] == "result",
                  let jid = node.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind")?.child("jid", namespace: "urn:ietf:params:xml:ns:xmpp-bind")?.text, !jid.isEmpty else { throw XMPPClientError.bindingFailed }
            try await write("<presence/>")
            guard generation == token else { throw XMPPClientError.connectionClosed }
            phase = .online
            deadline?.cancel(); deadline = nil
            try emit(.state(.online(jid: jid)))
            handshake?.resume(); handshake = nil
        case .online:
            if let message = Self.parsedMessage(node) {
                try emit(.message(message))
            } else if node.name == "iq", node.namespace == "jabber:client",
                      ["get", "set"].contains(node.attributes["type"] ?? ""), let id = node.attributes["id"] {
                let to = node.attributes["from"].map { " to='\(xmlEscaped($0))'" } ?? ""
                // Respond to XEP-0199 pings; reject other unsupported requests explicitly.
                if node.child("ping", namespace: "urn:xmpp:ping") != nil {
                    try await write("<iq type='result' id='\(xmlEscaped(id))'\(to)/>")
                } else {
                    try await write("<iq type='error' id='\(xmlEscaped(id))'\(to)><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
                }
            }
        case .idle: throw XMPPClientError.unexpectedProtocol
        }
    }

    private func streamOpening() -> String { "<stream:stream to='\(xmlEscaped(domain))' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>" }
    private func emit(_ event: XMPPEvent) throws {
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped, .terminated: throw XMPPClientError.eventConsumerTooSlow
        @unknown default: throw XMPPClientError.eventConsumerTooSlow
        }
    }
    private func cancel(_ token: UUID) { if generation == token { finish(nil) } }
    private func timeout(_ token: UUID) { if generation == token && phase != .online { finish("Connection timed out", error: XMPPClientError.timedOut) } }
    private func finish(_ reason: String?, error: Error = XMPPClientError.connectionClosed) {
        generation = UUID()
        handshake?.resume(throwing: error); handshake = nil
        connection?.cancel(); connection = nil
        reader?.cancel(); reader = nil
        deadline?.cancel(); deadline = nil
        password = ""; phase = .idle
        if case .dropped = continuation.yield(.state(.disconnected(reason))) { continuation.finish() }
    }
    private func write(_ xml: String) async throws {
        try Task.checkCancellation()
        guard let connection else { throw XMPPClientError.notConnected }
        let token = generation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(xml.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        // A cancelled/replaced connection must not report a successful send to the outbox.
        guard generation == token else { throw XMPPClientError.connectionClosed }
        try Task.checkCancellation()
    }
    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? XMPPClientError.connectionClosed) }
            }
        }
    }
    private static func start(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result = ConnectionStart(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: result.finish(nil)
                case .failed(let error), .waiting(let error): result.finish(error)
                case .cancelled: result.finish(XMPPClientError.connectionClosed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    private static func safeDescription(_ error: Error) -> String {
        switch error {
        case XMPPClientError.authenticationFailed: "Authentication failed"
        case XMPPClientError.authenticationUnavailable: "Server does not offer the laboratory authentication mechanism"
        case XMPPClientError.bindingFailed: "Resource binding failed"
        case XMPPClientError.eventConsumerTooSlow: "Event consumer could not keep up"
        case is XMLStreamError: "Invalid or oversized server XML"
        default: "Connection ended"
        }
    }
}

/// NWConnection callbacks are serialized on their queue; the lock also protects cancellation delivery.
private final class ConnectionStart: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.lock(); let result = continuation; continuation = nil; lock.unlock()
        if let error { result?.resume(throwing: error) } else { result?.resume() }
    }
}
