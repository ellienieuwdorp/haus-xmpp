import Foundation
import Testing
import MessageStore
import XMPPProtocol
import OMEMO
@testable import MessagingCore

/// Two clients of one account on the local lab Prosody: this client (XMPPClient, store, OMEMOService, InboundProcessor,
/// ReadSync) and an independent slixmpp client of the same account (`Scripts/Lab/mds_client.py`), with a second lab
/// account as the peer. Runs only when the lab is configured:
///   HAUS_LAB_READSYNC_ACCOUNT / HAUS_LAB_READSYNC_PEER  credential JSON files ({"jid", "password"}) under work/
///   HAUS_LAB_CA (PEM), HAUS_LAB_PYTHON (a venv with slixmpp), HAUS_LAB_READSYNC_SCRIPT (path to mds_client.py)
/// Messages are real (the peer sends them, our server archives them); they are stored as if decrypted, with the ids
/// the archive assigned, because the check is about read state, not OMEMO.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_READSYNC_ACCOUNT"] != nil), .serialized)
struct ReadSyncLabTests {
    private let env = ProcessInfo.processInfo.environment

    private struct Credentials: Decodable { let jid: String; let password: String }

    private func credentials(_ key: String) throws -> Credentials {
        try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env[key]))))
    }

    /// Runs the second client once and returns its output lines.
    private func second(_ credentialsKey: String, _ arguments: [String]) async throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(env["HAUS_LAB_PYTHON"]))
        process.arguments = [try #require(env["HAUS_LAB_READSYNC_SCRIPT"]), "--credentials", try #require(env[credentialsKey]),
                             "--ca", try #require(env["HAUS_LAB_CA"])] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(status == 0, "second client failed: \(arguments.first ?? "")")
        return lines
    }

    private func certificateAuthority() throws -> Data {
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return try #require(Data(base64Encoded: body))
    }

    private func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<50 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("timed out waiting for \(what)")
    }

    @Test func anotherClientsDisplayedStateMovesOurPointerAndOursRoundTrips() async throws {
        let own = try credentials("HAUS_LAB_READSYNC_ACCOUNT"), peer = try credentials("HAUS_LAB_READSYNC_PEER")
        let account = own.jid, contact = peer.jid
        let run = UUID().uuidString.prefix(8)
        // The peer writes three messages; our server archives each with its own stanza-id.
        var wireIDs: [String] = []
        for index in 1...3 {
            let lines = try await second("HAUS_LAB_READSYNC_PEER", ["send", account, "Lab read state \(run) #\(index)"])
            wireIDs.append(String(try #require(lines.first { $0.hasPrefix("SENT ") }).dropFirst(5)))
        }

        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "readsync-lab-\(UUID()).sqlite"))
        try await store.acquireTransportOwnership()
        try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([0]))
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 9, count: 32)))
        let client = XMPPClient(labCertificateAuthority: try certificateAuthority())
        let parts = account.split(separator: "@").map(String.init)
        try await client.connect(host: "localhost", port: 5223, domain: parts[1], username: parts[0], password: own.password)
        let processor = InboundProcessor(encryption: encryption, client: client, account: account)
        let consumer = Task { for await event in client.events { _ = try? await processor.process(event) } }
        defer { consumer.cancel() }
        try await client.setCarbonsEnabled()

        // Our archive names each message: the MAM result id is the stanza-id `by` our bare JID.
        let page = try await client.fetchArchivePage(.before(nil), limit: 50)
        var archiveIDs: [String] = []
        for (index, wireID) in wireIDs.enumerated() {
            let entry = try #require(page.messages.first { $0.message?.id == wireID })
            archiveIDs.append(entry.archiveID)
            let message = StoredMessage(id: "lab-\(index + 1)", accountID: account, chatID: contact, senderID: contact, body: entry.message?.body ?? "",
                                        sentAt: entry.timestamp, encryptionProfile: "modern", wireID: wireID)
            try await store.commitEncryptedIncoming(accountID: account, sender: contact, digest: "lab-\(run)-\(index)", expectedRevision: index + 1,
                                                    state: Data([UInt8(index + 1)]), message: message, archiveStanzaID: entry.archiveID)
        }
        #expect(try await store.unreadCounts(accountID: account)[contact] == 3)

        // 1. The other client publishes XEP-0490 state: Prosody's PEP notification (from our bare JID) moves our pointer.
        _ = try await second("HAUS_LAB_READSYNC_ACCOUNT", ["publish", contact, archiveIDs[0], account])
        try await eventually("the PEP notification") { try await store.readPointer(accountID: account, chatID: contact)?.messageID == "lab-1" }
        #expect(try await store.readPointer(accountID: account, chatID: contact)?.publishPending == false)

        // 2. The other client sends a plain XEP-0333 displayed to the peer: its carbon moves our pointer again.
        _ = try await second("HAUS_LAB_READSYNC_ACCOUNT", ["marker", contact, wireIDs[1]])
        try await eventually("the marker carbon") { try await store.readPointer(accountID: account, chatID: contact)?.messageID == "lab-2" }
        #expect(try await store.unreadCounts(accountID: account)[contact] == 1)

        // 3. We read the newest message here: the push publishes it, the other client fetches exactly that item back.
        #expect(try await store.markRead(accountID: account, chatID: contact, throughMessageID: "lab-3"))
        #expect(try await ReadSync(store: store).push(account: account, client: client) == 1)
        let fetched = try await second("HAUS_LAB_READSYNC_ACCOUNT", ["fetch"])
        #expect(fetched.contains("ITEM \(contact) \(archiveIDs[2]) \(account)"))
        #expect(fetched.contains("CONFIG pubsub#access_model whitelist"))
        #expect(fetched.contains("CONFIG pubsub#max_items max"))
        #expect(fetched.contains("CONFIG pubsub#send_last_published_item never"))
        // Our own fetch after bind sees the same item, and a store that had not read the chat catches up from it.
        #expect(try await client.fetchDisplayedSync().contains(XMPPDisplayedItem(chat: contact, stanzaID: archiveIDs[2], by: account)))
        #expect(try await store.unreadCounts(accountID: account)[contact] == nil)
        let fresh = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "readsync-lab-fresh-\(UUID()).sqlite"))
        try await fresh.acquireTransportOwnership()
        try await fresh.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([0]))
        for (index, wireID) in wireIDs.enumerated() {
            let message = StoredMessage(id: "lab-\(index + 1)", accountID: account, chatID: contact, senderID: contact, body: "Synthetic",
                                        sentAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), encryptionProfile: "modern", wireID: wireID)
            try await fresh.commitEncryptedIncoming(accountID: account, sender: contact, digest: "fresh-\(index)", expectedRevision: index + 1,
                                                    state: Data([UInt8(index + 1)]), message: message, archiveStanzaID: archiveIDs[index])
        }
        let freshEncryption = OMEMOService(store: fresh, protection: try StateProtection(key: Data(repeating: 9, count: 32)))
        #expect(try await ReadSync(store: fresh).pull(account: account, client: client, encryption: freshEncryption))
        #expect(try await fresh.readPointer(accountID: account, chatID: contact)?.messageID == "lab-3")
        #expect(try await fresh.pendingNotifications(accountID: account).claimed.count == 0)
        try await fresh.close()
        await client.disconnectAndWait()
        try await store.close()
    }
}
