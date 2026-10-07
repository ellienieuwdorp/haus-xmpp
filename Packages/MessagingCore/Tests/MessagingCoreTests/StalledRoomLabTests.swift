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

    /// The configured server, and a store as the app leaves it: an identity, the own archive walked, and the rooms
    /// recorded while they still answered.
    private struct Lab: Sendable {
        let own: Credentials, peer: Credentials, rooms: [String], port: UInt16, authority: Data
        let url: URL, key = Data(repeating: 9, count: 32)

        init(directory: URL) throws {
            let env = ProcessInfo.processInfo.environment
            func credentials(_ key: String) throws -> Credentials {
                try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env[key]))))
            }
            own = try credentials("HAUS_LAB_STALLED_ACCOUNT"); peer = try credentials("HAUS_LAB_STALLED_PEER")
            rooms = try #require(env["HAUS_LAB_STALLED_ROOMS"]).split(separator: ",").map(String.init)
            port = UInt16(env["HAUS_LAB_STALLED_PORT"] ?? "45223") ?? 45223
            let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
            authority = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
            url = directory.appending(path: "messages.sqlite")
        }

        func connect(_ credentials: Credentials, resource: String? = nil) async throws -> XMPPClient {
            let client = XMPPClient(labCertificateAuthority: authority)
            if let resource { try await client.configureResource(resource) }
            let parts = credentials.jid.split(separator: "@").map(String.init)
            try await client.connect(host: "localhost", port: port, domain: parts[1], username: parts[0], password: credentials.password)
            return client
        }

        func prepareStore() async throws {
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

        /// A direct message keyed only for a device this account does not have: it commits as a placeholder.
        func sendDirect() async throws {
            let sender = try await connect(peer)
            try await sender.sendEncryptedMessage(to: own.jid, envelope: XMPPOMEMOEnvelope(
                profile: .legacy, senderDeviceID: 4242, keys: [XMPPOMEMOKey(recipientJID: nil, deviceID: 1, keyExchange: false, data: Data(repeating: 7, count: 32))],
                iv: Data(repeating: 1, count: 12), payload: Data(UUID().uuidString.utf8)), id: UUID().uuidString)
            await sender.disconnectAndWait()
        }

        /// One extension run: `BackgroundSynchronizer` with the presenter.
        func synchronize(posting: FakePosting, progress: NotificationRunProgress) async throws {
            let parts = own.jid.split(separator: "@").map(String.init), accountID = own.jid
            try await BackgroundSynchronizer().synchronize(
                databaseURL: url, wrappingKey: key,
                account: BackgroundAccount(route: .fixed(XMPPEndpoint(host: "localhost", port: port, security: .directTLS)), domain: parts[1],
                                           username: parts[0], password: own.password, labCertificateAuthority: authority),
                progress: progress, presentation: { store, stage in
                    try await NotificationPresenter(posting: posting).present(store: store, accountID: accountID, progress: progress, stage: stage)
                })
        }
    }

    private func withLab(_ body: (Lab) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stalled-lab-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lab = try Lab(directory: directory)
        try await lab.prepareStore()
        try await body(lab)
    }

    @Test func directMessagesArePresentedWhileRoomsNeverAnswer() async throws {
        try await withLab { lab in
            try await lab.sendDirect()
            let posting = FakePosting(), progress = NotificationRunProgress()
            let clock = ContinuousClock(), start = clock.now
            try await lab.synchronize(posting: posting, progress: progress)
            let elapsed = clock.now - start
            let added = await posting.added
            print("stalled-room run: elapsed=\(elapsed) firstPost=\(progress.report.firstPostMilliseconds.map(String.init) ?? "none")ms posted=\(progress.report.posted)")
            #expect(added.map(\.body) == [NotificationPlanner.unreadableBody])
            #expect(progress.isCommitted)
            // Posted long before the rooms gave up: each one holds its membership read for the 15 s IQ timeout.
            #expect(try #require(progress.report.firstPostMilliseconds) < 5_000)
            // The rooms get 5 s more after the post, not the rest of the 20 s budget.
            #expect(elapsed < .seconds(12))
        }
    }

    /// A second message and its push while the rooms are walked, and the user opening the app from the first banner:
    /// the push joins the running run (one run, both messages posted, both requests settled) and the app gets the
    /// lease soon after, instead of waiting for a second run to walk the silent rooms again.
    @Test func aBurstDuringTheRoomWalkJoinsOneRunAndTheAppGetsTheLeaseSoon() async throws {
        try await withLab { lab in
            try await lab.sendDirect()
            let posting = FakePosting()
            let coordinator = NotificationRunCoordinator { progress in
                do {
                    try await lab.synchronize(posting: posting, progress: progress)
                    return .settled(progress.report)
                } catch {
                    return progress.isCommitted ? .settled(progress.report) : .fallback(NotificationFallbackReason(error))
                }
            }
            let clock = ContinuousClock(), start = clock.now
            let first = Task { await coordinator.deliver(ticket: UUID()) }
            while await posting.added.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            let banner = clock.now
            try await Task.sleep(for: .seconds(1))
            try await lab.sendDirect()
            let second = Task { await coordinator.deliver(ticket: UUID()) }
            try await Task.sleep(for: .milliseconds(100))
            #expect(coordinator.activeRuns == 1)
            // The app, opened from the first banner 2 s after it appeared, polls the lease as AppModel does.
            try await Task.sleep(until: banner + .seconds(2))
            let asked = clock.now
            let app = try MessageStore(url: lab.url)
            while true {
                do { try await app.acquireTransportOwnership(); break }
                catch MessageStoreError.transportOwnedElsewhere { try await Task.sleep(for: .milliseconds(250)) }
            }
            let waited = clock.now - asked
            try await app.close()
            let outcomes = [await first.value, await second.value]
            print("stalled-room burst: banner=\(banner - start) appWaited=\(waited) posted=\(await posting.added.count)")
            #expect(outcomes.allSatisfy { $0.suppressesRemoteAlert })
            #expect(await posting.added.map(\.body) == [NotificationPlanner.unreadableBody, NotificationPlanner.unreadableBody])
            #expect(waited < .seconds(6))
        }
    }
}
