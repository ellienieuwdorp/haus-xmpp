import Foundation

public enum XMPPGroupError: Error, Sendable, Equatable {
    case unsupportedRoom, incompleteMembership, membershipChanged, notJoined, unknownOccupant, invalidMessage
}

extension XMPPGroupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedRoom: "This group's server settings do not support secure group messaging."
        case .incompleteMembership: "The complete group membership could not be verified."
        case .membershipChanged: "Group membership changed. Review the group before retrying."
        case .notJoined: "Reconnect to this group before sending."
        case .unknownOccupant: "This group message's author could not be verified."
        case .invalidMessage: "This encrypted group message could not be validated."
        }
    }
}

/// A complete member/admin/owner union obtained from the authenticated room service.
/// Occupant presence alone is never a membership list: offline members remain recipients.
public struct XMPPGroupRoomSnapshot: Sendable, Equatable, Codable {
    public let room: String
    public let members: [String]
    public let revision: UInt64
    public let joined: Bool
    public init(room: String, members: [String], revision: UInt64, joined: Bool) throws {
        guard OMEMOWire.bareJID(room) == room, !members.isEmpty, members.count <= 100,
              Set(members).count == members.count, members.allSatisfy({ OMEMOWire.bareJID($0) == $0 }) else { throw XMPPGroupError.incompleteMembership }
        self.room = room; self.members = members.sorted(); self.revision = revision; self.joined = joined
    }
    private enum CodingKeys: String, CodingKey { case room, members, revision, joined }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(room: values.decode(String.self, forKey: .room), members: values.decode([String].self, forKey: .members),
                      revision: values.decode(UInt64.self, forKey: .revision), joined: values.decode(Bool.self, forKey: .joined))
    }

}

/// Construct only after validating the room's occupant→real-JID mapping. The displayed
/// nickname is never the cryptographic sender identity.
public enum XMPPGroupProvenance: String, Sendable, Codable { case liveOccupant, ownArchive, roomArchive }

public struct XMPPEncryptedGroupMessage: Sendable, Equatable, Codable {
    public let id: String
    public let room: String
    public let occupant: String
    public let sender: String
    public let envelope: XMPPOMEMOEnvelope
    public let provenance: XMPPGroupProvenance
    public let roomStanzaID: String?
    /// Unencrypted outer `<body/>` fallback: a content hint only (see `XMPPEncryptedMessage.hasFallbackBody`).
    public let hasFallbackBody: Bool
    /// A live stanza our own server held for this session (see `XMPPEncryptedMessage.serverStamp`). Not encoded:
    /// a retained envelope keeps its time beside it.
    public var serverStamp: Date? = nil
    public init(id: String, room: String, occupant: String, sender: String, envelope: XMPPOMEMOEnvelope, provenance: XMPPGroupProvenance = .liveOccupant, roomStanzaID: String? = nil,
                hasFallbackBody: Bool = false) throws {
        guard OMEMOWire.validStanzaID(id), roomStanzaID.map(OMEMOWire.validStanzaID) ?? true, OMEMOWire.bareJID(room) == room,
              occupant.hasPrefix(room + "/"), occupant.utf8.count <= 3071, occupant.count > room.count + 1,
              OMEMOWire.bareJID(sender) == sender, envelope.profile == .modern else { throw XMPPGroupError.invalidMessage }
        self.id = id; self.room = room; self.occupant = occupant; self.sender = sender; self.envelope = envelope; self.provenance = provenance; self.roomStanzaID = roomStanzaID
        self.hasFallbackBody = hasFallbackBody
    }
    private enum CodingKeys: String, CodingKey { case id, room, occupant, sender, envelope, provenance, roomStanzaID, hasFallbackBody }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), room: values.decode(String.self, forKey: .room),
                      occupant: values.decode(String.self, forKey: .occupant), sender: values.decode(String.self, forKey: .sender),
                      envelope: values.decode(XMPPOMEMOEnvelope.self, forKey: .envelope),
                      provenance: values.decodeIfPresent(XMPPGroupProvenance.self, forKey: .provenance) ?? .liveOccupant,
                      roomStanzaID: values.decodeIfPresent(String.self, forKey: .roomStanzaID),
                      // Retained envelopes written before this field existed still decode.
                      hasFallbackBody: values.decodeIfPresent(Bool.self, forKey: .hasFallbackBody) ?? false)
    }

}

struct GroupRoomState {
    var members: [String] = []
    var occupants: [String: String] = [:]
    var revision: UInt64 = 0
    var joined = false
    /// The room answered our last join with an error presence (not a member, banned, nickname taken, room gone).
    var joinRefused = false
    var nickname: String?
    /// The `revision` at which `members` was last validated by this connection.
    var validatedRevision: UInt64? = nil

    /// How much reading a membership refresh needs. Occupant presence and nickname changes bump `revision`,
    /// so an unchanged revision means no presence this connection can observe has changed since validation.
    private var refreshDecision: GroupRoomRefreshDecision {
        guard !members.isEmpty, let validatedRevision else { return .readTwice }
        return validatedRevision == revision ? .cached : .readOnceExpecting(members)
    }

    /// An unchanged revision does not mean unchanged membership: granting or revoking membership for a user
    /// who is not in the room sends no presence (XEP-0045 §9.3, §9.4). Only the archive paging path may reuse
    /// the validation; sends and key distribution read at least once so an added member gets the key and a
    /// removed one stops getting it.
    func refreshDecision(reusingValidation: Bool) -> GroupRoomRefreshDecision {
        let decision = refreshDecision
        guard !reusingValidation, decision == .cached else { return decision }
        return .readOnceExpecting(members)
    }

    mutating func markValidated(_ members: [String]) {
        self.members = members
        validatedRevision = revision
    }

    mutating func requestNickname(_ nickname: String) {
        joinRefused = false
        guard self.nickname != nickname else { return }
        self.nickname = nickname
        joined = false
        revision &+= 1
    }
}

enum GroupRoomRefreshDecision: Equatable {
    /// No presence changed since the last validation: return the stored snapshot, zero IQs.
    case cached
    /// Presence changed: one read; accept it without a second read when it equals the last validated list.
    case readOnceExpecting([String])
    /// Never validated on this connection: two agreeing reads.
    case readTwice
}

/// One in-flight membership validation, shared by every caller that asks for the room meanwhile.
/// It is cancelled only when every waiter was cancelled, or by `finish` with the connection.
struct GroupRoomRefresh: Sendable {
    let id: UUID
    let task: Task<XMPPGroupRoomSnapshot, Error>
    var waiters: Int
}

/// In-flight refreshes are kept apart by whether they may answer from the cache: a caller that must read
/// never joins one that may not read.
struct GroupRoomRefreshKey: Hashable, Sendable {
    let room: String
    let reusesValidation: Bool

    /// The in-flight refreshes a caller may join, most thorough first.
    static func joinable(room: String, reusingValidation: Bool) -> [GroupRoomRefreshKey] {
        let reading = GroupRoomRefreshKey(room: room, reusesValidation: false)
        return reusingValidation ? [reading, GroupRoomRefreshKey(room: room, reusesValidation: true)] : [reading]
    }
}

enum GroupChatWire {
    static let muc = "http://jabber.org/protocol/muc"
    static let user = muc + "#user"
    static let admin = muc + "#admin"
    static let disco = "http://jabber.org/protocol/disco#info"
    static func checkFeatures(_ reply: XMLNode, room: String) throws {
        guard reply.attributes["from"] == room else { throw XMPPGroupError.unsupportedRoom }
        let query = try OMEMOWire.singleton(reply, "query", disco)
        let features = Set(query.children.filter { $0.name == "feature" && $0.namespace == disco }.compactMap { $0.attributes["var"] })
        guard features.contains("muc_nonanonymous"), features.contains("muc_membersonly"), features.contains("urn:xmpp:sid:0"),
              !features.contains("muc_semianonymous"), !features.contains("muc_open") else { throw XMPPGroupError.unsupportedRoom }
    }
    static func members(_ reply: XMLNode, room: String, affiliation: String) throws -> [String] {
        guard reply.attributes["from"] == room else { throw XMPPGroupError.incompleteMembership }
        let query = try OMEMOWire.singleton(reply, "query", admin)
        guard query.children.count <= 100 else { throw XMPPGroupError.incompleteMembership }
        return try query.children.map { item in
            guard item.name == "item", item.namespace == admin, item.attributes["affiliation"] == affiliation,
                  let jid = item.attributes["jid"], !jid.contains("/"), let bare = OMEMOWire.bareJID(jid) else { throw XMPPGroupError.incompleteMembership }
            return bare
        }
    }
    static func message(_ node: XMLNode, account: String, room: String, state: GroupRoomState) throws -> XMPPEncryptedGroupMessage {
        guard node.name == "message", node.namespace == "jabber:client", node.attributes["type"] == "groupchat",
              let occupant = node.attributes["from"], OMEMOWire.bareJID(occupant) == room,
              let sender = state.occupants[occupant], state.members.contains(sender), state.joined,
              node.attributes["to"].map({ OMEMOWire.bareJID($0) == account }) ?? true,
              node.children.filter({ $0.name == "encrypted" }).count == 1,
              let encrypted = node.children.first(where: { $0.name == "encrypted" }) else { throw XMPPGroupError.unknownOccupant }
        let xs = node.children.filter { $0.name == "x" && $0.namespace == user }
        guard xs.count <= 1 else { throw XMPPGroupError.unknownOccupant }
        if let x = xs.first {
            let items = x.children.filter { $0.name == "item" && $0.namespace == user }
            guard items.count <= 1 else { throw XMPPGroupError.unknownOccupant }
            if let jid = items.first?.attributes["jid"] {
                guard OMEMOWire.bareJID(jid) == sender else { throw XMPPGroupError.unknownOccupant }
            }
        }
        return try XMPPEncryptedGroupMessage(id: node.attributes["id"] ?? UUID().uuidString, room: room, occupant: occupant,
                                             sender: sender, envelope: OMEMOWire.parseEnvelope(encrypted), roomStanzaID: stanzaID(node, room: room),
                                             hasFallbackBody: !node.children("body", namespace: "jabber:client").isEmpty)
    }
    /// Only called inside an authenticated MAM query. Historical nicknames cannot use
    /// today's occupant map: the service must include the archived author's real JID.
    static func archivedMessage(_ node: XMLNode, account: String, archiveRoom: String?, knownRooms: Set<String>, archiveID: String? = nil) throws -> XMPPEncryptedGroupMessage {
        guard node.attributes["type"] == "groupchat", let from = node.attributes["from"],
              let fromBare = OMEMOWire.bareJID(from), node.children.filter({ $0.name == "encrypted" }).count == 1,
              let encrypted = node.children.first(where: { $0.name == "encrypted" }) else { throw XMPPGroupError.invalidMessage }
        let room: String, sender: String, occupant: String
        if archiveRoom == nil, fromBare == account, let to = node.attributes["to"], OMEMOWire.bareJID(to) == to, to != account {
            room = to; sender = account; occupant = room + "/archived-own-device"
        } else {
            room = fromBare; occupant = from
            guard room != account, archiveRoom.map({ $0 == room && knownRooms.contains(room) }) ?? true, from.hasPrefix(room + "/"),
                  node.attributes["to"].map({ OMEMOWire.bareJID($0) == account }) ?? true else { throw XMPPGroupError.invalidMessage }
            let xs = node.children.filter { $0.name == "x" && $0.namespace == user }
            guard xs.count == 1 else { throw XMPPGroupError.unknownOccupant }
            let items = xs[0].children.filter { $0.name == "item" && $0.namespace == user }
            guard items.count == 1, let jid = items[0].attributes["jid"].flatMap(OMEMOWire.bareJID) else { throw XMPPGroupError.unknownOccupant }
            sender = jid
        }
        return try .init(id: node.attributes["id"] ?? UUID().uuidString, room: room, occupant: occupant, sender: sender,
                         envelope: OMEMOWire.parseEnvelope(encrypted), provenance: archiveRoom == nil ? .ownArchive : .roomArchive,
                         roomStanzaID: stanzaID(node, room: room, archiveID: archiveRoom == nil ? nil : archiveID),
                         hasFallbackBody: !node.children("body", namespace: "jabber:client").isEmpty)
    }
    static func stanzaID(_ node: XMLNode, room: String, archiveID: String? = nil) throws -> String? {
        let identifiers = node.children.filter { $0.name == "stanza-id" && $0.namespace == "urn:xmpp:sid:0" && $0.attributes["by"].flatMap(JID.normalized) == room }
        guard identifiers.count <= 1 else { throw XMPPGroupError.invalidMessage }
        let value = identifiers.first?.attributes["id"]
        if let identifier = identifiers.first {
            guard let value, OMEMOWire.validStanzaID(value), identifier.children.isEmpty, identifier.text.isEmpty else { throw XMPPGroupError.invalidMessage }
        }
        if let archiveID {
            guard OMEMOWire.validStanzaID(archiveID), value.map({ $0 == archiveID }) ?? true else { throw XMPPGroupError.invalidMessage }
        }
        // XEP-0444 requires the room-assigned stanza-id element; a MAM cursor alone
        // does not turn a message without that extension into a reaction target.
        return value
    }
    static func applyPresence(_ node: XMLNode, room: String, account: String, state: inout GroupRoomState) {
        guard let occupant = node.attributes["from"], occupant.hasPrefix(room + "/"),
              node.attributes["to"].map({ OMEMOWire.bareJID($0) == account }) ?? true else { return }
        state.revision &+= 1
        let ownOccupant = occupant == room + "/" + (state.nickname ?? "")
        let xs = node.children.filter { $0.name == "x" && $0.namespace == user }
        let items = xs.first?.children.filter { $0.name == "item" && $0.namespace == user } ?? []
        // Nonanonymous rooms can expose one item per session of the same occupant.
        // All entries must still describe exactly one real identity and affiliation.
        guard node.attributes["type"] == nil, xs.count == 1, !items.isEmpty, items.count <= 100,
              let jid = items[0].attributes["jid"].flatMap(OMEMOWire.bareJID),
              let affiliation = items[0].attributes["affiliation"], ["member", "admin", "owner"].contains(affiliation),
              items.allSatisfy({ $0.attributes["jid"].flatMap(OMEMOWire.bareJID) == jid && $0.attributes["affiliation"] == affiliation }) else {
            state.occupants[occupant] = nil
            if ownOccupant { state.joined = false; state.joinRefused = node.attributes["type"] == "error" }
            return
        }
        // Keep authenticated presence for a newly added member; a complete membership
        // refresh is still required before this mapping can authorize message routing.
        state.occupants[occupant] = jid
        if ownOccupant {
            state.joined = jid == account && xs[0].children.contains {
                $0.name == "status" && $0.namespace == user && $0.attributes["code"] == "110"
            }
        }
    }
    static func outgoing(room: String, envelope: XMPPOMEMOEnvelope, id: String) throws -> String {
        guard envelope.profile == .modern, envelope.payload != nil, OMEMOWire.bareJID(room) == room else { throw XMPPGroupError.invalidMessage }
        return try OMEMOWire.messageXML(to: room, envelope: envelope, id: id).replacingOccurrences(of: "type='chat'", with: "type='groupchat'")
    }
}

extension XMPPClient {
    /// The room refused our last join (an error presence to it); a later join clears this.
    public func groupRoomRefusedJoin(_ room: String) -> Bool { groupRooms[room]?.joinRefused == true }
    public func groupRoomSnapshot(_ room: String) throws -> XMPPGroupRoomSnapshot? {
        guard let state = groupRooms[room], !state.members.isEmpty else { return nil }
        return try .init(room: room, members: state.members, revision: state.revision, joined: state.joined)
    }
    func validateGroupWrite(_ snapshot: XMPPGroupRoomSnapshot?) throws {
        guard let snapshot else { return }
        guard let current = groupRooms[snapshot.room], current.joined,
              current.revision == snapshot.revision, current.members == snapshot.members else { throw XMPPGroupError.membershipChanged }
    }

    /// The server offers no transactional membership revision. The first validation on a connection
    /// requires two matching full reads with no intervening presence change. Every later refresh reads at
    /// least once and accepts one read that equals the last validated list: a change and its reversal between
    /// reads is invisible to two reads as well. Used by sends, joins and OMEMO's group key distribution.
    /// Callers must still revalidate before send (`validateGroupWrite` compares the revision at write time).
    public func refreshGroupRoom(_ room: String) async throws -> XMPPGroupRoomSnapshot {
        try await refreshGroupRoom(room, reusingValidation: false)
    }

    /// `reusingValidation: true` also returns this connection's last validated list without any read while no
    /// occupant presence or nickname change arrived. Only for archive paging after the walk validated the room:
    /// affiliation changes for absent users send no presence, so this may be stale for the rest of the walk.
    public func refreshGroupRoom(_ room: String, reusingValidation: Bool) async throws -> XMPPGroupRoomSnapshot {
        let account = try groupAccount()
        guard OMEMOWire.bareJID(room) == room else { throw XMPPGroupError.unsupportedRoom }
        if groupRooms[room] == nil { groupRooms[room] = GroupRoomState() }
        let key: GroupRoomRefreshKey
        let refresh: GroupRoomRefresh
        if let joined = GroupRoomRefreshKey.joinable(room: room, reusingValidation: reusingValidation).first(where: { roomRefreshes[$0] != nil }),
           var shared = roomRefreshes[joined] {
            shared.waiters += 1
            roomRefreshes[joined] = shared
            key = joined
            refresh = shared
        } else {
            let id = UUID()
            key = GroupRoomRefreshKey(room: room, reusesValidation: reusingValidation)
            refresh = GroupRoomRefresh(id: id, task: Task { try await self.validateGroupRoom(room, account: account, key: key, refresh: id) }, waiters: 1)
            roomRefreshes[key] = refresh
        }
        return try await withTaskCancellationHandler {
            try await refresh.task.value
        } onCancel: {
            Task { await self.leaveGroupRoomRefresh(key, id: refresh.id) }
        }
    }
    private func leaveGroupRoomRefresh(_ key: GroupRoomRefreshKey, id: UUID) {
        guard var refresh = roomRefreshes[key], refresh.id == id else { return }
        refresh.waiters -= 1
        if refresh.waiters > 0 { roomRefreshes[key] = refresh; return }
        roomRefreshes[key] = nil
        refresh.task.cancel()
    }
    private func validateGroupRoom(_ room: String, account: String, key: GroupRoomRefreshKey, refresh id: UUID) async throws -> XMPPGroupRoomSnapshot {
        defer { if roomRefreshes[key]?.id == id { roomRefreshes[key] = nil } }
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard let current = groupRooms[room] else { throw XMPPGroupError.notJoined }
            let revision = current.revision
            let members: [String]
            switch current.refreshDecision(reusingValidation: key.reusesValidation) {
            case .cached:
                return try XMPPGroupRoomSnapshot(room: room, members: current.members, revision: revision, joined: current.joined)
            case .readOnceExpecting(let previous):
                let first = try await readGroupMembers(room)
                guard revision == groupRooms[room]?.revision else { continue }
                if first == previous { members = first; break }
                let second = try await readGroupMembers(room)
                guard first == second, revision == groupRooms[room]?.revision else { continue }
                members = first
            case .readTwice:
                let first = try await readGroupMembers(room)
                let second = try await readGroupMembers(room)
                guard first == second, revision == groupRooms[room]?.revision else { continue }
                members = first
            }
            guard members.contains(account) else { throw XMPPGroupError.incompleteMembership }
            guard try groupAccount() == account, var state = groupRooms[room] else { throw XMPPGroupError.notJoined }
            state.markValidated(members)
            state.occupants = state.occupants.filter { members.contains($0.value) }
            groupRooms[room] = state
            return try XMPPGroupRoomSnapshot(room: room, members: members, revision: revision, joined: state.joined)
        }
        throw XMPPGroupError.membershipChanged
    }
    private func readGroupMembers(_ room: String) async throws -> [String] {
        let disco = try await requestIQ(type: "get", to: room, payload: "<query xmlns='\(GroupChatWire.disco)'/>")
        try GroupChatWire.checkFeatures(disco, room: room)
        var all: [String] = []
        for affiliation in ["member", "admin", "owner"] {
            let reply = try await requestIQ(type: "get", to: room, payload: "<query xmlns='\(GroupChatWire.admin)'><item affiliation='\(affiliation)'/></query>")
            all += try GroupChatWire.members(reply, room: room, affiliation: affiliation)
        }
        guard !all.isEmpty, all.count <= 100, Set(all).count == all.count else { throw XMPPGroupError.incompleteMembership }
        return all.sorted()
    }
    public func joinGroupRoom(_ room: String, nickname: String) async throws -> XMPPGroupRoomSnapshot {
        guard !nickname.isEmpty, nickname.utf8.count <= 128, !nickname.contains("/"),
              !nickname.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw XMPPGroupError.invalidMessage }
        _ = try await refreshGroupRoom(room)
        guard var state = groupRooms[room] else { throw XMPPGroupError.notJoined }
        state.requestNickname(nickname)
        groupRooms[room] = state
        let snapshot = try XMPPGroupRoomSnapshot(room: room, members: state.members, revision: state.revision, joined: state.joined)
        try await groupWrite("<presence to='\(xmlEscaped(room + "/" + nickname))'><x xmlns='\(GroupChatWire.muc)'><history maxstanzas='0'/></x></presence>")
        return snapshot
    }
    public func leaveGroupRoom(_ room: String) async throws {
        guard let nickname = groupRooms[room]?.nickname else { return }
        groupRooms[room] = nil
        try await groupWrite("<presence to='\(xmlEscaped(room + "/" + nickname))' type='unavailable'/>")
    }
    public func sendEncryptedGroupMessage(room: String, envelope: XMPPOMEMOEnvelope, id: String,
                                           expectedMembers: [String]) async throws -> String {
        let snapshot = try await refreshGroupRoom(room)
        guard snapshot.joined else { throw XMPPGroupError.notJoined }
        guard snapshot.members == expectedMembers.sorted() else { throw XMPPGroupError.membershipChanged }
        try await groupWrite(GroupChatWire.outgoing(room: room, envelope: envelope, id: id), snapshot: snapshot)
        return id
    }
}
