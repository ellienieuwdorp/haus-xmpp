import Foundation
import Testing
import MessageStore
import OMEMO
import XMPPProtocol
@testable import MessagingCore

/// The extension's fresh-bind path against the local lab Prosody. Runs only when configured:
///   HAUS_LAB_BACKGROUND_ACCOUNT  credential JSON ({"jid", "password"}) of a disposable lab account
///   HAUS_LAB_BACKGROUND_ROOM     a members-only, non-anonymous room on rooms.localhost the account is a member of
///   HAUS_LAB_CA                  the lab CA (PEM)
///   HAUS_LAB_PROSODY_CONTAINER   the lab's Prosody container (default haus-xmpp-lab-prosody-1), whose shell reports
///                                the server's sessions and occupants
/// The run leaves its session hibernating, so it can also be inspected by hand afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_BACKGROUND_ACCOUNT"] != nil), .serialized)
struct BackgroundSessionLabTests {
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

    /// `prosodyctl shell` in the lab container: the server's own view, which no client can query.
    private func prosody(_ arguments: String...) throws -> [Substring] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "exec", env["HAUS_LAB_PROSODY_CONTAINER"] ?? "haus-xmpp-lab-prosody-1", "prosodyctl", "shell"] + arguments
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    @Test func freshBindFromTheExtensionReplacesTheSessionAndRestoresPushAndRooms() async throws {
        let account = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env["HAUS_LAB_BACKGROUND_ACCOUNT"]))))
        let room = try #require(env["HAUS_LAB_BACKGROUND_ROOM"])
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        let authority = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let parts = account.jid.split(separator: "@").map(String.init)
        let resource = XMPPClient.makeResource()
        let push = try PushSubscription.generate(serviceJID: "push.localhost")
        func client() -> XMPPClient { XMPPClient(labCertificateAuthority: authority) }
        func connect(_ client: XMPPClient) async throws {
            try await client.connect(host: "localhost", port: 5223, domain: parts[1], username: parts[0], password: account.password)
        }

        // No session left from an earlier run: the count below is this installation's alone.
        _ = try prosody("c2s", "close", account.jid)

        // The extension's store: an identity and the room, as the app leaves them. Set up without stream management,
        // so this connection ends with its socket instead of hibernating.
        let url = FileManager.default.temporaryDirectory.appending(path: "background-lab-\(UUID()).sqlite")
        let key = Data(repeating: 11, count: 32)
        do {
            let store = try MessageStore(url: url)
            let encryption = OMEMOService(store: store, protection: try StateProtection(key: key))
            let setup = client()
            try await connect(setup)
            try await encryption.initialize(account: account.jid, transport: setup)
            _ = try await encryption.refreshGroupDevices(account: account.jid, room: room, transport: setup)
            await setup.disconnectAndWait()
            try await store.close()
        }

        // The app's session: push enabled, in the room, left hibernating.
        let app = client()
        try await app.configureStreamManagement(persistence: Persistence())
        try await app.configureResource(resource)
        try await connect(app)
        try await app.enablePush(push)
        _ = try await app.joinGroupRoom(room, nickname: parts[0])
        await app.disconnectAndWait()

        // A push arrives and the extension cannot resume (its store holds no session): it binds fresh.
        try await BackgroundSynchronizer().synchronize(
            databaseURL: url, wrappingKey: key,
            account: BackgroundAccount(route: .fixed(XMPPEndpoint(host: "localhost", port: 5223, security: .directTLS)), domain: parts[1], username: parts[0], password: account.password,
                                       labCertificateAuthority: authority, resource: resource, push: push,
                                       leftForeground: Date().addingTimeInterval(-600)))
        // One session for the account: the extension's, under the installation's resource, replacing the app's rather
        // than joining it, hibernating with nothing unacknowledged, push enabled on it, and the account in the room.
        let sessions = try prosody("c2s", "show", account.jid, "jid smacks smacks_queue push_identifier").filter { $0.hasPrefix(account.jid + "/") }
        #expect(sessions.count == 1)
        let columns = try #require(sessions.first).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(columns == [account.jid + "/" + resource, "hibernating", "0", columns[3]])
        #expect(columns[3].hasPrefix("push.localhost<"))
        let occupants = try prosody("muc", "occupants", room).filter { $0.contains("| " + account.jid + " ") }
        #expect(occupants.count == 1)
    }
}
