import dnssd
import Foundation
import Network
import Testing
@testable import XMPPProtocol

private func srv(_ priority: UInt16, _ weight: UInt16, _ target: String, _ port: UInt16 = 5222) -> SRVRecord {
    SRVRecord(priority: priority, weight: weight, port: port, target: target)
}
private func plan(_ directTLS: SRVLookup, _ startTLS: SRVLookup) -> [XMPPEndpoint] {
    var random = SystemRandomNumberGenerator()
    return EndpointDiscovery.candidates(domain: "example.org", directTLS: directTLS, startTLS: startTLS, using: &random)
}

@Test func discoveryOrdersByPriorityAndPrefersDirectTLSOnTies() {
    let candidates = plan(.records([srv(20, 0, "b.example.net", 443), srv(10, 0, "a.example.net", 5223)]),
                          .records([srv(10, 0, "a.example.net", 5222), srv(5, 0, "first.example.net", 5222)]))
    #expect(candidates == [XMPPEndpoint(host: "first.example.net", port: 5222, security: .startTLS),
                           XMPPEndpoint(host: "a.example.net", port: 5223, security: .directTLS),
                           XMPPEndpoint(host: "a.example.net", port: 5222, security: .startTLS),
                           XMPPEndpoint(host: "b.example.net", port: 443, security: .directTLS)])
}

@Test func discoveryFallsBackOnlyWithoutRecordsAndHonoursDot() {
    let startTLS = XMPPEndpoint(host: "example.org", port: 5222, security: .startTLS)
    let directTLS = XMPPEndpoint(host: "example.org", port: 5223, security: .directTLS)
    let cases: [(SRVLookup, SRVLookup, [XMPPEndpoint])] = [
        (.none, .none, [startTLS, directTLS]), // RFC 6120 §3.2.2, then XEP-0368's port
        (.notOffered, .none, [startTLS]), // no direct TLS, STARTTLS undeclared
        (.none, .notOffered, []), // no client service at all
        (.notOffered, .notOffered, []),
        (.notOffered, .records([srv(0, 0, "xmpp.example.org")]), [XMPPEndpoint(host: "xmpp.example.org", port: 5222, security: .startTLS)]),
        (.records([srv(0, 0, "tls.example.org", 443)]), .none, [XMPPEndpoint(host: "tls.example.org", port: 443, security: .directTLS)]),
    ]
    for (direct, starttls, expected) in cases { #expect(plan(direct, starttls) == expected, "\(direct) \(starttls)") }
    // "." counts only when it is the whole answer.
    #expect(SRVLookup([srv(0, 0, ".")]) == .notOffered)
    #expect(SRVLookup([srv(0, 0, "."), srv(1, 0, "xmpp.example.org")]) == .records([srv(1, 0, "xmpp.example.org")]))
    #expect(SRVLookup([]) == SRVLookup.none)
}

/// RFC 2782: within a priority, the chance of going first is proportional to weight. Ignoring weights gives 50%.
@Test func discoveryHonoursWeights() {
    var heavyFirst = 0
    for _ in 0..<2_000 where plan(.none, .records([srv(0, 1, "light.example.org"), srv(0, 9, "heavy.example.org")])).first?.host == "heavy.example.org" {
        heavyFirst += 1
    }
    #expect((1_600...1_900).contains(heavyFirst))
}

@Test func srvRecordDataParsesTargetsAndRoot() {
    let target = Data([0, 5, 0, 10, 20, 102] + [4] + Array("xmpp".utf8) + [7] + Array("example".utf8) + [3] + Array("org".utf8) + [0])
    #expect(SRVRecord(rdata: target) == srv(5, 10, "xmpp.example.org", 5222))
    #expect(SRVRecord(rdata: Data([0, 0, 0, 0, 0, 0, 0]))?.target == ".")
    #expect(SRVRecord(rdata: Data([0, 0, 0, 0, 0, 0, 9, 65])) == nil)
}

/// A plaintext server on loopback that answers the client's stream header and `<starttls/>` as scripted, and
/// records every byte the client sends. Without `features` it never answers. A TLS ClientHello ends the connection.
private final class PlaintextServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.plaintext-server")
    private let lock = NSLock()
    private var bytes = Data()
    private let features: String?
    private let starttlsReply: String

    init(features: String?, starttlsReply: String = "") throws {
        self.features = features; self.starttlsReply = starttlsReply
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var received: Data { lock.withLock { bytes } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, answeredHeader: false, answeredStartTLS: false)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { continuation.resume(returning: listener.port!.rawValue) }
                if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, answeredHeader: Bool, answeredStartTLS: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            guard let data, error == nil else { connection.cancel(); return }
            let all = lock.withLock { bytes.append(data); return bytes }
            let text = String(decoding: all, as: UTF8.self)
            var header = answeredHeader, starttls = answeredStartTLS
            // TLS this server cannot speak (direct TLS, or after our reply to <starttls/>): hang up.
            if !header, data.first == 0x16 { connection.cancel(); return }
            guard let features else { receive(connection, answeredHeader: true, answeredStartTLS: true); return }
            if !header, text.contains("<stream:stream") {
                header = true
                connection.send(content: Data(("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.test' id='1' version='1.0'>" + features).utf8), completion: .idempotent)
            }
            // Whatever follows our reply to <starttls/> is TLS this server cannot speak: hang up.
            if starttls { connection.cancel(); return }
            if !starttls, text.contains("<starttls") {
                starttls = true
                connection.send(content: Data(starttlsReply.utf8), completion: .idempotent)
            }
            if complete { connection.cancel() } else { receive(connection, answeredHeader: header, answeredStartTLS: starttls) }
        }
    }

    func stop() { listener.cancel() }
}

private let sasl = "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms>"
private let starttls = "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls>"

/// RFC 6120 §5: without `<proceed/>` the connection fails and nothing but the header and `<starttls/>` was sent.
@Test(arguments: [
    ("<stream:features>\(sasl)</stream:features>", ""), // STARTTLS not offered (stripped)
    ("<stream:features>\(starttls)\(sasl)</stream:features>", "<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"),
])
private func startTLSFailsClosed(_ features: String, _ reply: String) async throws {
    let server = try PlaintextServer(features: features, starttlsReply: reply)
    let port = try await server.start()
    defer { server.stop() }
    let client = XMPPClient()
    await #expect(throws: XMPPClientError.encryptionUnavailable) {
        try await client.connect(host: "127.0.0.1", port: port, security: .startTLS, domain: "example.test", username: "alice", password: "secret-password")
    }
    let sent = String(decoding: server.received, as: UTF8.self)
    #expect(!sent.contains("<auth") && !sent.contains("secret") && !sent.contains("<presence") && !sent.contains("<iq"))
    #expect(sent.components(separatedBy: "<stream:stream").count == 2)
}

/// After `<proceed/>` the next bytes on the wire are our TLS ClientHello (content type 22) for the account domain.
/// Plaintext injected behind `<proceed/>` fails the connection before any handshake, so it can never be read as
/// post-TLS stream content. Either way nothing but the header and `<starttls/>` travels in plaintext.
@Test(arguments: [("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>", true),
                  ("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/><stream:features>\(sasl)</stream:features>", false)])
private func startTLSHandsOverToTLSOnlyOnACleanProceed(_ reply: String, _ handshakes: Bool) async throws {
    let server = try PlaintextServer(features: "<stream:features>\(starttls)</stream:features>", starttlsReply: reply)
    let port = try await server.start()
    defer { server.stop() }
    let client = XMPPClient()
    await #expect(throws: (any Error).self) {
        try await client.connect(host: "127.0.0.1", port: port, security: .startTLS, domain: "example.test", username: "alice", password: "secret-password")
    }
    let sent = server.received
    let text = String(decoding: sent, as: UTF8.self)
    #expect(!text.contains("<auth") && !text.contains("secret"))
    #expect(text.components(separatedBy: "<stream:stream").count == 2)
    let afterStartTLS = sent.suffix(from: try #require(sent.range(of: Data("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>".utf8))).upperBound)
    #expect((afterStartTLS.first == 0x16) == handshakes)
    #expect((afterStartTLS.range(of: Data("example.test".utf8)) != nil) == handshakes)
}

/// XEP-0368: the direct TLS ClientHello asks for ALPN `xmpp-client` and names the account domain.
@Test func directTLSOffersTheXMPPClientProtocol() async throws {
    let server = try PlaintextServer(features: nil)
    let port = try await server.start()
    defer { server.stop() }
    await #expect(throws: (any Error).self) {
        try await XMPPClient().connect(host: "127.0.0.1", port: port, domain: "example.test", username: "alice", password: "secret-password")
    }
    let hello = server.received
    #expect(hello.first == 0x16)
    #expect(hello.range(of: Data("xmpp-client".utf8)) != nil && hello.range(of: Data("example.test".utf8)) != nil)
}

/// SRV records on this machine only (multicast DNS, never on the network): the real resolver path without a public
/// zone. Each test gets its own `.local` domain; records vanish when the registration ends.
private final class LocalSRVZone: @unchecked Sendable {
    let domain = "haus-test-\(UUID().uuidString.prefix(8).lowercased()).local"
    private var connection: DNSServiceRef?
    private var records: [OpaquePointer?] = []

    /// `target` "." declares the service not offered.
    func register(_ service: String, target: String, port: UInt16) throws {
        if connection == nil {
            guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError else { throw POSIXError(.EIO) }
        }
        var rdata: [UInt8] = [0, 0, 0, 0, UInt8(port >> 8), UInt8(port & 0xFF)]
        for label in target.split(separator: ".") { rdata += [UInt8(label.utf8.count)] + Array(label.utf8) }
        rdata.append(0)
        var record: OpaquePointer?
        let status = rdata.withUnsafeBytes { bytes in
            DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsShared), UInt32(kDNSServiceInterfaceIndexLocalOnly),
                                     "\(service)._tcp.\(domain)", UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN),
                                     UInt16(rdata.count), bytes.baseAddress, 60, { _, _, _, _, _ in }, nil)
        }
        // The registration is complete once the call returns; the callback only reports later conflicts.
        guard status == kDNSServiceErr_NoError else { throw POSIXError(.EIO) }
        records.append(record)
    }

    deinit { if let connection { DNSServiceRefDeallocate(connection) } }
}

private enum DeadEndpoint { case refused, silent }

/// RFC 6120 §3.2: a remembered endpoint that no longer answers is skipped for what SRV now says, and the error is
/// the last candidate's. The silent case waits out the per-candidate timeout.
@Test(arguments: [DeadEndpoint.refused, .silent])
private func discoveryMovesPastADeadRememberedEndpoint(_ dead: DeadEndpoint) async throws {
    let current = try PlaintextServer(features: "<stream:features>\(sasl)</stream:features>")
    let currentPort = try await current.start()
    defer { current.stop() }
    let silent = try PlaintextServer(features: nil)
    let deadPort = try await silent.start()
    defer { silent.stop() }
    if dead == .refused { silent.stop() }
    let zone = LocalSRVZone()
    try zone.register("_xmpp-client", target: "localhost", port: currentPort)
    try zone.register("_xmpps-client", target: ".", port: 0)
    let client = XMPPClient()
    // `current` offers no STARTTLS, so reaching it ends in `encryptionUnavailable`; the dead endpoint's own error
    // (refused or timed out) would mean the loop stopped early.
    await #expect(throws: XMPPClientError.encryptionUnavailable) {
        try await client.connect(route: .discover(preferred: XMPPEndpoint(host: "127.0.0.1", port: deadPort, security: .startTLS)),
                                 domain: zone.domain, username: "alice", password: "secret-password")
    }
    let sent = String(decoding: current.received, as: UTF8.self)
    #expect(sent.contains("to='\(zone.domain)'") && !sent.contains("secret"))
    if dead == .silent { #expect(String(decoding: silent.received, as: UTF8.self).contains("<stream:stream")) }
}

/// Discovery ends with the caller's cancellation, not with the DNS timeout: the notification extension's budget
/// covers it. A `.local` name nobody answers makes the query wait for its full timeout otherwise.
@Test func cancellingDuringDiscoveryReturnsPromptly() async throws {
    let zone = LocalSRVZone()
    let client = XMPPClient()
    let clock = ContinuousClock()
    let started = clock.now
    let attempt = Task {
        try await client.connect(route: .discover(preferred: nil), domain: zone.domain, username: "alice", password: "secret-password")
    }
    try await Task.sleep(for: .milliseconds(300))
    attempt.cancel()
    await #expect(throws: (any Error).self) { try await attempt.value }
    #expect(clock.now - started < .seconds(2))
}
