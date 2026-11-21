import Foundation

extension XMPPClient {
    // Counted so `h` stays aligned, never read as content. Only the outer wrapper of an archive result and an IQ's
    // addressing are used; anything but a stanza comes from the server itself and ends the stream.
    func handleRejected(_ node: XMLNode) async throws {
        guard phase == .online, node.namespace == "jabber:client", ["message", "iq", "presence"].contains(node.name) else {
            throw XMLStreamError.limitExceeded
        }
        let node = JID.normalizingAddresses(node)
        let inbound = try await countInbound(node)
        if node.name == "message" {
            if stampWindow?.ends(with: node) == true { stampWindow = nil }
            if ArchiveQuery.containsWrapper(node) { return try await receiveArchiveResult(node, inbound: inbound, oversized: true) }
        } else if node.name == "iq", let id = node.attributes["id"] {
            switch node.attributes["type"] {
            case "get", "set": try await write(Self.oversizedRequestError(id: id, to: node.attributes["from"]))
            case "result", "error":
                guard let request = iqRequests[id], request.scope.accepts(node) else { break }
                stampWindow = nil
                failIQ(id, error: XMPPIQError.malformedResponse)
            default: break
            }
        }
        if let inbound { try await streamManagement?.handled(inbound) }
    }

    // RFC 6120 §8.3.3.12: the limits are this client's policy, and a smaller request would be answered.
    static func oversizedRequestError(id: String, to: String?) -> String {
        let to = to.map { " to='\(xmlEscaped($0))'" } ?? ""
        return "<iq type='error' id='\(xmlEscaped(id))'\(to)><error type='modify'><policy-violation xmlns='\(XMPPMessageError.stanzasNamespace)'/></error></iq>"
    }
}
