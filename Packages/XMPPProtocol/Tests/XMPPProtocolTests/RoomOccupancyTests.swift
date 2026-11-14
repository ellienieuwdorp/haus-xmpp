import Foundation
import Testing
@testable import XMPPProtocol

// Room occupancy across a stream-management resume: what a clean detach keeps, what the resume restores, and the
// XEP-0410 self-ping that confirms it, through `XMPPClient`'s own socket against `LoopbackServer`.
@Suite(.serialized)
struct RoomOccupancyTests {
    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        init(_ value: XMPPStreamManagementSnapshot?) { self.value = value }
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
    }

    private static let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"
    private static let alice = "alice@localhost", bob = "bob@localhost", room = "room@rooms.localhost"
    private static let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 7,
                                                    keys: [.init(recipientJID: alice, deviceID: 9, keyExchange: false, data: Data([1]))],
                                                    payload: Data([2]))

    private static func occupantPresence(_ room: String, nickname: String, jid: String, own: Bool = false) -> String {
        "<presence from='\(room)/\(nickname)' to='\(alice)/r'><x xmlns='\(GroupChatWire.user)'><item affiliation='member' jid='\(jid)/phone'/>"
            + (own ? "<status code='110'/>" : "") + "</x></presence>"
    }

    // An encrypted room message from `nickname`, as the room delivers it to us.
    private static func groupMessage(_ id: String, room: String = room, nickname: String = "bob") throws -> String {
        try GroupChatWire.outgoing(room: room, envelope: envelope, id: id)
            .replacingOccurrences(of: "to='\(room)'", with: "from='\(room)/\(nickname)' to='\(alice)/r'")
    }

    private static func retained(_ rooms: [String], handled: UInt64) -> XMPPStreamManagementSnapshot {
        var snapshot = XMPPStreamManagementSnapshot(revision: 1, accountID: alice, fullJID: alice + "/r", streamID: "s2", expiresAt: nil,
                                                    inboundHandled: handled, outboundSent: 0, outboundAcknowledged: 0, journal: [])
        snapshot.capabilities = EntityCapabilities.verification
        snapshot.availability = .active
        snapshot.retainedRooms = RetainedGroupRooms(handled: handled, rooms: rooms.map {
            RetainedGroupRoom(room: $0, nickname: "alice", members: [alice, bob], occupants: [$0 + "/alice": alice, $0 + "/bob": bob])
        })
        return snapshot
    }

    // Binds alice@localhost/r and enables `s2`.
    private func bindFresh(_ client: XMPPClient, on server: LoopbackServer) async throws {
        async let online: Void = server.connect(client)
        try await server.authenticate()
        let bind = try await server.next()
        let jid = "<jid>\(Self.alice)/r</jid>"
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(Self.bindNamespace)'>\(jid)</bind></iq>")
        #expect(try await server.next().name == "enable")
        try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
    }

    // Resumes `s2` on a new connection; the server received everything sent before.
    private func resume(_ persistence: Persistence) async throws -> (LoopbackServer, XMPPClient) {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await client.configureStreamManagement(persistence: persistence)
        try await client.setAvailability(.active, clientActive: true)
        async let online: Void = server.connect(client)
        try await server.authenticate()
        #expect(try await server.next().name == "resume")
        let sent = await persistence.value?.outboundSent ?? 0
        try await server.send("<resumed xmlns='urn:xmpp:sm:3' previd='s2' h='\(sent)'/>")
        try await online
        #expect(await client.sessionResumed)
        return (server, client)
    }

    // One full membership read: alice owns the room and bob is its member.
    private func answerMembershipRead(_ server: LoopbackServer, room: String = room) async throws {
        for _ in 0..<4 {
            let query = try await server.next()
            let id = query.attributes["id"] ?? ""
            if query.child("query", namespace: GroupChatWire.disco) != nil {
                let features = "<feature var='muc_nonanonymous'/><feature var='muc_membersonly'/><feature var='urn:xmpp:sid:0'/>"
                try await server.send("<iq type='result' from='\(room)' id='\(id)'><query xmlns='\(GroupChatWire.disco)'>\(features)</query></iq>")
            } else {
                let affiliation = query.child("query", namespace: GroupChatWire.admin)?.child("item", namespace: GroupChatWire.admin)?.attributes["affiliation"]
                let item = switch affiliation {
                case "owner": "<item affiliation='owner' jid='\(Self.alice)'/>"
                case "member": "<item affiliation='member' jid='\(Self.bob)'/>"
                default: ""
                }
                try await server.send("<iq type='result' from='\(room)' id='\(id)'><query xmlns='\(GroupChatWire.admin)'>\(item)</query></iq>")
            }
        }
    }

    // The client's next self-pings, by the occupant they address; anything else it writes meanwhile is skipped.
    private func selfPings(_ count: Int, on server: LoopbackServer) async throws -> [String: String] {
        var pings: [String: String] = [:]
        while pings.count < count {
            let node = try await server.next()
            guard node.name == "iq", node.child("ping", namespace: "urn:xmpp:ping") != nil, let to = node.attributes["to"] else { continue }
            pings[to] = node.attributes["id"] ?? ""
        }
        return pings
    }

    private static func failure(_ condition: String, from: String, id: String) -> String {
        "<iq type='error' from='\(from)' id='\(id)'><error type='cancel'><\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
    }

    @Test func aCleanDetachKeepsTheOccupancyAndItsResumeRoutesWhatTheServerHeld() async throws {
        let persistence = Persistence(nil)
        do {
            let server = try await LoopbackServer.start()
            let client = server.client()
            try await client.configureStreamManagement(persistence: persistence)
            var events = client.events.makeAsyncIterator()
            try await bindFresh(client, on: server)
            async let joining = client.joinGroupRoom(Self.room, nickname: "alice")
            try await answerMembershipRead(server)
            try await answerMembershipRead(server)
            #expect(try await server.next().name == "presence")
            _ = try await joining
            try await server.send(Self.occupantPresence(Self.room, nickname: "bob", jid: Self.bob)
                + Self.occupantPresence(Self.room, nickname: "alice", jid: Self.alice, own: true))
            var presences = 0
            while presences < 2, let event = await events.next() { if case .groupPresence = event { presences += 1 } }
            #expect(try await client.groupRoomSnapshot(Self.room)?.joined == true)
            async let closed: Void = client.disconnectAndWait()
            _ = try await server.remainder()
            await closed
            await server.stop()
        }
        let saved = try #require(await persistence.value)
        let retained = try #require(saved.retainedRooms)
        #expect(retained.handled == saved.inboundHandled)
        #expect(retained.rooms == [RetainedGroupRoom(room: Self.room, nickname: "alice", members: [Self.alice, Self.bob],
                                                     occupants: [Self.room + "/alice": Self.alice, Self.room + "/bob": Self.bob])])

        let (server, client) = try await resume(persistence)
        var events = client.events.makeAsyncIterator()
        // Consumed by this resume: a later one of the same count must not restore it over what this session does.
        #expect(await persistence.value?.retainedRooms == nil)
        #expect(await client.restoredGroupRooms() == [Self.room: "alice"])
        // Routing what the server held needs no confirmation; sending does.
        #expect(try await client.groupRoomSnapshot(Self.room)?.joined == false)
        try await server.send(try Self.groupMessage("held"))
        var routed: XMPPEncryptedGroupMessage?
        while routed == nil, let event = await events.next() {
            if case .encryptedGroupMessage(let message) = event { routed = message }
            if case .encryptionFailure = event { break }
        }
        #expect(routed?.sender == Self.bob && routed?.occupant == Self.room + "/bob")
        async let confirmed = client.confirmRestoredGroupRoom(Self.room)
        let pings = try await selfPings(1, on: server)
        let id = try #require(pings[Self.room + "/alice"])
        try await server.send("<iq type='result' from='\(Self.room)/alice' id='\(id)'/>")
        #expect(await confirmed)
        #expect(try await client.groupRoomSnapshot(Self.room)?.joined == true)
        #expect(await client.restoredGroupRooms().isEmpty)
        await client.disconnect()
        await server.stop()
    }

    // XEP-0410 §3.2: a result, or an error only a joined client's own answer produces, confirms; anything else (not an
    // occupant, an unreachable service) ends the restored occupancy, and so does a room returning our message first.
    @Test func selfPingAnswersDecideWhetherARestoredRoomStillCountsUs() async throws {
        let rooms = (1...5).map { "r\($0)@rooms.localhost" }
        let persistence = Persistence(Self.retained(rooms, handled: 3))
        let (server, client) = try await resume(persistence)
        var events = client.events.makeAsyncIterator()
        #expect(await client.restoredGroupRooms().count == 5)
        let notAcceptable = "<error type='cancel'><not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>"
        try await server.send("<message from='\(rooms[4])' to='\(Self.alice)/r' type='error' id='g1'>\(notAcceptable)</message>")
        while let event = await events.next() { if case .messageError = event { break } }
        let answers = await withTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
            for room in rooms { group.addTask { (room, await client.confirmRestoredGroupRoom(room)) } }
            let pings = try? await selfPings(4, on: server)
            for (occupant, id) in pings ?? [:] {
                let reply = switch occupant {
                case rooms[0] + "/alice": "<iq type='result' from='\(occupant)' id='\(id)'/>"
                case rooms[1] + "/alice": Self.failure("service-unavailable", from: occupant, id: id)
                case rooms[2] + "/alice": Self.failure("not-acceptable", from: occupant, id: id)
                default: Self.failure("remote-server-timeout", from: occupant, id: id)
                }
                try? await server.send(reply)
            }
            var answers: [String: Bool] = [:]
            for await (room, answer) in group { answers[room] = answer }
            return answers
        }
        #expect(answers == [rooms[0]: true, rooms[1]: true, rooms[2]: false, rooms[3]: false, rooms[4]: false])
        for (index, room) in rooms.enumerated() {
            #expect(try await client.groupRoomSnapshot(room)?.joined == (index < 2))
        }
        #expect(await client.restoredGroupRooms().isEmpty)
        // Not an occupant: the old occupant list no longer names anyone.
        try await server.send(try Self.groupMessage("stale", room: rooms[2]))
        var failed = false
        while let event = await events.next() {
            if case .encryptionFailure = event { failed = true; break }
            if case .encryptedGroupMessage = event { break }
        }
        #expect(failed)
        await client.disconnect()
        await server.stop()
    }

    // A count other than the saved one describes other stanzas; a fresh bind starts with nothing.
    @Test func occupancyIsKeptOnlyWhenItDescribesTheSavedCount() async throws {
        let persistence = Persistence(nil)
        let management = StreamManagement(persistence)
        try await management.enable(accountID: Self.alice, fullJID: Self.alice + "/r", streamID: "s1")
        let rooms = [RetainedGroupRoom(room: Self.room, nickname: "alice", members: [Self.alice], occupants: [Self.room + "/alice": Self.alice])]
        // Nothing counted yet on this connection.
        try await management.retain(rooms, through: nil)
        #expect(await persistence.value?.retainedRooms?.handled == 0)
        let first = try #require(try await management.receive())
        // Counted but not handled, or counted after what the client applied: neither is exact.
        try await management.retain(rooms, through: first.sequence)
        #expect(await persistence.value?.retainedRooms?.handled == 0)
        try await management.handled(first)
        try await management.retain(rooms, through: nil)
        #expect(await persistence.value?.retainedRooms?.handled == 0)
        try await management.retain(rooms, through: first.sequence)
        let kept = try #require(await persistence.value)
        #expect(kept.retainedRooms?.handled == 1 && kept.inboundHandled == 1)
        // A later handled count leaves the saved rooms describing an earlier one, which no resume restores.
        let second = try #require(try await management.receive())
        try await management.handled([second])
        let moved = try #require(await persistence.value)
        #expect(moved.inboundHandled == 2 && moved.retainedRooms?.handled == 1)
        let client = XMPPClient()
        await client.restoreGroupRooms(from: moved)
        #expect(await client.restoredGroupRooms().isEmpty)
        await client.restoreGroupRooms(from: kept)
        #expect(await client.restoredGroupRooms() == [Self.room: "alice"])
        // The resume that restores it consumes it.
        _ = try await management.restore(accountID: Self.alice)
        _ = try await management.acknowledge(0, resumed: true)
        #expect(await persistence.value?.retainedRooms == nil)
        try await management.retain(rooms, through: nil)
        try await management.enable(accountID: Self.alice, fullJID: Self.alice + "/r", streamID: "s3")
        #expect(await persistence.value?.retainedRooms == nil)
    }

    // Saved state is held to the wire's rules; one bad room drops the whole set.
    @Test func restoredOccupancyIsValidatedLikeTheStanzasItCameFrom() async {
        func restored(_ rooms: [RetainedGroupRoom]) async -> [String: String] {
            var snapshot = Self.retained([], handled: 4)
            snapshot.retainedRooms = RetainedGroupRooms(handled: 4, rooms: rooms)
            let client = XMPPClient()
            await client.restoreGroupRooms(from: snapshot)
            return await client.restoredGroupRooms()
        }
        let good = RetainedGroupRoom(room: Self.room, nickname: "alice", members: [Self.alice, Self.bob],
                                     occupants: [Self.room + "/alice": Self.alice, Self.room + "/bob": Self.bob])
        #expect(await restored([good]) == [Self.room: "alice"])
        let bad = [
            RetainedGroupRoom(room: "other@rooms.localhost", nickname: "alice", members: [Self.alice], occupants: ["other@rooms.localhost/alice": Self.bob]),
            RetainedGroupRoom(room: "other@rooms.localhost", nickname: "alice", members: [Self.bob], occupants: ["other@rooms.localhost/alice": Self.alice]),
            RetainedGroupRoom(room: "other@rooms.localhost", nickname: "a/b", members: [Self.alice], occupants: ["other@rooms.localhost/a/b": Self.alice]),
            RetainedGroupRoom(room: "other@rooms.localhost/x", nickname: "alice", members: [Self.alice],
                              occupants: ["other@rooms.localhost/x/alice": Self.alice]),
            RetainedGroupRoom(room: "other@rooms.localhost", nickname: "alice", members: [Self.alice],
                              occupants: ["other@rooms.localhost/alice": Self.alice, "elsewhere@rooms.localhost/bob": Self.bob]),
        ]
        for room in bad { #expect(await restored([good, room]).isEmpty) }
        #expect(await restored([good, good]).isEmpty)
    }
}
