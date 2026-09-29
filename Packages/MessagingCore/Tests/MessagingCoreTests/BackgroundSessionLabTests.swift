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
/// The run leaves its session hibernating, so the server side can be inspected afterwards:
///   prosodyctl shell c2s show <jid> "jid smacks smacks_queue csi push_identifier"
///   prosodyctl shell muc occupants <room>
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
            account: BackgroundAccount(host: "localhost", port: 5223, domain: parts[1], username: parts[0], password: account.password,
                                       labCertificateAuthority: authority, resource: resource, push: push,
                                       leftForeground: Date().addingTimeInterval(-600)))
        print("BACKGROUND_SESSION \(account.jid)/\(resource)")
    }
}
