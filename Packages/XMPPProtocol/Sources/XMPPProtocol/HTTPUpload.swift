import Foundation

/// XEP-0363: the server's upload component and one slot for one file.
public struct XMPPUploadService: Sendable, Equatable {
    public static let namespace = "urn:xmpp:http:upload:0"
    public let jid: String
    /// Advertised `max-file-size`, when the component publishes one.
    public let maximumFileSize: Int?
    public init(jid: String, maximumFileSize: Int?) { self.jid = jid; self.maximumFileSize = maximumFileSize }

    /// Reads the component's disco#info: the feature plus the optional data form.
    static func decode(jid: String, info query: XMLNode) -> XMPPUploadService? {
        let features = Set(query.children.filter { $0.name == "feature" && $0.namespace == query.namespace }.compactMap { $0.attributes["var"] })
        guard features.contains(namespace) else { return nil }
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
    public func discoveryItems(for jid: String? = nil) async throws -> [String] {
        let response = try await requestIQ(type: "get", to: jid, payload: "<query xmlns='http://jabber.org/protocol/disco#items'/>")
        let query = try OMEMOWire.singleton(response, "query", "http://jabber.org/protocol/disco#items")
        let items = query.children.filter { $0.name == "item" && $0.namespace == query.namespace }
        guard items.count <= 256 else { throw XMPPIQError.malformedResponse }
        return items.compactMap { $0.attributes["jid"] }.filter { MessageContent.validAddress($0) && !$0.contains("/") }
    }

    /// The first server component advertising XEP-0363, or nil when the server offers none.
    /// Components hang off the server domain (an unaddressed items query returns the account's
    /// own items); each probe is then addressed to the exact component so the reply scope stays strict.
    public func uploadService() async throws -> XMPPUploadService? {
        guard phase == .online, !domain.isEmpty else { throw XMPPClientError.notConnected }
        for item in try await discoveryItems(for: domain) {
            let info: XMLNode
            do { info = try await discoveryInfo(for: item) } catch XMPPIQError.stanza { continue }
            if let service = XMPPUploadService.decode(jid: item, info: info) { return service }
        }
        return nil
    }

    public func requestUploadSlot(service: XMPPUploadService, filename: String, size: Int, contentType: String) async throws -> XMPPUploadSlot {
        guard !filename.isEmpty, filename.utf8.count <= 255, !filename.contains("/"), MessageContent.validXMLText(filename),
              size > 0, !contentType.isEmpty, contentType.utf8.count <= 128, MessageContent.validXMLText(contentType) else { throw XMPPClientError.invalidConfiguration }
        let payload = "<request xmlns='\(XMPPUploadService.namespace)' filename='\(xmlEscaped(filename))' size='\(size)' content-type='\(xmlEscaped(contentType))'/>"
        return try XMPPUploadSlot.decode(try await requestIQ(type: "get", to: service.jid, payload: payload))
    }
}
