import Foundation
import Testing
@testable import XMPPProtocol

// What the walk asks of a room on the wire: one round trip per membership read, a newest-entry probe that runs
// beside a page query and reads no membership, and the queries of one walk that run beside each other.
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
    private static let mam = "urn:xmpp:mam:2"
    private static let rsm = "http://jabber.org/protocol/rsm"

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

    @Test func theNewestEntryProbeRunsBesideAPageAndReadsNoMembership() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await online(client, on: server)
        async let page = client.fetchArchivePage(.after("own-1"))
        let pageQuery = try await server.next()
        #expect(pageQuery.child("query", namespace: Self.mam) != nil)
        async let newest = client.newestArchiveEntry(room: Self.room)
        let probe = try await server.next()
        #expect(probe.attributes["to"] == Self.room)
        let query = try #require(probe.child("query", namespace: Self.mam))
        let set = try #require(query.child("set", namespace: Self.rsm))
        #expect(set.child("max", namespace: Self.rsm)?.text == "1")
        #expect(set.child("before", namespace: Self.rsm)?.text == "")
        let queryID = query.attributes["queryid"] ?? ""
        try await server.send("""
            <message to='alice@localhost/r' from='\(Self.room)'><result xmlns='\(Self.mam)' queryid='\(queryID)' id='room-7'>\
            <forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-11-14T10:00:00Z'/>\
            <message xmlns='jabber:client' type='groupchat' from='\(Self.room)/bob'><body>hi</body></message></forwarded></result></message>
            """)
        try await server.send("<iq type='result' id='\(probe.attributes["id"] ?? "")' from='\(Self.room)'><fin xmlns='\(Self.mam)' complete='true'>"
            + "<set xmlns='\(Self.rsm)'><first>room-7</first><last>room-7</last></set></fin></iq>")
        try await server.send("<iq type='result' id='\(pageQuery.attributes["id"] ?? "")'><fin xmlns='\(Self.mam)' complete='true'/></iq>")
        let found = try await newest
        #expect(found.id == "room-7")
        #expect(found.handledTokens.count == 1)
        #expect(try await page.messages.isEmpty)
        await server.stop()
    }

    @Test func anEmptyArchiveHasNoNewestEntry() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await online(client, on: server)
        async let newest = client.newestArchiveEntry(room: Self.room)
        let probe = try await server.next()
        try await server.send("<iq type='result' id='\(probe.attributes["id"] ?? "")' from='\(Self.room)'><fin xmlns='\(Self.mam)' complete='true'/></iq>")
        #expect(try await newest == XMPPArchiveNewest(id: nil, handledTokens: []))
        await server.stop()
    }

    private func result(_ queryID: String, _ id: String) -> String {
        "<message to='alice@localhost/r'><result xmlns='\(Self.mam)' queryid='\(queryID)' id='\(id)'>"
            + "<forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-11-14T10:00:00Z'/>"
            + "<message xmlns='jabber:client' from='bob@localhost/x' type='chat'><body>hi</body></message></forwarded></result></message>"
    }

    private func fin(_ query: XMPPProtocol.XMLNode, _ ids: [String], complete: Bool) -> String {
        let set = ids.isEmpty ? "" : "<set xmlns='\(Self.rsm)'><first>\(ids[0])</first><last>\(ids[ids.count - 1])</last></set>"
        return "<iq type='result' id='\(query.attributes["id"] ?? "")'><fin xmlns='\(Self.mam)' complete='\(complete)'>\(set)</fin></iq>"
    }

    @Test func oneWalksQueriesRunTogetherAndEachKeepsItsOwnResults() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await online(client, on: server)
        let walk = UUID()
        async let newer = client.fetchArchivePage(.after("own-1"), walk: walk)
        let first = try await server.next()
        async let older = client.fetchArchivePage(.before(nil), walk: walk)
        let second = try await server.next()
        let newerID = try #require(first.child("query", namespace: Self.mam)?.attributes["queryid"])
        let olderID = try #require(second.child("query", namespace: Self.mam)?.attributes["queryid"])
        #expect(second.child("query", namespace: Self.mam)?.child("set", namespace: Self.rsm)?.child("before", namespace: Self.rsm) != nil)
        // Interleaved on the stream; each result belongs to the query its ID names.
        try await server.send(result(newerID, "own-2"))
        try await server.send(result(olderID, "own-8"))
        try await server.send(result(newerID, "own-3"))
        try await server.send(result(olderID, "own-9"))
        try await server.send(fin(second, ["own-8", "own-9"], complete: false))
        try await server.send(fin(first, ["own-2", "own-3"], complete: false))
        let (forward, backward) = try await (newer, older)
        #expect(forward.messages.map(\.archiveID) == ["own-2", "own-3"])
        #expect(backward.messages.map(\.archiveID) == ["own-8", "own-9"])
        #expect(Set(forward.handledTokens.map(\.sequence)).isDisjoint(with: backward.handledTokens.map(\.sequence)))
        #expect(forward.handledTokens.count == 2 && backward.handledTokens.count == 2)
        await server.stop()
    }

    @Test func anotherCallerWaitsForTheWalksQueriesToFinish() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await online(client, on: server)
        let walk = UUID()
        async let page = client.fetchArchivePage(.after("own-1"), walk: walk)
        let query = try await server.next()
        await #expect(throws: XMPPClientError.invalidConfiguration) { _ = try await client.fetchArchivePage(.before("own-1")) }
        await #expect(throws: XMPPClientError.invalidConfiguration) { _ = try await client.fetchArchivePage(.before("own-1"), walk: UUID()) }
        try await server.send(fin(query, [], complete: true))
        #expect(try await page.messages.isEmpty)
        // Free again once they did.
        async let next = client.fetchArchivePage(.before("own-1"))
        let again = try await server.next()
        try await server.send(fin(again, [], complete: true))
        #expect(try await next.complete)
        await server.stop()
    }

    @Test func aWalkHasAtMostItsLimitOfQueriesOut() async throws {
        let server = try await LoopbackServer.start()
        let client = server.client()
        try await online(client, on: server)
        let walk = UUID()
        var pages: [Task<Result<XMPPArchivePage, any Error>, Never>] = []
        var queries: [XMPPProtocol.XMLNode] = []
        for index in 0..<XMPPClient.archiveWalkQueryLimit {
            pages.append(Task {
                do { return .success(try await client.fetchArchivePage(.after("own-\(index)"), walk: walk)) } catch { return .failure(error) }
            })
            queries.append(try await server.next())
        }
        await #expect(throws: XMPPClientError.invalidConfiguration) { _ = try await client.fetchArchivePage(.after("own-9"), walk: walk) }
        for query in queries { try await server.send(fin(query, [], complete: true)) }
        for page in pages { #expect(try await page.value.get().complete) }
        await server.stop()
    }
}
