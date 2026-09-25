import Foundation

/// Why an archive entry with valid outer provenance carries no content this client accepts. Recorded durably
/// (before the cursor) instead of failing the page, so one odd message cannot wedge catch-up.
public enum XMPPArchiveRejection: String, Sendable, Equatable {
    case unverifiableEncryptedGroup
    /// Inner from/to is not user@domain, or neither side is the account (server notice, component, forged actors).
    case foreignSender
    /// Content the client does not implement: EME without an OMEMO envelope, an unknown `urn:xmpp:omemo:*` namespace,
    /// more than one `<encrypted/>`, or a nested MAM/carbon/forwarded wrapper.
    case unsupportedDirectContent
    /// One OMEMO envelope in a known namespace that `OMEMOWire.parseMessage` refused (bad base64, oversize key or
    /// payload, wrong legacy IV length, invalid stanza id, duplicate/invalid header ids).
    case malformedEncryptedContent
}

public struct XMPPArchiveMessage: Sendable, Equatable {
    public let archiveID: String
    public let timestamp: Date
    public let message: XMPPMessage?
    public let encryptedMessage: XMPPEncryptedMessage?
    public var reaction: XMPPReaction? = nil
    public var retraction: XMPPRetraction? = nil
    public var receipt: XMPPReceipt? = nil
    public var encryptedGroupMessage: XMPPEncryptedGroupMessage? = nil
    public var rejectedContent: XMPPArchiveRejection? = nil
    public var rejectionArchive: String? = nil
    /// Bare JID of the conversation a rejected direct entry belongs to; nil for `foreignSender` and group rejections.
    public var rejectedPeer: String? = nil
    /// True when the rejected entry was sent by the account (own archive, `from` is the account).
    public var rejectedOutgoing: Bool = false
}

/// Which side of a cursor an archive page is taken from (XEP-0059 §2.2, §2.5; XEP-0313 §4.1).
public enum XMPPArchiveBound: Sendable, Equatable {
    /// Forward from a cursor; nil = from the beginning of the archive.
    case after(String?)
    /// Backward from a cursor; nil = the newest page (RSM `<before/>`).
    case before(String?)

    var cursor: String? { switch self { case .after(let id), .before(let id): id } }
}

/// Results are in chronological order in either direction: `messages.first` is the oldest entry.
public struct XMPPArchivePage: Sendable, Equatable {
    public let messages: [XMPPArchiveMessage]
    /// Forward: nothing newer than this page. Backward: nothing older than this page.
    public let complete: Bool
    /// RSM `<first>`: the oldest returned ID. nil only when the page is empty.
    public let firstID: String?
    /// RSM `<last>`: the newest returned ID. nil only when the page is empty.
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
    static let resultSetNamespace = "http://jabber.org/protocol/rsm"

    /// The MAM query with an RSM set of `limit` items on the requested side of the cursor. An empty `<before/>`
    /// asks for the last (newest) page (XEP-0059 §2.5, XEP-0313 §4.1).
    static func payload(queryID: String, limit: Int, bound: XMPPArchiveBound) -> String {
        let cursorXML: String
        switch bound {
        case .after(nil): cursorXML = ""
        case .after(let id?): cursorXML = "<after>\(xmlEscaped(id))</after>"
        case .before(nil): cursorXML = "<before/>"
        case .before(let id?): cursorXML = "<before>\(xmlEscaped(id))</before>"
        }
        return "<query xmlns='\(namespace)' queryid='\(xmlEscaped(queryID))'><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'><value>\(namespace)</value></field></x><set xmlns='\(resultSetNamespace)'><max>\(limit)</max>\(cursorXML)</set></query>"
    }
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
        // Exactly one <delay/> and at most one <message/>; other children (a server's <stanza-id/>) are ignored.
        let delay = try OMEMOWire.singleton(forwarded, "delay", "urn:xmpp:delay")
        guard let stamp = delay.attributes["stamp"], let timestamp = Self.timestamp(stamp) else { throw XMPPIQError.malformedResponse }
        let innerMessages = forwarded.children("message", namespace: "jabber:client")
        guard innerMessages.count <= 1 else { throw XMPPIQError.malformedResponse }
        guard var inner = innerMessages.first else {
            // XEP-0313 allows a redacted archive entry to retain only its timestamp and UID.
            messages.append(.init(archiveID: id, timestamp: timestamp, message: nil, encryptedMessage: nil))
            identifiers.insert(id); return
        }
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
        if room != nil {
            guard !Self.nestsWrapper(inner) else { throw XMPPIQError.malformedResponse }
            // Non-encrypted room events carry no authenticated application content.
            messages.append(.init(archiveID: id, timestamp: timestamp, message: nil, encryptedMessage: nil))
            identifiers.insert(id); return
        }
        // Everything above is the own archive's outer provenance and still throws. From here on the inner message is
        // content: whatever this client cannot accept becomes a rejected entry, recorded before the cursor advances.
        if inner.attributes["to"] == nil {
            // Prosody stores incoming/self messages without their redundant local recipient; ejabberd includes it.
            // This normalization is permitted only after the own-archive wrapper is authenticated. Both shapes are
            // covered by `archiveNormalizesOnlyTrustedMissingRecipientAndAcceptsRedactedPositions` and `ArchiveContentTests`.
            var attributes = inner.attributes; attributes["to"] = accountBareJID
            inner = XMLNode(name: inner.name, namespace: inner.namespace, attributes: attributes, text: inner.text, children: inner.children)
        }
        func reject(_ reason: XMPPArchiveRejection, peer: String? = nil, outgoing: Bool = false) {
            messages.append(.init(archiveID: id, timestamp: timestamp, message: nil, encryptedMessage: nil, rejectedContent: reason,
                                  rejectionArchive: archiveOwner, rejectedPeer: peer, rejectedOutgoing: outgoing))
            identifiers.insert(id)
        }
        guard let from = inner.attributes["from"], let sender = OMEMOWire.bareJID(from),
              let to = inner.attributes["to"], let recipient = OMEMOWire.bareJID(to),
              sender == accountBareJID || recipient == accountBareJID else { return reject(.foreignSender) }
        let outgoing = sender == accountBareJID
        let peer = outgoing ? recipient : sender
        guard !Self.nestsWrapper(inner) else { return reject(.unsupportedDirectContent, peer: peer, outgoing: outgoing) }
        // Reuse already authenticated own-account forwarding provenance; archive ID and time are separate.
        let provenance: XMPPMessageProvenance = outgoing ? .sentCarbon : .receivedCarbon
        var encrypted: XMPPEncryptedMessage?
        if OMEMOWire.hasEncryptedContent(inner) {
            let known = inner.children.filter { child in child.name == "encrypted" && XMPPOMEMOProfile.allCases.contains { $0.namespace == child.namespace } }
            guard known.count == 1 else { return reject(.unsupportedDirectContent, peer: peer, outgoing: outgoing) }
            do { encrypted = try OMEMOWire.parseMessage(inner, provenance: provenance) }
            catch { return reject(.malformedEncryptedContent, peer: peer, outgoing: outgoing) }
        }
        let retraction = encrypted == nil ? XMPPClient.parsedRetraction(inner, provenance: provenance) : nil
        let reaction = encrypted == nil && retraction == nil ? XMPPClient.parsedReaction(inner, provenance: provenance) : nil
        let receipt = encrypted == nil && reaction == nil && retraction == nil ? XMPPClient.parsedReceipt(inner, provenance: provenance) : nil
        let plain = encrypted == nil && reaction == nil && receipt == nil && retraction == nil ? XMPPClient.parsedMessage(inner, provenance: provenance) : nil
        // Preserve an archive position even for a stanza type the current client cannot display.
        messages.append(.init(archiveID: id, timestamp: timestamp, message: plain, encryptedMessage: encrypted, reaction: reaction, retraction: retraction, receipt: receipt))
        identifiers.insert(id)
    }

    func finish(_ node: XMLNode) throws -> XMPPArchivePage {
        guard !failure, (room == nil && node.attributes["from"] == nil) || node.attributes["from"] == archiveOwner else { throw XMPPIQError.malformedResponse }
        let fin = try OMEMOWire.singleton(node, "fin", Self.namespace)
        guard fin.attributes["stable"] != "false", fin.attributes["stable"] != "0" else { throw XMPPIQError.malformedResponse }
        let complete: Bool
        switch fin.attributes["complete"] { case nil, "false", "0": complete = false; case "true", "1": complete = true; default: throw XMPPIQError.malformedResponse }
        let set = try OMEMOWire.singleton(fin, "set", Self.resultSetNamespace)
        func bound(_ name: String) throws -> String? {
            let nodes = set.children.filter { $0.name == name && $0.namespace == set.namespace }
            guard nodes.count <= 1 else { throw XMPPIQError.malformedResponse }
            return nodes.first?.text
        }
        let first = try bound("first"), last = try bound("last")
        // Results arrive oldest first whichever direction was asked, so the RSM bounds must name exactly the
        // returned ends. A non-empty page names both; an empty one names neither and must be complete.
        guard first == messages.first?.archiveID, last == messages.last?.archiveID,
              complete || (first != nil && last != nil) else { throw XMPPIQError.malformedResponse }
        return .init(messages: messages, complete: complete, firstID: first, lastID: last, handledTokens: handledTokens)
    }

    /// A MAM result, carbon or `<forwarded/>` inside archived content: never unwrapped a second time.
    static func nestsWrapper(_ inner: XMLNode) -> Bool {
        containsWrapper(inner) || Carbons.containsWrapper(inner) || inner.child("forwarded", namespace: Carbons.forwarding) != nil
    }

    // Configured once and then only read: `ISO8601DateFormatter`, like `DateFormatter` since iOS 7, is thread-safe for
    // parsing, so one shared pair replaces two allocations per archived message. `nonisolated(unsafe)` is needed only
    // because the class is not `Sendable` under Swift 6; nothing mutates these after initialization.
    nonisolated(unsafe) private static let fractionalTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let wholeTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestamp(_ value: String) -> Date? {
        fractionalTimestamp.date(from: value) ?? wholeTimestamp.date(from: value)
    }
}

func validArchiveID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 1_024 && !id.contains(where: { $0.isWhitespace || $0.isNewline }) && id.unicodeScalars.allSatisfy { $0.value >= 32 }
}
