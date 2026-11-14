import Foundation

/// Why an archive entry with valid outer provenance carries no acceptable content. Recorded durably before the
/// cursor instead of failing the page, so one odd message cannot wedge catch-up.
public enum XMPPArchiveRejection: String, Sendable, Equatable {
    case unverifiableEncryptedGroup
    /// Inner from/to is not user@domain, or neither side is the account (server notice, component, forged actors).
    case foreignSender
    /// Content the client does not implement: EME without an OMEMO envelope, an unknown `urn:xmpp:omemo:*` namespace,
    /// more than one `<encrypted/>`, or a nested MAM/carbon/forwarded wrapper.
    case unsupportedDirectContent
    /// One OMEMO envelope in a known namespace that `OMEMOWire.parseMessage` refused.
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
    /// nil for `foreignSender` and group rejections.
    public var rejectedPeer: String? = nil
    /// The account sent the rejected entry.
    public var rejectedOutgoing: Bool = false
    /// A bounced stanza, which Prosody keeps in the own archive. Only its id, sender and condition are read.
    public var messageError: XMPPMessageError? = nil
}

/// Which side of a cursor an archive page is taken from (XEP-0059 §2.2, §2.5; XEP-0313 §4.1).
public enum XMPPArchiveBound: Sendable, Equatable {
    /// nil starts at the beginning of the archive.
    case after(String?)
    /// nil is the newest page (RSM `<before/>`).
    case before(String?)
    /// XEP-0313 §4.1.1 `start` field, without a cursor.
    case since(Date)

    var cursor: String? {
        switch self {
        case .after(let id), .before(let id): id
        case .since: nil
        }
    }
}

/// Chronological in either direction: `messages.first` is the oldest entry.
public struct XMPPArchivePage: Sendable, Equatable {
    public let messages: [XMPPArchiveMessage]
    /// Forward: nothing newer than this page. Backward: nothing older than this page.
    public let complete: Bool
    /// RSM `<first>`, the oldest returned ID; nil only when the page is empty.
    public let firstID: String?
    /// RSM `<last>`, the newest returned ID; nil only when the page is empty.
    public let lastID: String?
    public let handledTokens: [XMPPInboundToken]
}

extension XMPPArchivePage {
    /// The entries after `id` (all of them for nil) with every token of the page, for a page whose first entries were
    /// already handed out; `complete` is what the remainder says about newer entries. Nil when the page lacks `id`.
    public func entries(after id: String?, complete: Bool) -> XMPPArchivePage? {
        var index = messages.startIndex
        if let id {
            guard let found = messages.firstIndex(where: { $0.archiveID == id }) else { return nil }
            index = found + 1
        }
        let rest = Array(messages[index...])
        return .init(messages: rest, complete: complete, firstID: rest.first?.archiveID, lastID: rest.last?.archiveID, handledTokens: handledTokens)
    }

    /// The same entries, owing `tokens` instead once they are durable.
    public func owing(_ tokens: [XMPPInboundToken]) -> XMPPArchivePage {
        .init(messages: messages, complete: complete, firstID: firstID, lastID: lastID, handledTokens: tokens)
    }
}

/// An archive's newest entry, from `XMPPClient.newestArchiveEntry`.
public struct XMPPArchiveNewest: Sendable, Equatable {
    /// nil when the archive is empty.
    public let id: String?
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
    var walk: UUID? = nil
    var archiveOwner: String { room ?? accountBareJID }

    static let namespace = "urn:xmpp:mam:2"
    static let resultSetNamespace = "http://jabber.org/protocol/rsm"

    // An empty `<before/>` asks for the newest page (XEP-0059 §2.5, XEP-0313 §4.1).
    static func payload(queryID: String, limit: Int, bound: XMPPArchiveBound) -> String {
        var cursorXML = "", filterXML = ""
        switch bound {
        case .after(nil): break
        case .after(let id?): cursorXML = "<after>\(xmlEscaped(id))</after>"
        case .before(nil): cursorXML = "<before/>"
        case .before(let id?): cursorXML = "<before>\(xmlEscaped(id))</before>"
        // XEP-0082 UTC, whole seconds (truncated, so never later than asked).
        case .since(let date): filterXML = "<field var='start'><value>\(wholeTimestamp.string(from: date))</value></field>"
        }
        return "<query xmlns='\(namespace)' queryid='\(xmlEscaped(queryID))'><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'><value>\(namespace)</value></field>\(filterXML)</x><set xmlns='\(resultSetNamespace)'><max>\(limit)</max>\(cursorXML)</set></query>"
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
                // Valid outer provenance: record the rejection instead of blocking unrelated DMs.
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
        // Above: outer provenance, which throws. Below: inner content, which becomes a rejected entry recorded before
        // the cursor advances.
        if inner.attributes["to"] == nil {
            // Prosody stores incoming/self messages without their local recipient; ejabberd includes it. Normalized
            // only after the own-archive wrapper is authenticated.
            var attributes = inner.attributes; attributes["to"] = accountBareJID
            inner = XMLNode(name: inner.name, namespace: inner.namespace, attributes: attributes, text: inner.text, children: inner.children, attributePrefixes: inner.attributePrefixes)
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
        if inner.attributes["type"] == "error" {
            // A returned stanza echoes what we sent, ciphertext included: it is a bounce, never a message to decrypt.
            messages.append(.init(archiveID: id, timestamp: timestamp, message: nil, encryptedMessage: nil,
                                  messageError: outgoing ? nil : XMPPMessageError.parse(inner)))
            identifiers.insert(id); return
        }
        guard !Self.nestsWrapper(inner) else { return reject(.unsupportedDirectContent, peer: peer, outgoing: outgoing) }
        // Reuses authenticated own-account forwarding provenance; archive ID and time are separate.
        let provenance: XMPPMessageProvenance = outgoing ? .sentCarbon : .receivedCarbon
        var encrypted: XMPPEncryptedMessage?
        if OMEMOWire.hasEncryptedContent(inner) {
            let known = inner.children.filter { child in child.name == "encrypted" && XMPPOMEMOProfile.allCases.contains { $0.namespace == child.namespace } }
            guard known.count == 1 else { return reject(.unsupportedDirectContent, peer: peer, outgoing: outgoing) }
            do { encrypted = try OMEMOWire.parseMessage(inner, provenance: provenance); encrypted?.archiveStanzaID = id }
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
        let sets = fin.children("set", namespace: Self.resultSetNamespace)
        guard sets.count <= 1 else { throw XMPPIQError.malformedResponse }
        func bound(_ name: String) throws -> String? {
            guard let set = sets.first else { return nil }
            let nodes = set.children.filter { $0.name == name && $0.namespace == set.namespace }
            guard nodes.count <= 1 else { throw XMPPIQError.malformedResponse }
            return nodes.first?.text
        }
        let first = try bound("first"), last = try bound("last")
        // Results arrive oldest first in either direction, so the RSM bounds must name exactly the returned ends; an
        // empty page names neither.
        guard first == messages.first?.archiveID, last == messages.last?.archiveID else { throw XMPPIQError.malformedResponse }
        // An empty page offers no cursor, so it ends the walk. ejabberd sends `complete='false'` or no `<set/>` on some
        // empty pages (Monal 060db00d8, 0bacd2e2d); asking again would loop.
        return .init(messages: messages, complete: complete || messages.isEmpty, firstID: first, lastID: last, handledTokens: handledTokens)
    }

    // Never unwrapped a second time.
    static func nestsWrapper(_ inner: XMLNode) -> Bool {
        containsWrapper(inner) || Carbons.containsWrapper(inner) || inner.child("forwarded", namespace: Carbons.forwarding) != nil
    }

    // `ISO8601DateFormatter` is thread-safe for parsing and formatting, and nothing mutates these after initialization;
    // `nonisolated(unsafe)` only because the class is not `Sendable`.
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

extension XMPPClient {
    static let archiveProbeLimit = 32

    // A result belongs to the page query or a probe by its query ID; any other is handled at once and dropped.
    func receiveArchiveResult(_ node: XMLNode, inbound: XMPPInboundToken?) async throws {
        let queryID = node.child("result", namespace: ArchiveQuery.namespace)?.attributes["queryid"]
        if let queryID, var query = archiveQueries[queryID] {
            try query.receive(node)
            if let inbound { query.handledTokens.append(inbound) }
            archiveQueries[queryID] = query
        } else if let queryID, var probe = archiveProbes[queryID] {
            try probe.receive(node)
            if let inbound { probe.handledTokens.append(inbound) }
            archiveProbes[queryID] = probe
        } else if let inbound { try await streamManagement?.handled(inbound) }
    }

    /// The page queries one walk may have out at once.
    public static let archiveWalkQueryLimit = 4

    /// Persist every result and its archive position before acknowledging `handledTokens`. One bounded own-account
    /// query at a time, or `archiveWalkQueryLimit` of one `walk`, which must hand their pages out in archive order; no
    /// arbitrary archive sender is trusted.
    public func fetchArchivePage(_ bound: XMPPArchiveBound, limit: Int = 100, room: String? = nil, walk: UUID? = nil) async throws -> XMPPArchivePage {
        guard isOnline, let ownBare = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
        func free() -> Bool {
            archiveQueries.isEmpty || (walk != nil && archiveQueries.count < Self.archiveWalkQueryLimit && archiveQueries.values.allSatisfy { $0.walk == walk })
        }
        guard free(), (1...200).contains(limit), bound.cursor.map(validArchiveID) ?? true else { throw XMPPClientError.invalidConfiguration }
        // Later pages of a room reuse the validation its walk just did; sends never do (`refreshGroupRoom(_:)`).
        if let room { _ = try await refreshGroupRoom(room, reusingValidation: true) }
        guard isOnline, OMEMOWire.bareJID(boundJID) == ownBare, free() else { throw XMPPClientError.connectionClosed }
        let queryID = UUID().uuidString
        var query = ArchiveQuery(queryID: queryID, accountBareJID: ownBare, accountFullJID: boundJID, limit: limit)
        query.room = room
        query.knownRooms = Set(groupRooms.filter { !$0.value.members.isEmpty }.keys)
        query.walk = walk
        archiveQueries[queryID] = query
        defer { archiveQueries[queryID] = nil }
        let payload = ArchiveQuery.payload(queryID: queryID, limit: limit, bound: bound)
        do {
            let response = try await requestIQ(type: "set", to: room ?? ownBare, payload: payload, timeout: Self.archiveQueryTimeout)
            guard let query = archiveQueries[queryID] else { throw XMPPClientError.connectionClosed }
            return try query.finish(response)
        } catch {
            // A discarded partial page must not leave an acknowledgement gap; the unchanged cursor refetches it after
            // reconnect.
            if !(archiveQueries[queryID]?.handledTokens.isEmpty ?? true) {
                finish("Archive synchronization interrupted", error: error)
                if error is CancellationError { throw error }
                // Abandoning the partial page's unhandled tokens has already ended the transport.
                throw XMPPClientError.connectionClosed
            }
            throw error
        }
    }

    /// The ID of an archive's newest entry (nil when the archive is empty), so a caller can tell whether anything
    /// follows its checkpoint without a page. Content is neither returned nor validated, so a room needs no membership
    /// read; acknowledge `handledTokens`, nothing else is owed for them. Runs beside `fetchArchivePage`.
    public func newestArchiveEntry(room: String? = nil) async throws -> XMPPArchiveNewest {
        guard isOnline, let ownBare = OMEMOWire.bareJID(boundJID) else { throw XMPPClientError.notConnected }
        guard room.map({ OMEMOWire.bareJID($0) == $0 }) ?? true, archiveProbes.count < Self.archiveProbeLimit else {
            throw XMPPClientError.invalidConfiguration
        }
        let queryID = UUID().uuidString
        var probe = ArchiveQuery(queryID: queryID, accountBareJID: ownBare, accountFullJID: boundJID, limit: 1)
        probe.room = room
        archiveProbes[queryID] = probe
        defer { archiveProbes[queryID] = nil }
        let payload = ArchiveQuery.payload(queryID: queryID, limit: 1, bound: .before(nil))
        do {
            let response = try await requestIQ(type: "set", to: room ?? ownBare, payload: payload, timeout: Self.archiveQueryTimeout)
            guard let probe = archiveProbes[queryID] else { throw XMPPClientError.connectionClosed }
            let page = try probe.finish(response)
            return XMPPArchiveNewest(id: page.lastID, handledTokens: page.handledTokens)
        } catch {
            // As for a page: a result the caller never saw must not leave an acknowledgement gap.
            if !(archiveProbes[queryID]?.handledTokens.isEmpty ?? true) {
                finish("Archive synchronization interrupted", error: error)
                if error is CancellationError { throw error }
                throw XMPPClientError.connectionClosed
            }
            throw error
        }
    }

}

func validArchiveID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 1_024 && !id.contains(where: { $0.isWhitespace || $0.isNewline }) && id.unicodeScalars.allSatisfy { $0.value >= 32 }
}
