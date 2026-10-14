import Foundation
import Testing
import MessageStore
import XMPPProtocol
import OMEMO
@testable import MessagingCore

/// The forward walk against the local lab Prosody when the server no longer holds a checkpoint's cursor, through the
/// notification extension's entry point (`BackgroundSynchronizer`). Runs only when the lab is configured:
///   HAUS_LAB_CURSOR_ACCOUNT / HAUS_LAB_CURSOR_PEER  fixture JSON files ({"jid", "password", "room"}) for two
///   disposable accounts and a members-only room; the account owns the room and the peer is its other member.
///   HAUS_LAB_CA (PEM)
/// The peer sends OMEMO envelopes with no key for this account, so every archived entry becomes a durable
/// "not for this device" outcome without a trust setup: the check is about archive positions, not decryption.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_CURSOR_ACCOUNT"] != nil), .serialized)
struct ArchiveCursorLabTests {
    private let env = ProcessInfo.processInfo.environment
    private struct Fixture: Decodable { let jid: String; let password: String; let room: String }

    private func fixture(_ key: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env[key]))))
    }

    private func certificateAuthority() throws -> Data {
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        return try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
    }

    private func connect(_ fixture: Fixture, ca: Data) async throws -> XMPPClient {
        let client = XMPPClient(labCertificateAuthority: ca)
        let parts = fixture.jid.split(separator: "@").map(String.init)
        try await client.connect(host: "127.0.0.1", port: 5223, domain: parts[1], username: parts[0], password: fixture.password)
        return client
    }

    /// One direct and one room entry from the peer, each with an envelope keyed only for a device the account does not have.
    /// Replay identity is the ciphertext digest, so every envelope carries its own payload.
    private func send(from peer: XMPPClient, to account: String, room: String, members: [String]) async throws {
        let envelope = { (profile: XMPPOMEMOProfile) in
            XMPPOMEMOEnvelope(profile: profile, senderDeviceID: 4242,
                              keys: [XMPPOMEMOKey(recipientJID: profile == .legacy ? nil : account, deviceID: 1, keyExchange: false, data: Data(repeating: 7, count: 32))],
                              iv: profile == .legacy ? Data(repeating: 1, count: 12) : nil, payload: Data(UUID().uuidString.utf8))
        }
        try await peer.sendEncryptedMessage(to: account, envelope: envelope(.legacy), id: UUID().uuidString)
        _ = try await peer.sendEncryptedGroupMessage(room: room, envelope: envelope(.modern), id: UUID().uuidString, expectedMembers: members)
    }

    @Test func lostCursorsRecoverThroughTheExtensionPathOnOneConnection() async throws {
        let own = try fixture("HAUS_LAB_CURSOR_ACCOUNT"), other = try fixture("HAUS_LAB_CURSOR_PEER")
        let account = own.jid, room = own.room, members = [own.jid, other.jid].sorted()
        let ca = try certificateAuthority()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cursor-lab-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite"), key = Data(repeating: 5, count: 32)

        let peer = try await connect(other, ca: ca)
        _ = try await peer.joinGroupRoom(room, nickname: "peer")
        try await send(from: peer, to: account, room: room, members: members)

        // A first catch-up records both checkpoints with their archive times.
        let store = try MessageStore(url: url)
        try await store.acquireTransportOwnership()
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: key))
        let client = try await connect(own, ca: ca)
        try await encryption.initialize(account: account, transport: client)
        _ = try await encryption.refreshGroupDevices(account: account, room: room, transport: client)
        #expect(try await ArchiveSynchronizer(store: store).synchronize(account: account, client: client, encryption: encryption).isComplete)
        let direct = try #require(try await store.archiveCheckpoint(accountID: account, archiveID: account))
        let roomCheckpoint = try #require(try await store.archiveCheckpoint(accountID: account, archiveID: room))
        #expect(direct.stamp != nil && roomCheckpoint.stamp != nil)
        await client.disconnectAndWait()

        // As after a week of archive expiry: the server no longer holds either cursor. The room's checkpoint is one
        // written before stamps existed.
        let lost = "p0-lost-" + UUID().uuidString
        try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: direct.revision, cursor: lost, stamp: direct.stamp)
        try await store.saveArchiveCheckpoint(accountID: account, archiveID: room, expectedRevision: roomCheckpoint.revision, cursor: lost)
        let chatsBefore = try await store.messages(accountID: account, chatID: other.jid).count
        try await send(from: peer, to: account, room: room, members: members)
        await peer.disconnectAndWait()
        try await store.close()

        // The extension's run: throws on a disconnect before catch-up, on an incomplete own archive, or on the deadline.
        try await BackgroundSynchronizer().synchronize(databaseURL: url, wrappingKey: key, account: BackgroundAccount(route: .fixed(XMPPEndpoint(host: "127.0.0.1", port: 5223, security: .directTLS)), domain: "localhost", username: String(account.split(separator: "@")[0]),
            password: own.password, labCertificateAuthority: ca))

        let after = try MessageStore(url: url)
        let recoveredDirect = try #require(try await after.archiveCheckpoint(accountID: account, archiveID: account))
        let recoveredRoom = try #require(try await after.archiveCheckpoint(accountID: account, archiveID: room))
        #expect(recoveredDirect.cursor != lost && recoveredDirect.stamp.map { $0 >= direct.stamp! } == true)
        #expect(recoveredRoom.cursor != lost && recoveredRoom.stamp != nil)
        // The newest-page restart moved the room's backfill cursor to that page (its first sync wrote revision 1).
        #expect(try await after.archiveBackfillCursor(accountID: account, archiveID: room)?.revision == 2)
        #expect(Set(try await after.archiveGaps(accountID: account).map(\.archiveID)) == [account, room])
        // The direct entry sent while the cursor was lost is stored (as a placeholder: it carries no key for us).
        #expect(try await after.messages(accountID: account, chatID: other.jid).count == chatsBefore + 1)
        try await after.close()
    }
}
