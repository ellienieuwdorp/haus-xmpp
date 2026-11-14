import Foundation
import Testing
@testable import XMPPProtocol

// What the walk asks of a room on the wire: one round trip per membership read.
@Suite(.serialized)
struct ArchiveWalkWireTests {
    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
    }

    private static let room = "walk@rooms.localhost"
    private static let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"

    private func online(_ client: XMPPClient, on server: LoopbackServer) async throws {
        try await client.configureStreamManagement(persistence: Persistence())
        async let online: Void = server.connect(client)
        try await server.authenticate()
        let bind = try await server.next()
        try #require(bind.child("bind", namespace: Self.bindNamespace) != nil)
        let jid = "<bind xmlns='\(Self.bindNamespace)'><jid>alice@localhost/r</jid></bind>"
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'>\(jid)</iq>")
        #expect(try await server.next().name == "enable")
        try await server.send("<enabled xmlns='urn:xmpp:sm:3' id='walk' resume='true'/>")
        #expect(try await server.next().name == "presence")
        try await online
    }

    // A members-only, nonanonymous room with alice as owner and bob as member.
    private func answer(_ query: XMPPProtocol.XMLNode) -> String {
        let id = query.attributes["id"] ?? ""
        let head = "<iq type='result' id='\(id)' from='\(Self.room)' to='alice@localhost/r'>"
        if query.child("query", namespace: GroupChatWire.disco) != nil {
            let features = ["muc_nonanonymous", "muc_membersonly", "urn:xmpp:sid:0"].map { "<feature var='\($0)'/>" }.joined()
            return head + "<query xmlns='\(GroupChatWire.disco)'>\(features)</query></iq>"
        }
        let affiliation = query.child("query", namespace: GroupChatWire.admin)?.child("item", namespace: GroupChatWire.admin)?.attributes["affiliation"]
        let members = ["owner": "alice@localhost", "member": "bob@localhost"]
        let item = affiliation.flatMap { members[$0] }.map { "<item affiliation='\(affiliation ?? "")' jid='\($0)'/>" } ?? ""
        return head + "<query xmlns='\(GroupChatWire.admin)'>\(item)</query></iq>"
    }

    @Test func aMembershipReadAsksItsFourQueriesInOneRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await online(client, on: server)
        async let refreshed = client.refreshGroupRoom(Self.room)
        // The first validation on a connection is two agreeing reads; each read's queries all arrive unanswered.
        for _ in 0..<2 {
            var queries: [XMPPProtocol.XMLNode] = []
            for _ in 0..<4 { queries.append(try await server.next()) }
            #expect(queries.filter { $0.child("query", namespace: GroupChatWire.disco) != nil }.count == 1)
            #expect(queries.filter { $0.child("query", namespace: GroupChatWire.admin) != nil }.count == 3)
            for query in queries { try await server.send(answer(query)) }
        }
        #expect(try await refreshed.members == ["alice@localhost", "bob@localhost"])
        await server.stop()
    }

    @Test func aRoomThatIsNotMembersOnlyIsRefusedWhateverItsListsSay() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await online(client, on: server)
        let refreshed = Task { try await client.refreshGroupRoom(Self.room) }
        var queries: [XMPPProtocol.XMLNode] = []
        for _ in 0..<4 { queries.append(try await server.next()) }
        for query in queries {
            if query.child("query", namespace: GroupChatWire.disco) != nil {
                let open = "<query xmlns='\(GroupChatWire.disco)'><feature var='muc_open'/></query>"
                try await server.send("<iq type='result' id='\(query.attributes["id"] ?? "")' from='\(Self.room)'>\(open)</iq>")
            } else {
                try await server.send(answer(query))
            }
        }
        await #expect(throws: XMPPGroupError.unsupportedRoom) { _ = try await refreshed.value }
        await server.stop()
    }
}
