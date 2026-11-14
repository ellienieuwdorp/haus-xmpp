import Foundation
import Testing
@testable import XMPPProtocol

// Room occupancy across XEP-0198 hibernation against the lab Prosody, in rooms each test makes. Needs HAUS_LAB_ROOM_ACCOUNT
// and HAUS_LAB_ROOM_PEER (credential JSON of two disposable lab accounts), HAUS_LAB_CA (PEM) and optionally
// HAUS_LAB_PROSODY_CONTAINER.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_ROOM_ACCOUNT"] != nil), .serialized)
struct RoomResumeLabTests {
    private struct Credentials: Decodable { let jid: String; let password: String }

    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
    }

    private let env = ProcessInfo.processInfo.environment

    private func credentials(_ key: String) throws -> Credentials {
        try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env[key]))))
    }

    private func connect(_ account: Credentials, persistence: Persistence, resource: String) async throws -> XMPPClient {
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        let authority = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let parts = account.jid.split(separator: "@").map(String.init)
        let client = XMPPClient(labCertificateAuthority: authority)
        try await client.configureStreamManagement(persistence: persistence)
        try await client.configureResource(resource)
        try await client.setAvailability(.active, clientActive: true)
        try await client.connect(host: "localhost", port: 5223, domain: parts[1], username: parts[0], password: account.password)
        return client
    }

    @discardableResult
    private func prosody(_ script: String) throws -> String {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "exec", "-i", env["HAUS_LAB_PROSODY_CONTAINER"] ?? "haus-xmpp-lab-prosody-1", "prosodyctl", "shell"]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // A members-only, nonanonymous room the account owns and the peer belongs to.
    private func makeRoom(owner: String, member: String) throws -> String {
        let room = "resume-\(UUID().uuidString.prefix(8).lowercased())@rooms.localhost"
        try prosody("""
            muc:create("\(room)", { persistent = true; members_only = true; whois = "anyone" })
            muc:room("\(room)"):set_affiliation(true, "\(owner)", "owner")
            muc:room("\(room)"):set_affiliation(true, "\(member)", "member")

            """)
        return room
    }

    private func join(_ client: XMPPClient, room: String, nickname: String) async throws {
        var events = client.events.makeAsyncIterator()
        _ = try await client.joinGroupRoom(room, nickname: nickname)
        while try await client.groupRoomSnapshot(room)?.joined != true {
            guard let event = await events.next() else { throw XMPPClientError.connectionClosed }
            if case .groupPresence = event { continue }
        }
    }

    // Detached cleanly while joined, so the session hibernates in the room with its occupancy saved.
    private func hibernateInRoom(_ room: String, persistence: Persistence, resource: String) async throws {
        let client = try await connect(try credentials("HAUS_LAB_ROOM_ACCOUNT"), persistence: persistence, resource: resource)
        try await join(client, room: room, nickname: "app")
        await client.disconnectAndWait()
        let saved = try #require(await persistence.value)
        #expect(saved.retainedRooms?.handled == saved.inboundHandled)
        #expect(saved.retainedRooms?.rooms.map(\.room) == [room])
    }

    @Test(.timeLimit(.minutes(1))) func theResumeRoutesWhatTheRoomSentMeanwhileAndTheSelfPingConfirms() async throws {
        let app = try credentials("HAUS_LAB_ROOM_ACCOUNT"), peer = try credentials("HAUS_LAB_ROOM_PEER")
        let room = try makeRoom(owner: app.jid, member: peer.jid)
        defer { _ = try? prosody("muc:room(\"\(room)\"):destroy()\n") }
        let persistence = Persistence(), resource = XMPPClient.makeResource()
        try await hibernateInRoom(room, persistence: persistence, resource: resource)

        let sender = try await connect(peer, persistence: Persistence(), resource: XMPPClient.makeResource())
        try await join(sender, room: room, nickname: "peer")
        let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 7,
                                         keys: [.init(recipientJID: app.jid, deviceID: 9, keyExchange: false, data: Data([1]))], payload: Data([2]))
        let id = "held-\(UUID().uuidString)"
        _ = try await sender.sendEncryptedGroupMessage(room: room, envelope: envelope, id: id, expectedMembers: [app.jid, peer.jid])
        await sender.disconnectAndWait()

        let client = try await connect(app, persistence: persistence, resource: resource)
        #expect(await client.sessionResumed)
        var events = client.events.makeAsyncIterator()
        var routed: XMPPEncryptedGroupMessage?
        while routed == nil, let event = await events.next() {
            if case .encryptedGroupMessage(let message) = event, message.id == id { routed = message }
            if case .encryptionFailure = event { break }
        }
        #expect(routed?.sender == peer.jid && routed?.roomStanzaID != nil)
        #expect(await client.confirmRestoredGroupRoom(room))
        #expect(try await client.groupRoomSnapshot(room)?.joined == true)
        await client.disconnectAndWait()
    }

    // Removing a member kicks it from a members-only room (status 321); destroying the room ends every occupant. Either
    // presence waits in the hibernated session's queue and ends the restored occupancy before any self-ping.
    @Test(.timeLimit(.minutes(1)), arguments: ["kick", "destroy"])
    func aRemovalQueuedWhileHibernatingEndsTheRestoredOccupancy(_ removal: String) async throws {
        let app = try credentials("HAUS_LAB_ROOM_ACCOUNT"), peer = try credentials("HAUS_LAB_ROOM_PEER")
        let room = try makeRoom(owner: peer.jid, member: app.jid)
        defer { _ = try? prosody("muc:room(\"\(room)\"):destroy()\n") }
        let persistence = Persistence(), resource = XMPPClient.makeResource()
        try await hibernateInRoom(room, persistence: persistence, resource: resource)
        try prosody(removal == "kick" ? "muc:room(\"\(room)\"):set_affiliation(true, \"\(app.jid)\", \"none\")\n" : "muc:room(\"\(room)\"):destroy()\n")

        let client = try await connect(app, persistence: persistence, resource: resource)
        #expect(await client.sessionResumed)
        var events = client.events.makeAsyncIterator()
        while await !client.restoredGroupRooms().isEmpty, let event = await events.next() {
            if case .groupPresence = event { continue }
        }
        #expect(await !client.confirmRestoredGroupRoom(room))
        #expect(try await client.groupRoomSnapshot(room)?.joined != true)
        await client.disconnectAndWait()
    }
}
