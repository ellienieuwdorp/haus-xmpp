import dnssd
import Foundation

public enum XMPPTransportSecurity: String, Sendable, Codable, CaseIterable {
    /// TLS from the first byte (XEP-0368), ALPN `xmpp-client`.
    case directTLS
    /// RFC 6120 §5: plain TCP, then a mandatory `<starttls/>` before anything else is sent.
    case startTLS

    public var defaultPort: UInt16 { self == .directTLS ? 5223 : 5222 }
}

/// Where to open the TCP connection. TLS identity is always the account domain, never this host.
public struct XMPPEndpoint: Sendable, Hashable, Codable {
    public let host: String
    public let port: UInt16
    public let security: XMPPTransportSecurity

    public init(host: String, port: UInt16, security: XMPPTransportSecurity) {
        self.host = host; self.port = port; self.security = security
    }
}

public enum XMPPRoute: Sendable, Equatable {
    /// Exactly this endpoint, no discovery: a manually entered server, or the lab.
    case fixed(XMPPEndpoint)
    /// RFC 6120 §3.2 and XEP-0368 discovery for the account domain. `preferred`, the endpoint that worked last time,
    /// is tried first; DNS is only queried when it fails.
    case discover(preferred: XMPPEndpoint?)
}

/// One SRV record set: the records, "." (RFC 2782: decidedly not offered), or nothing usable (no records, NXDOMAIN,
/// error or timeout).
enum SRVLookup: Equatable {
    case records([SRVRecord])
    case notOffered
    case none

    /// "." is honoured only when it is all there is; real records next to it win. Port 0 is unusable.
    init(_ records: [SRVRecord]) {
        let usable = records.filter { $0.target != "." && $0.port != 0 }
        self = !usable.isEmpty ? .records(usable) : records.contains { $0.target == "." } ? .notOffered : .none
    }
}

struct SRVRecord: Equatable {
    let priority: UInt16
    let weight: UInt16
    let port: UInt16
    let target: String

    /// RFC 2782 RDATA: priority, weight, port, then the target as uncompressed DNS labels. The root name is ".".
    init?(rdata: Data) {
        let bytes = [UInt8](rdata)
        guard bytes.count >= 7 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        var labels: [String] = []
        var index = 6
        while true {
            guard index < bytes.count else { return nil }
            let length = Int(bytes[index])
            if length == 0 { break }
            guard length < 64, index + 1 + length <= bytes.count,
                  let label = String(bytes: bytes[(index + 1)...(index + length)], encoding: .utf8) else { return nil }
            labels.append(label); index += 1 + length
        }
        guard index == bytes.count - 1 else { return nil }
        self.init(priority: u16(0), weight: u16(2), port: u16(4), target: labels.isEmpty ? "." : labels.joined(separator: "."))
    }

    init(priority: UInt16, weight: UInt16, port: UInt16, target: String) {
        self.priority = priority; self.weight = weight; self.port = port; self.target = target
    }
}

enum EndpointDiscovery {
    /// Merges `_xmpps-client._tcp` (direct TLS) and `_xmpp-client._tcp` (STARTTLS) answers into the order to try.
    /// Priority first; RFC 2782 weighted order within a priority; direct TLS before STARTTLS on equal priority.
    /// With no records at all: `<domain>:5222` STARTTLS (RFC 6120 §3.2.2), then `<domain>:5223` direct TLS. A type
    /// answered with "." contributes nothing, not even its fallback. Empty means the domain offers no client service.
    static func candidates<R: RandomNumberGenerator>(domain: String, directTLS: SRVLookup, startTLS: SRVLookup,
                                                     using random: inout R) -> [XMPPEndpoint] {
        var tagged: [(SRVRecord, XMPPTransportSecurity)] = []
        if case .records(let records) = directTLS { tagged += records.map { ($0, .directTLS) } }
        if case .records(let records) = startTLS { tagged += records.map { ($0, .startTLS) } }
        if tagged.isEmpty {
            var fallback: [XMPPEndpoint] = []
            if startTLS == .none { fallback.append(XMPPEndpoint(host: domain, port: 5222, security: .startTLS)) }
            if startTLS == .none, directTLS == .none { fallback.append(XMPPEndpoint(host: domain, port: 5223, security: .directTLS)) }
            return fallback
        }
        var ordered: [XMPPEndpoint] = []
        for priority in Set(tagged.map(\.0.priority)).sorted() {
            for security in [XMPPTransportSecurity.directTLS, .startTLS] {
                let group = tagged.filter { $0.0.priority == priority && $0.1 == security }.map(\.0)
                ordered += weightedOrder(group, using: &random).map { XMPPEndpoint(host: $0.target, port: $0.port, security: security) }
            }
        }
        var seen = Set<XMPPEndpoint>()
        return ordered.filter { seen.insert($0).inserted }
    }

    /// RFC 2782: zero-weight records first, then repeatedly pick by a random point in the running weight sum.
    static func weightedOrder<R: RandomNumberGenerator>(_ records: [SRVRecord], using random: inout R) -> [SRVRecord] {
        var remaining = records.filter { $0.weight == 0 } + records.filter { $0.weight != 0 }
        var ordered: [SRVRecord] = []
        while !remaining.isEmpty {
            let total = remaining.reduce(0) { $0 + Int($1.weight) }
            let point = Int.random(in: 0...total, using: &random)
            var sum = 0
            let index = remaining.firstIndex { sum += Int($0.weight); return sum >= point } ?? 0
            ordered.append(remaining.remove(at: index))
        }
        return ordered
    }

    /// Both SRV types, concurrently, each bounded by `timeout`.
    static func resolve(domain: String, timeout: Duration) async -> [XMPPEndpoint] {
        async let direct = lookup("_xmpps-client._tcp." + domain, timeout: timeout)
        async let starttls = lookup("_xmpp-client._tcp." + domain, timeout: timeout)
        let (directTLS, startTLS) = await (direct, starttls)
        var random = SystemRandomNumberGenerator()
        return candidates(domain: domain, directTLS: directTLS, startTLS: startTLS, using: &random)
    }

    /// Cancellation ends the query at once with nothing usable, so a caller's budget bounds discovery too.
    static func lookup(_ name: String, timeout: Duration) async -> SRVLookup {
        let query = SRVQuery(name: name, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in query.start { continuation.resume(returning: $0) } }
        } onCancel: { query.cancel() }
    }
}

/// One `DNSServiceQueryRecord`. `ReturnIntermediates` makes NXDOMAIN and NODATA answer at once instead of waiting
/// out the timeout. Records arrive in batches flagged `MoreComing`; the first complete SRV batch ends the query.
private final class SRVQuery: @unchecked Sendable {
    private let name: String
    private let timeout: Duration
    private let queue = DispatchQueue(label: "xmpp.srv")
    private var completion: ((SRVLookup) -> Void)?
    private var reference: DNSServiceRef?
    private var records: [SRVRecord] = []
    private var retained: Unmanaged<SRVQuery>?
    private var cancelled = false

    init(name: String, timeout: Duration) {
        self.name = name; self.timeout = timeout
    }

    func start(completion: @escaping (SRVLookup) -> Void) {
        queue.async { [self] in
            self.completion = completion
            // A cancellation that arrived first ends the query before it is sent.
            guard !cancelled else { finish(); return }
            let context = Unmanaged.passRetained(self)
            retained = context
            var ref: DNSServiceRef?
            let status = DNSServiceQueryRecord(&ref, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0, name,
                                               UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN), { _, flags, _, error, _, type, _, length, rdata, _, context in
                guard let context else { return }
                let query = Unmanaged<SRVQuery>.fromOpaque(context).takeUnretainedValue()
                query.received(flags: flags, error: error, type: type, data: rdata.map { Data(bytes: $0, count: Int(length)) })
            }, context.toOpaque())
            guard status == kDNSServiceErr_NoError, let ref, DNSServiceSetDispatchQueue(ref, queue) == kDNSServiceErr_NoError else {
                if let ref { DNSServiceRefDeallocate(ref) }
                finish(); return
            }
            reference = ref
            let (seconds, attoseconds) = timeout.components
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000))) { [self] in finish() }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            finish()
        }
    }

    private func received(flags: DNSServiceFlags, error: DNSServiceErrorType, type: UInt16, data: Data?) {
        guard completion != nil else { return }
        if error != kDNSServiceErr_NoError { finish(); return }
        // CNAME and other intermediates do not end the query.
        guard type == UInt16(kDNSServiceType_SRV) else { return }
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data, let record = SRVRecord(rdata: data) { records.append(record) }
        if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { finish() }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        if let reference { DNSServiceRefDeallocate(reference); self.reference = nil }
        let result = cancelled ? .none : SRVLookup(records)
        retained?.release(); retained = nil
        completion(result)
    }
}
