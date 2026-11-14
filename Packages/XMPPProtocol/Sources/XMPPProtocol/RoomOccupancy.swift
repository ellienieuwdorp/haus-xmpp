import Foundation

// Exact as of `handled` inbound stanzas, the `h` its resume sends, so the server redelivers just what followed. At any
// other count stanzas would be replayed onto it or skipped, which can map a reused nickname to the wrong member.
struct RetainedGroupRooms: Codable, Sendable, Equatable {
    let handled: UInt64
    let rooms: [RetainedGroupRoom]
}

struct RetainedGroupRoom: Codable, Sendable, Equatable {
    let room: String
    let nickname: String
    let members: [String]
    let occupants: [String: String]

    static let limit = 1_000

    init(room: String, nickname: String, members: [String], occupants: [String: String]) {
        self.room = room; self.nickname = nickname; self.members = members; self.occupants = occupants
    }

    init?(room: String, state: GroupRoomState, account: String) {
        guard state.joined, state.validatedRevision != nil, !state.members.isEmpty, let nickname = state.nickname,
              state.occupants[room + "/" + nickname] == account else { return nil }
        self.init(room: room, nickname: nickname, members: state.members, occupants: state.occupants)
    }

    // Validated as on the wire: saved state is never trusted more than the stanzas it came from.
    func state(account: String) -> GroupRoomState? {
        guard OMEMOWire.bareJID(room) == room, GroupChatWire.validNickname(nickname),
              (try? XMPPGroupRoomSnapshot(room: room, members: members, revision: 0, joined: true)) != nil,
              members.contains(account), occupants.count <= Self.limit, occupants[room + "/" + nickname] == account,
              occupants.allSatisfy({ $0.key.hasPrefix(room + "/") && $0.key.count > room.count + 1 && OMEMOWire.bareJID($0.value) == $0.value })
        else { return nil }
        return GroupRoomState(members: members.sorted(), occupants: occupants, revision: 0, joined: true, nickname: nickname,
                              validatedRevision: 0, restored: true)
    }
}

extension XMPPClient {
    public static let selfPingTimeout: Duration = .seconds(10)

    func countInbound(_ node: XMLNode) async throws -> XMPPInboundToken? {
        guard ["message", "iq", "presence"].contains(node.name), node.namespace == "jabber:client",
              let token = try await streamManagement?.receive() else { return nil }
        lastInboundSequence = token.sequence
        return token
    }

    // Occupancy taken before `finish` clears it is saved only if nothing was counted after it (`retain`).
    func close(joining reader: Task<Void, Never>?) async {
        let rooms = phase == .online ? retainableGroupRooms() : [], through = lastInboundSequence
        finish(nil)
        await reader?.value
        // After the socket is gone, so a held journal gate never delays the cancel; a lagging count only redelivers.
        _ = try? await streamManagement?.flushHandled()
        // Unsaved occupancy only means the next resume rejoins.
        try? await streamManagement?.retain(rooms, through: through)
    }

    /// Rooms a resume restored that route held stanzas but wait for `confirmRestoredGroupRoom` to send; by nickname.
    public func restoredGroupRooms() -> [String: String] {
        groupRooms.reduce(into: [:]) { rooms, entry in
            if entry.value.restored, entry.value.joined, let nickname = entry.value.nickname { rooms[entry.key] = nickname }
        }
    }

    /// XEP-0410 §3.2: a result, `service-unavailable` or `feature-not-implemented` mean the room still counts us. Anything
    /// else, a timeout included, ends the restored occupancy, so the caller joins as after a fresh bind.
    public func confirmRestoredGroupRoom(_ room: String, within limit: Duration = XMPPClient.selfPingTimeout) async -> Bool {
        guard let state = groupRooms[room], let nickname = state.nickname else { return false }
        guard state.restored else { return state.sendable }
        let token = generation
        let confirmed: Bool
        do {
            _ = try await requestIQ(type: "get", to: room + "/" + nickname, payload: "<ping xmlns='urn:xmpp:ping'/>", timeout: limit)
            confirmed = true
        } catch XMPPIQError.stanza(let condition) {
            confirmed = ["service-unavailable", "feature-not-implemented"].contains(condition)
        } catch {
            confirmed = false
        }
        guard generation == token, !Task.isCancelled, var current = groupRooms[room], current.nickname == nickname else { return false }
        guard current.restored else { return current.sendable }
        if confirmed, current.joined {
            current.restored = false
        } else {
            // The occupant list may be stale; only a join brings it back.
            current.restored = false; current.joined = false; current.occupants = [:]; current.revision &+= 1
        }
        groupRooms[room] = current
        return current.sendable
    }

    // Before anything redelivered is read; a malformed room drops the whole set.
    func restoreGroupRooms(from snapshot: XMPPStreamManagementSnapshot) {
        guard let retained = snapshot.retainedRooms, retained.handled == snapshot.inboundHandled,
              retained.rooms.count <= RetainedGroupRoom.limit, let account = OMEMOWire.bareJID(snapshot.fullJID) else { return }
        var restored: [String: GroupRoomState] = [:]
        for room in retained.rooms {
            guard restored[room.room] == nil, let state = room.state(account: account) else { return }
            restored[room.room] = state
        }
        groupRooms = restored
    }

    func retainableGroupRooms() -> [RetainedGroupRoom] {
        guard let account = OMEMOWire.bareJID(boundJID) else { return [] }
        return groupRooms.keys.sorted().compactMap { room in groupRooms[room].flatMap { RetainedGroupRoom(room: room, state: $0, account: account) } }
    }
}
