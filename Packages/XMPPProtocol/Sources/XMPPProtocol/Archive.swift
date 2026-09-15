import Foundation

public enum XMPPArchiveRejection: String, Sendable, Equatable { case unverifiableEncryptedGroup }

public struct XMPPArchiveMessage: Sendable, Equatable {
    public let archiveID: String
    public let timestamp: Date
    public let message: XMPPMessage?
    public let encryptedMessage: XMPPEncryptedMessage?
    public var reaction: XMPPReaction? = nil
    public var encryptedGroupMessage: XMPPEncryptedGroupMessage? = nil
    public var rejectedContent: XMPPArchiveRejection? = nil
    public var rejectionArchive: String? = nil
}

public struct XMPPArchivePage: Sendable, Equatable {
    public let messages: [XMPPArchiveMessage]
    public let complete: Bool
    public let lastID: String?
    public let handledTokens: [XMPPInboundToken]
}

struct ArchiveQuery {
    let queryID: String
    let accountBareJID: String
    let accountFullJID: String
    let limit: Int
    var messages: [XMPPArchiveMessage] = []
    var identifiers: Set<String> = []
    var failure: Bool = false
    var handledTokens: [XMPPInboundToken] = []
    var room: String? = nil
    var knownRooms: Set<String> = []
    var archiveOwner: String { room ?? accountBareJID }

    static let namespace = "urn:xmpp:mam:2"
    static func containsWrapper(_ node: XMLNode) -> Bool {
        node.children.contains { $0.name == "result" && $0.namespace.hasPrefix("urn:xmpp:mam:") }
    }

    mutating func receive(_ node: XMLNode) throws {
        guard node.name == "message", node.namespace == "jabber:client",
              (room == nil && node.attributes["from"] == nil) || node.attributes["from"] == archiveOwner,
              node.attributes["to"] == nil || node.attributes["to"] == accountFullJID else { throw XMPPIQError.malformedResponse }
        let result = try OMEMOWire.singleton(node, "result", Self.namespace)
        guard result.attributes["queryid"] == queryID, let id = result.attributes["id"], validArchiveID(id),
              !identifiers.contains(id), result.children.count == 1, messages.count < limit else { throw XMPPIQError.malformedResponse }
        let forwarded = try OMEMOWire.singleton(result, "forwarded", Carbons.forwarding)
        guard (1...2).contains(forwarded.children.count) else { throw XMPPIQError.malformedResponse }
        let delay = try OMEMOWire.singleton(forwarded, "delay", "urn:xmpp:delay")
        guard let stamp = delay.attributes["stamp"], let timestamp = Self.timestamp(stamp) else { throw XMPPIQError.malformedResponse }
        if forwarded.children.count == 1 {
            // XEP-0313 allows a redacted archive entry to retain only its timestamp and UID.
            messages.append(.init(archiveID: id, timestamp: timestamp, message: nil, encryptedMessage: nil))
            identifiers.insert(id); return
        }
        var inner = try OMEMOWire.singleton(forwarded, "message", "jabber:client")
        if inner.attributes["type"] == "groupchat", OMEMOWire.hasEncryptedContent(inner) {
            do {
                guard !Self.containsWrapper(inner), !Carbons.containsWrapper(inner), inner.child("forwarded", namespace: Carbons.forwarding) == nil else { throw XMPPGroupError.invalidMessage }
                let group = try GroupChatWire.archivedMessage(inner, account: accountBareJID, archiveRoom: room, knownRooms: knownRooms, archiveID: id)
                messages.append(.init(archiveID: id, timestamp: timestamp, message: nil, encryptedMessage: nil, encryptedGroupMessage: group))
            } catch {
                // The outer archive provenance is valid. Record a deliberate rejection of
                // unsupported/unverifiable inner content instead of blocking unrelated DMs.
                messages.append(.init(archiveID: id, timestamp: timestamp, message: nil, encryptedMessage: nil, rejectedContent: .unverifiableEncryptedGroup, rejectionArchive: archiveOwner))
            }
            identifiers.insert(id); return
        }
        guard !Self.containsWrapper(inner), !Carbons.containsWrapper(inner), inner.child("forwarded", namespace: Carbons.forwarding) == nil else { throw XMPPIQError.malformedResponse }
        if room != nil {
            // Non-encrypted room events carry no authenticated application content.
            messages.append(.init(archiveID: id, timestamp: timestamp, message: nil, encryptedMessage: nil))
            identifiers.insert(id); return
        }
        if inner.attributes["to"] == nil {
            // Prosody stores incoming/self messages without their redundant local recipient.
            // This normalization is permitted only after the own-archive wrapper is authenticated.
            var attributes = inner.attributes; attributes["to"] = accountBareJID
            inner = XMLNode(name: inner.name, namespace: inner.namespace, attributes: attributes, text: inner.text, children: inner.children)
        }
        guard !Self.containsWrapper(inner), !Carbons.containsWrapper(inner), inner.child("forwarded", namespace: Carbons.forwarding) == nil,
              let from = inner.attributes["from"], let sender = OMEMOWire.bareJID(from),
              let to = inner.attributes["to"], let recipient = OMEMOWire.bareJID(to),
              sender == accountBareJID || recipient == accountBareJID else { throw XMPPIQError.malformedResponse }
        // Reuse already authenticated own-account forwarding provenance; archive ID and time are separate.
        let provenance: XMPPMessageProvenance = sender == accountBareJID ? .sentCarbon : .receivedCarbon
        let encrypted = OMEMOWire.hasEncryptedContent(inner) ? try OMEMOWire.parseMessage(inner, provenance: provenance) : nil
        let reaction = encrypted == nil ? XMPPClient.parsedReaction(inner, provenance: provenance) : nil
        let plain = encrypted == nil && reaction == nil ? XMPPClient.parsedMessage(inner, provenance: provenance) : nil
        // Preserve an archive position even for a stanza type the current client cannot display.
        messages.append(.init(archiveID: id, timestamp: timestamp, message: plain, encryptedMessage: encrypted, reaction: reaction))
        identifiers.insert(id)
    }

    func finish(_ node: XMLNode) throws -> XMPPArchivePage {
        guard !failure, (room == nil && node.attributes["from"] == nil) || node.attributes["from"] == archiveOwner else { throw XMPPIQError.malformedResponse }
        let fin = try OMEMOWire.singleton(node, "fin", Self.namespace)
        guard fin.attributes["stable"] != "false", fin.attributes["stable"] != "0" else { throw XMPPIQError.malformedResponse }
        let complete: Bool
        switch fin.attributes["complete"] { case nil, "false", "0": complete = false; case "true", "1": complete = true; default: throw XMPPIQError.malformedResponse }
        let set = try OMEMOWire.singleton(fin, "set", "http://jabber.org/protocol/rsm")
        let lastNodes = set.children.filter { $0.name == "last" && $0.namespace == set.namespace }
        guard lastNodes.count <= 1 else { throw XMPPIQError.malformedResponse }
        let last = lastNodes.first?.text
        guard last == messages.last?.archiveID, complete || last != nil else { throw XMPPIQError.malformedResponse }
        return .init(messages: messages, complete: complete, lastID: last, handledTokens: handledTokens)
    }

    static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

func validArchiveID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 1_024 && !id.contains(where: { $0.isWhitespace || $0.isNewline }) && id.unicodeScalars.allSatisfy { $0.value >= 32 }
}
