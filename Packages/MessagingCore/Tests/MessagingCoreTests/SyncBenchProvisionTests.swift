import Foundation
import MessageStore
import OMEMO
import Testing
import XMPPProtocol
@testable import MessagingCore

// Once, on existing accounts and rooms: identities, trust, the sender's and the peer's stores (the peer knows two rooms)
// and the measured account's snapshots (before the seeded messages, caught up, and caught up with five rooms). Plain clients without stream management, so
// no snapshot holds a session to resume.
@Suite(.serialized, .enabled(if: SyncBenchEnvironment.provisioning))
struct SyncBenchProvisionTests {
    private struct Party {
        let account: SyncBenchFixture.Account
        let bench: SyncBenchStore
        let client: XMPPClient
        let consumer: Task<Void, Never>

        static func open(_ account: SyncBenchFixture.Account, at directory: URL, authority: Data) async throws -> Party {
            let bench = try SyncBenchStore.open(directory)
            try await bench.store.acquireTransportOwnership()
            let client = XMPPClient(labCertificateAuthority: authority)
            try await client.connect(host: "127.0.0.1", port: 5223, domain: account.domain, username: account.localpart, password: account.password)
            let processor = InboundProcessor(encryption: bench.encryption, client: client, account: account.jid)
            let consumer = Task {
                // A stanza that fails here is withheld from acknowledgement, which a stream without management never sends.
                for await event in client.events { _ = try? await processor.process(event) }
            }
            return Party(account: account, bench: bench, client: client, consumer: consumer)
        }

        func close() async throws {
            await client.disconnectAndWait()
            consumer.cancel()
            await consumer.value
            try await bench.close(removing: false)
        }

        func trust(_ other: SyncBenchFixture.Account) async throws {
            let overview = try await bench.encryption.refreshDevices(account: account.jid, peer: other.jid, transport: client)
            let devices = overview.devices.filter { $0.active && $0.jid == other.jid }.map(\.id)
            #expect(!devices.isEmpty, "\(other.localpart) has devices")
            try await bench.encryption.setTrust(account: account.jid, deviceIDs: devices, trust: .accepted)
            try await bench.store.upsertChat(accountID: account.jid, chatID: other.jid, title: other.localpart)
        }

        func send(_ count: Int, to other: SyncBenchFixture.Account) async throws {
            for index in 0..<count {
                try await OutgoingEnqueue.text("Synthetic catch-up \(index + 1)", account: account.jid, chatID: other.jid, store: bench.store)
            }
            let drain = OutboxDrain(account: account.jid, client: client, encryption: bench.encryption, store: bench.store,
                                    sender: OutboxSender(store: bench.store), joinedGroups: [])
            #expect(try await drain.run().isEmpty, "nothing held for trust")
            // An answered query after the sends: the server has taken every one of them.
            _ = try await client.fetchRoster()
        }

        // Walks to the archive's head, sends the receipts and key transports that queued, then walks again past them, so
        // a snapshot holds an empty outbox and nothing new in the archive.
        func walk() async throws {
            let synchronizer = ArchiveSynchronizer(store: bench.store)
            _ = try await synchronizer.synchronize(account: account.jid, client: client, encryption: bench.encryption) { _ in }
            let drain = OutboxDrain(account: account.jid, client: client, encryption: bench.encryption, store: bench.store,
                                    sender: OutboxSender(store: bench.store), joinedGroups: [])
            _ = try await drain.run()
            _ = try await client.fetchRoster()
            _ = try await synchronizer.synchronize(account: account.jid, client: client, encryption: bench.encryption) { _ in }
        }
    }

    @Test func provision() async throws {
        let environment = try SyncBenchEnvironment()
        let fixture = environment.fixture, authority = environment.authority
        let work = environment.directory.appending(path: "provision", directoryHint: .isDirectory)
        // A missing directory is the first provisioning.
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.removeItem(at: environment.peerStore)
        let appDirectory = work.appending(path: "app"), peerDirectory = environment.peerStore

        // Identities and trust: the app and the sender trust the peer, the peer trusts both.
        var app = try await Party.open(fixture.app, at: appDirectory, authority: authority)
        let peer = try await Party.open(fixture.peer, at: peerDirectory, authority: authority)
        let sender = try await Party.open(fixture.sender, at: environment.senderStore, authority: authority)
        for party in [app, peer, sender] { try await party.bench.encryption.initialize(account: party.account.jid, transport: party.client) }
        try await app.trust(fixture.peer)
        try await sender.trust(fixture.peer)
        try await peer.trust(fixture.app)
        try await peer.trust(fixture.sender)
        for room in fixture.rooms.prefix(2) {
            _ = try await app.bench.encryption.refreshGroupDevices(account: fixture.app.jid, room: room, transport: app.client)
            _ = try await peer.bench.encryption.refreshGroupDevices(account: fixture.peer.jid, room: room, transport: peer.client)
        }
        // One message first, so the walk below has a checkpoint and the seeded ones arrive as new.
        try await peer.send(1, to: fixture.app)
        try await app.walk()
        try await sender.close()
        try await app.close()
        try snapshot(appDirectory, as: "catchup", in: environment)

        try await peer.send(SyncBenchFixture.catchUpMessages, to: fixture.app)
        try await peer.close()
        app = try await Party.open(fixture.app, at: appDirectory, authority: authority)
        try await app.walk()
        let unread = try await app.bench.store.unreadCounts(accountID: fixture.app.jid)[fixture.peer.jid] ?? 0
        #expect(unread >= SyncBenchFixture.catchUpMessages)
        try await app.close()
        try snapshot(appDirectory, as: "base", in: environment)

        app = try await Party.open(fixture.app, at: appDirectory, authority: authority)
        for room in fixture.rooms.dropFirst(2) {
            _ = try await app.bench.encryption.refreshGroupDevices(account: fixture.app.jid, room: room, transport: app.client)
        }
        try await app.walk()
        #expect(try await app.bench.encryption.knownGroupRooms(account: fixture.app.jid).count == fixture.rooms.count)
        try await app.close()
        try snapshot(appDirectory, as: "rooms", in: environment)
    }

    private func snapshot(_ directory: URL, as name: String, in environment: SyncBenchEnvironment) throws {
        let target = environment.snapshot(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A snapshot from an earlier provisioning is replaced whole.
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: directory, to: target)
    }
}
