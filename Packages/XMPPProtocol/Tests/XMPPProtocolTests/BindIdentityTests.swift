import Foundation
import Network
import Security
import Testing
@testable import XMPPProtocol

/// RFC 6120 §7.7: the server chooses the resource and the canonical spelling of the account, never another account.
/// A scripted TLS server (generated localhost CA, PLAIN, bind) answers the client's bind with a chosen JID.
@Suite(.serialized) struct BindIdentityTests {
    @Test(arguments: [("ellie@localhost/phone", true), ("mallory@localhost/phone", false), ("localhost/phone", false)])
    func boundAccountMustBeTheOneThatSignedIn(bound: String, accepted: Bool) async throws {
        let server = try ScriptedServer(boundJID: bound)
        defer { server.stop() }
        let client = XMPPClient(labCertificateAuthority: server.certificateAuthority)
        let drain = Task { for await _ in client.events {} }
        defer { drain.cancel() }
        let port = try await server.start()
        // Signed in as typed; the server answers with its own spelling.
        let connecting = Task { try await client.connect(host: "127.0.0.1", port: port, domain: "LocalHost", username: "Ellie", password: "synthetic") }
        if accepted {
            try await connecting.value
            await client.disconnect()
        } else {
            await #expect(throws: XMPPIdentityError.boundAccountMismatch) { try await connecting.value }
        }
    }
}

/// Just enough of a server for sign-in: stream features with PLAIN, success, bind. Identity generated per run.
private final class ScriptedServer: @unchecked Sendable {
    let certificateAuthority: Data
    private let identity: SecIdentity
    private let boundJID: String
    private let queue = DispatchQueue(label: "scripted-xmpp-server")
    private var listener: NWListener?
    private var buffer = ""
    private var streams = 0

    init(boundJID: String) throws {
        self.boundJID = boundJID
        let directory = FileManager.default.temporaryDirectory.appending(path: "bind-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func openssl(_ arguments: String) throws {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/openssl")
            process.arguments = arguments.split(separator: " ").map(String.init)
            process.currentDirectoryURL = directory
            process.standardError = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n".write(to: directory.appending(path: "leaf.ext"), atomically: true, encoding: .utf8)
        try openssl("req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=bind-test-ca -keyout ca.key -out ca.pem")
        try openssl("req -newkey rsa:2048 -nodes -subj /CN=localhost -keyout leaf.key -out leaf.csr")
        try openssl("x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile leaf.ext -out leaf.pem")
        try openssl("pkcs12 -export -inkey leaf.key -in leaf.pem -passout pass:test -out leaf.p12")
        try openssl("x509 -in ca.pem -outform der -out ca.der")
        certificateAuthority = try Data(contentsOf: directory.appending(path: "ca.der"))
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: "test"]
        if #available(macOS 15, iOS 18, *) { options[kSecImportToMemoryOnly as String] = true }
        guard SecPKCS12Import(try Data(contentsOf: directory.appending(path: "leaf.p12")) as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first, let value = first[kSecImportItemIdentity as String] else { throw CocoaError(.fileReadCorruptFile) }
        identity = value as! SecIdentity
    }

    func start() async throws -> UInt16 {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        let listener = try NWListener(using: NWParameters(tls: tls), on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.receive(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0); listener.stateUpdateHandler = nil
                case .failed(let error): continuation.resume(throwing: error); listener.stateUpdateHandler = nil
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, error == nil else { return }
            if let data { buffer += String(decoding: data, as: UTF8.self); respond(connection) }
            if !done { receive(connection) }
        }
    }

    private func respond(_ connection: NWConnection) {
        func send(_ xml: String) { connection.send(content: Data(xml.utf8), completion: .contentProcessed { _ in }) }
        let header = "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='localhost' id='s\(streams)' version='1.0'>"
        if let range = buffer.range(of: "<stream:stream"), let end = buffer[range.upperBound...].firstIndex(of: ">") {
            buffer.removeSubrange(..<buffer.index(after: end))
            streams += 1
            send(header + (streams == 1
                ? "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms></stream:features>"
                : "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/></stream:features>"))
        }
        if let range = buffer.range(of: "</auth>") {
            buffer.removeSubrange(..<range.upperBound)
            send("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        }
        if let range = buffer.range(of: "</iq>"), let id = buffer.firstMatch(of: /id='([^']+)'/)?.1 {
            buffer.removeSubrange(..<range.upperBound)
            send("<iq type='result' id='\(id)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>\(boundJID)</jid></bind></iq>")
        }
    }
}
