import Foundation
import Network
@preconcurrency import Security
@testable import XMPPProtocol

/// A one-connection XMPP server on loopback TLS that a test drives stanza by stanza, so `XMPPClient`'s own
/// socket, parser and state machine run unchanged. The certificate is made per test process by the system's
/// `openssl` for `localhost` and lives only in memory; clients trust it as their lab authority.
actor LoopbackServer {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let domain = "localhost"
    /// Made once per test process; SecIdentity is immutable.
    private nonisolated(unsafe) static let credentials = Result { try makeIdentity() }

    nonisolated let port: UInt16
    nonisolated let certificate: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private var connection: NWConnection?
    private var framer = XMLStreamFramer()
    private var frames: [XMLStreamFrame] = []
    private var restartPending = false
    private var ended = false

    static func start() async throws -> LoopbackServer {
        let (identity, certificate) = try credentials.get()
        let tls = NWProtocolTLS.Options()
        guard let local = sec_identity_create(identity) else { throw Failure(description: "no TLS identity") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = Once(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): once.resume(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: DispatchQueue(label: "loopback-listener"))
        }
        let server = LoopbackServer(listener: listener, port: port, certificate: certificate)
        listener.newConnectionHandler = { connection in Task { await server.adopt(connection) } }
        return server
    }

    private init(listener: NWListener, port: UInt16, certificate: Data) {
        self.listener = listener; self.port = port; self.certificate = certificate
    }

    /// A client configured for this server's certificate.
    nonisolated func client() -> XMPPClient { XMPPClient(labCertificateAuthority: certificate) }

    nonisolated func connect(_ client: XMPPClient) async throws {
        try await client.connect(host: "127.0.0.1", port: port, domain: Self.domain, username: "alice", password: "loopback")
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func adopt(_ connection: NWConnection) {
        guard self.connection == nil else { connection.cancel(); return }
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    private nonisolated func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            let finished = complete || error != nil
            Task {
                await self.ingest(data ?? Data(), ended: finished)
                if !finished { self.receive(on: connection) }
            }
        }
    }

    private func ingest(_ data: Data, ended: Bool) {
        if !data.isEmpty {
            // The client restarts the stream only after it read `<success/>`, so its next bytes open a new one.
            if restartPending { framer = XMLStreamFramer(); restartPending = false }
            do { frames += try framer.feed(data) } catch { self.ended = true }
        }
        if ended { self.ended = true }
    }

    func send(_ xml: String) async throws {
        guard let connection else { throw Failure(description: "no connection") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(xml.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// The next frame from the client; throws when none arrives in time or the connection ended first.
    private func nextFrame(within limit: Duration) async throws -> XMLStreamFrame {
        let deadline = ContinuousClock.now + limit
        while frames.isEmpty {
            guard !ended else { throw Failure(description: "connection ended") }
            guard ContinuousClock.now < deadline else { throw Failure(description: "nothing received") }
            try await Task.sleep(for: .milliseconds(5))
        }
        return frames.removeFirst()
    }

    func next(within limit: Duration = .seconds(5)) async throws -> XMPPProtocol.XMLNode {
        guard case .element(let node) = try await nextFrame(within: limit) else { throw Failure(description: "expected a stanza") }
        return node
    }

    /// Everything the client writes until it closes the connection, answering its pings on the way.
    func remainder(within limit: Duration = .seconds(5)) async throws -> [XMPPProtocol.XMLNode] {
        var nodes: [XMPPProtocol.XMLNode] = []
        while true {
            let frame: XMLStreamFrame
            do { frame = try await nextFrame(within: limit) } catch { if ended { return nodes }; throw error }
            guard case .element(let node) = frame else { continue }
            nodes.append(node)
            if node.name == "iq", node.child("ping", namespace: "urn:xmpp:ping") != nil, let id = node.attributes["id"] {
                try await send("<iq type='result' id='\(id)'/>")
            }
        }
    }

    /// Stream opening, SASL PLAIN and the restarted stream, ending with the post-authentication features.
    func authenticate(features: String = "<sm xmlns='urn:xmpp:sm:3'/><csi xmlns='urn:xmpp:csi:0'/>") async throws {
        guard try await nextFrame(within: .seconds(5)) == .opened else { throw Failure(description: "expected the stream") }
        try await send(Self.header + "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms></stream:features>")
        guard try await next().name == "auth" else { throw Failure(description: "expected auth") }
        restartPending = true
        try await send("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        guard try await nextFrame(within: .seconds(5)) == .opened else { throw Failure(description: "expected the restarted stream") }
        try await send(Self.header + "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\(features)</stream:features>")
    }

    private static var header: String {
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' id='\(UUID().uuidString)' from='\(domain)' version='1.0'>"
    }

    private static func makeIdentity() throws -> (SecIdentity, Data) {
        guard #available(macOS 15, iOS 18, *) else { throw Failure(description: "needs in-memory PKCS #12 import") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func openssl(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure(description: "openssl \(arguments[0]) failed") }
        }
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem",
                     "-out", "cert.pem", "-days", "2", "-subj", "/CN=\(domain)", "-addext", "subjectAltName=DNS:\(domain)",
                     "-addext", "extendedKeyUsage=serverAuth"])
        try openssl(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12", "-passout", "pass:loopback"])
        let bundle = try Data(contentsOf: directory.appending(path: "identity.p12"))
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "loopback", kSecImportToMemoryOnly as String: true] as CFDictionary
        guard SecPKCS12Import(bundle as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first, let value = first[kSecImportItemIdentity as String] else {
            throw Failure(description: "identity import failed")
        }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw Failure(description: "no certificate") }
        return (identity, SecCertificateCopyData(certificate) as Data)
    }
}

private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func resume(_ result: Result<Value, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
