import Foundation

/// XEP-0363: the server's upload component and one slot for one file.
public struct XMPPUploadService: Sendable, Equatable {
    public static let namespace = "urn:xmpp:http:upload:0"
    public let jid: String
    /// Advertised `max-file-size`, when the component publishes one.
    public let maximumFileSize: Int?
    public init(jid: String, maximumFileSize: Int?) { self.jid = jid; self.maximumFileSize = maximumFileSize }

    /// Reads the component's disco#info: the feature plus the optional data form. A MUC service that also offers
    /// uploads keeps them for its rooms, so it is not the account's service.
    static func decode(jid: String, info query: XMLNode) -> XMPPUploadService? {
        let features = Set(query.children.filter { $0.name == "feature" && $0.namespace == query.namespace }.compactMap { $0.attributes["var"] })
        guard features.contains(namespace), !features.contains("http://jabber.org/protocol/muc") else { return nil }
        var maximum: Int?
        for form in query.children("x", namespace: "jabber:x:data") {
            let fields = form.children("field", namespace: "jabber:x:data")
            guard fields.first(where: { $0.attributes["var"] == "FORM_TYPE" })?.child("value", namespace: "jabber:x:data")?.text == namespace else { continue }
            if let value = fields.first(where: { $0.attributes["var"] == "max-file-size" })?.child("value", namespace: "jabber:x:data")?.text,
               let size = Int(value.trimmingCharacters(in: .whitespaces)), size > 0 { maximum = size }
        }
        return XMPPUploadService(jid: jid, maximumFileSize: maximum)
    }
}

public struct XMPPUploadSlot: Sendable, Equatable {
    public let put: URL
    /// Only the headers XEP-0363 permits are kept; anything else from the server is dropped.
    public let headers: [String: String]
    public let get: URL

    static func decode(_ response: XMLNode) throws -> XMPPUploadSlot {
        let slot = try OMEMOWire.singleton(response, "slot", XMPPUploadService.namespace)
        let put = try OMEMOWire.singleton(slot, "put", XMPPUploadService.namespace)
        let get = try OMEMOWire.singleton(slot, "get", XMPPUploadService.namespace)
        guard let putURL = put.attributes["url"].flatMap(Self.https), let getURL = get.attributes["url"].flatMap(Self.https) else { throw XMPPIQError.malformedResponse }
        var headers: [String: String] = [:]
        for header in put.children("header", namespace: XMPPUploadService.namespace) {
            guard let name = header.attributes["name"], ["Authorization", "Cookie", "Expires"].contains(name), header.children.isEmpty,
                  header.text.utf8.count <= 4_096, !header.text.contains(where: { $0 == "\r" || $0 == "\n" }) else { continue }
            headers[name] = header.text
        }
        return XMPPUploadSlot(put: putURL, headers: headers, get: getURL)
    }
    private static func https(_ value: String) -> URL? {
        guard MessageContent.FileSharing.validURL(value) else { return nil }
        return URL(string: value)
    }
}

extension XMPPClient {
    /// Entities the server lists under disco#items (components such as the upload service).
    public func discoveryItems(for jid: String? = nil, timeout: Duration = XMPPClient.iqTimeout) async throws -> [String] {
        let response = try await requestIQ(type: "get", to: jid, payload: "<query xmlns='http://jabber.org/protocol/disco#items'/>", timeout: timeout)
        let query = try OMEMOWire.singleton(response, "query", "http://jabber.org/protocol/disco#items")
        let items = query.children.filter { $0.name == "item" && $0.namespace == query.namespace }
        guard items.count <= 256 else { throw XMPPIQError.malformedResponse }
        return items.compactMap { $0.attributes["jid"] }.filter { MessageContent.validAddress($0) && !$0.contains("/") }
    }

    /// Probes in flight at once; well under the client's limit on outstanding IQs.
    static let uploadProbeWidth = 8

    /// The server's XEP-0363 service, or nil when the server offers none. The domain itself and every entity it lists
    /// under disco#items are probed concurrently, each within `timeout`; components hang off the server domain (an
    /// unaddressed items query returns the account's own items), and each probe is addressed to the exact entity so the
    /// reply scope stays strict. Of several services the one with the largest `max-file-size` wins (one that states no
    /// limit counts as largest), then the domain, then list order.
    ///
    /// A stanza error means "not this entity". Any other failure (a silent component, a timeout, a malformed answer)
    /// leaves the question open: when nothing was found, that error is thrown, so the caller keeps what it knew.
    public func uploadService(timeout: Duration = .seconds(5)) async throws -> XMPPUploadService? {
        guard !domain.isEmpty else { throw XMPPClientError.notConnected }
        let server = domain
        async let listed: Result<[String], any Error> = { () async -> Result<[String], any Error> in
            do { return .success(try await self.discoveryItems(for: server, timeout: timeout)) } catch { return .failure(error) }
        }()
        var open: (any Error)?
        var found: [(order: Int, service: XMPPUploadService)] = []
        func record(_ order: Int, _ outcome: Result<XMPPUploadService?, any Error>) {
            switch outcome {
            case .success(let service?): found.append((order, service))
            case .success(nil), .failure(XMPPIQError.stanza): break
            case .failure(let error): open = open ?? error
            }
        }
        record(0, await probeUploadInfo(server, timeout: timeout))
        switch await listed {
        case .failure(XMPPIQError.stanza): break
        case .failure(let error): open = open ?? error
        case .success(let items):
            let candidates = Array(items.filter { $0 != server }.enumerated())
            await withTaskGroup(of: (Int, Result<XMPPUploadService?, any Error>).self) { group in
                var next = 0
                func add() {
                    guard next < candidates.count else { return }
                    let (index, item) = candidates[next]; next += 1
                    group.addTask { (index + 1, await self.probeUploadInfo(item, timeout: timeout)) }
                }
                for _ in 0..<Self.uploadProbeWidth { add() }
                for await (order, outcome) in group { record(order, outcome); add() }
            }
        }
        try Task.checkCancellation()
        let best = found.min { lhs, rhs in
            let left = lhs.service.maximumFileSize ?? .max, right = rhs.service.maximumFileSize ?? .max
            return left != right ? left > right : lhs.order < rhs.order
        }
        if let best { return best.service }
        if let open { throw open }
        return nil
    }

    private func probeUploadInfo(_ jid: String, timeout: Duration) async -> Result<XMPPUploadService?, any Error> {
        do {
            let response = try await requestIQ(type: "get", to: jid, payload: "<query xmlns='http://jabber.org/protocol/disco#info'/>", timeout: timeout)
            let info = try OMEMOWire.singleton(response, "query", "http://jabber.org/protocol/disco#info")
            return .success(XMPPUploadService.decode(jid: jid, info: info))
        } catch { return .failure(error) }
    }

    public func requestUploadSlot(service: XMPPUploadService, filename: String, size: Int, contentType: String) async throws -> XMPPUploadSlot {
        guard !filename.isEmpty, filename.utf8.count <= 255, !filename.contains("/"), MessageContent.validXMLText(filename),
              size > 0, !contentType.isEmpty, contentType.utf8.count <= 128, MessageContent.validXMLText(contentType) else { throw XMPPClientError.invalidConfiguration }
        let payload = "<request xmlns='\(XMPPUploadService.namespace)' filename='\(xmlEscaped(filename))' size='\(size)' content-type='\(xmlEscaped(contentType))'/>"
        return try XMPPUploadSlot.decode(try await requestIQ(type: "get", to: service.jid, payload: payload))
    }
}
