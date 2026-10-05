import Foundation
import Testing
import MessageStore
import OMEMO
import XMPPProtocol
@testable import MessagingCore

/// MS-110 against a real server: the extension's entry point with rooms whose MUC component never answers. Needs the
/// disposable server in infra/local/stalled-room (its own Compose project, not the shared lab) and its component
/// script. Runs only when configured:
///   HAUS_LAB_STALLED_ACCOUNT / HAUS_LAB_STALLED_PEER  credential JSON ({"jid", "password"}) of two accounts there
///   HAUS_LAB_STALLED_ROOMS  comma-separated rooms on the component (answering only resources named "setup…")
///   HAUS_LAB_STALLED_PORT   the server's direct TLS port on 127.0.0.1 (default 45223)
///   HAUS_LAB_CA             the CA (PEM) that signed that server's certificate
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_STALLED_ACCOUNT"] != nil), .serialized)
struct StalledRoomLabTests {
    private struct Credentials: Decodable { let jid: String; let password: String }
    private let env = ProcessInfo.processInfo.environment

    private func credentials(_ key: String) throws -> Credentials {
        try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env[key]))))
    }

    @Test func directMessagesArePresentedWhileRoomsNeverAnswer() async throws {
        let own = try credentials("HAUS_LAB_STALLED_ACCOUNT"), peer = try credentials("HAUS_LAB_STALLED_PEER")
        let rooms = try #require(env["HAUS_LAB_STALLED_ROOMS"]).split(separator: ",").map(String.init)
        let port = UInt16(env["HAUS_LAB_STALLED_PORT"] ?? "45223") ?? 45223
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        let authority = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let parts = own.jid.split(separator: "@").map(String.init)
        func connect(_ credentials: Credentials, resource: String? = nil) async throws -> XMPPClient {
            let client = XMPPClient(labCertificateAuthority: authority)
            if let resource { try await client.configureResource(resource) }
            let parts = credentials.jid.split(separator: "@").map(String.init)
            try await client.connect(host: "localhost", port: port, domain: parts[1], username: parts[0], password: credentials.password)
            return client
        }

        let directory = FileManager.default.temporaryDirectory.appending(path: "stalled-lab-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite"), key = Data(repeating: 9, count: 32)

        // As the app leaves it: an identity, the own archive walked, and the rooms recorded while they still answered.
        do {
            let store = try MessageStore(url: url)
            try await store.acquireTransportOwnership()
            let encryption = OMEMOService(store: store, protection: try StateProtection(key: key))
            let setup = try await connect(own, resource: "setup-\(UUID())")
            try await encryption.initialize(account: own.jid, transport: setup)
            #expect(try await ArchiveSynchronizer(store: store).synchronize(account: own.jid, client: setup, encryption: encryption).isComplete)
            for room in rooms { _ = try await encryption.refreshGroupDevices(account: own.jid, room: room, transport: setup) }
            await setup.disconnectAndWait()
            try await store.close()
        }

        // A direct message, keyed only for a device this account does not have: it commits as a placeholder.
        let sender = try await connect(peer)
        try await sender.sendEncryptedMessage(to: own.jid, envelope: XMPPOMEMOEnvelope(
            profile: .legacy, senderDeviceID: 4242, keys: [XMPPOMEMOKey(recipientJID: nil, deviceID: 1, keyExchange: false, data: Data(repeating: 7, count: 32))],
            iv: Data(repeating: 1, count: 12), payload: Data(UUID().uuidString.utf8)), id: UUID().uuidString)
        await sender.disconnectAndWait()

        let posting = FakePosting(), progress = NotificationRunProgress()
        let clock = ContinuousClock(), start = clock.now
        try await BackgroundSynchronizer().synchronize(
            databaseURL: url, wrappingKey: key,
            account: BackgroundAccount(route: .fixed(XMPPEndpoint(host: "localhost", port: port, security: .directTLS)), domain: parts[1],
                                       username: parts[0], password: own.password, labCertificateAuthority: authority),
            progress: progress, presentation: { store, stage in
                try await NotificationPresenter(posting: posting).present(store: store, accountID: own.jid, progress: progress, stage: stage)
            })
        let elapsed = clock.now - start
        let added = await posting.added
        print("stalled-room run: elapsed=\(elapsed) firstPost=\(progress.report.firstPostMilliseconds.map(String.init) ?? "none")ms posted=\(progress.report.posted)")
        #expect(added.map(\.body) == [NotificationPlanner.unreadableBody])
        #expect(progress.isCommitted)
        // Posted long before the rooms gave up: each one holds its membership read for the 15 s IQ timeout.
        #expect(try #require(progress.report.firstPostMilliseconds) < 5_000)
        #expect(elapsed < .seconds(25))
    }
}
