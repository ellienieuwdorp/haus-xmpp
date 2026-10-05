import Foundation
import Testing
@testable import XMPPProtocol

/// XEP-0198 resumption against the local lab Prosody. Runs only when configured:
///   HAUS_LAB_RESUME_ACCOUNT  credential JSON ({"jid", "password"}) of a disposable lab account
///   HAUS_LAB_CA              the lab CA (PEM)
///   HAUS_LAB_PROSODY_CONTAINER the lab's Prosody container (default haus-xmpp-lab-prosody-1), for the server's view
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_RESUME_ACCOUNT"] != nil), .serialized)
struct ResumeLabTests {
    private struct Credentials: Decodable { let jid: String; let password: String }

    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
        func seed(_ snapshot: XMPPStreamManagementSnapshot?) { value = snapshot }
    }

    private let env = ProcessInfo.processInfo.environment

    private func credentials() throws -> Credentials {
        try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env["HAUS_LAB_RESUME_ACCOUNT"]))))
    }

    private func certificateAuthority() throws -> Data {
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        return try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
    }

    /// Connects a new client over `persistence`, as the app, extension and actions each do.
    private func connect(_ persistence: Persistence, resource: String, availability: XMPPAvailability = .active) async throws -> XMPPClient {
        let account = try credentials()
        let parts = account.jid.split(separator: "@").map(String.init)
        let client = XMPPClient(labCertificateAuthority: try certificateAuthority())
        try await client.configureStreamManagement(persistence: persistence)
        try await client.configureResource(resource)
        try await client.setAvailability(availability)
        try await client.connect(host: "localhost", port: 5223, domain: parts[1], username: parts[0], password: account.password)
        return client
    }

    @Test func sessionIsResumedPastTheAdvertisedWindow() async throws {
        let resource = XMPPClient.makeResource()
        let persistence = Persistence()
        let first = try await connect(persistence, resource: resource)
        #expect(await !first.sessionResumed)
        await first.disconnectAndWait()
        var saved = try #require(await persistence.value)
        #expect(saved.fullJID.hasSuffix("/" + resource))
        // As an older build saved it: 300 s from a last acknowledgement 301 s ago. Prosody still holds the session.
        saved.resumeTimeoutSeconds = 300
        saved.expiresAt = Date().addingTimeInterval(-1)
        await persistence.seed(saved)
        let second = try await connect(persistence, resource: resource)
        #expect(await second.sessionResumed)
        await second.disconnectAndWait()
    }

    @Test func refusedResumeFallsThroughToAFreshBindOnTheSameConnection() async throws {
        let account = try credentials()
        let resource = XMPPClient.makeResource()
        let persistence = Persistence()
        await persistence.seed(.init(revision: 1, accountID: account.jid, fullJID: account.jid + "/" + resource, streamID: "expired-session",
                                     expiresAt: nil, inboundHandled: 3, outboundSent: 0, outboundAcknowledged: 0, journal: []))
        let client = try await connect(persistence, resource: resource)
        #expect(await !client.sessionResumed)
        let saved = try #require(await persistence.value)
        #expect(saved.streamID != nil && saved.streamID != "expired-session")
        #expect(saved.fullJID == account.jid + "/" + resource)
        #expect(saved.inboundHandled == 0)
        await client.disconnectAndWait()
    }

    @Test func freshBindWithTheSameResourceReplacesTheHibernatingSession() async throws {
        let resource = XMPPClient.makeResource()
        let old = Persistence()
        let first = try await connect(old, resource: resource)
        await first.disconnectAndWait()
        let hibernating = try #require(await old.value)
        // Another process binds fresh (no resumable state) with the installation's resource.
        let replacement = try await connect(Persistence(), resource: resource)
        #expect(await !replacement.sessionResumed)
        await replacement.disconnectAndWait()
        // The server no longer holds the first session: it was replaced, not left behind as a second resource.
        await old.seed(hibernating)
        let probe = try await connect(old, resource: resource)
        #expect(await !probe.sessionResumed)
        await probe.disconnectAndWait()
    }

    /// The stanzas the server holds unacknowledged for a hibernating session of the account.
    private func queued(resource: String) throws -> Int? {
        let jid = try credentials().jid + "/" + resource
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "exec", env["HAUS_LAB_PROSODY_CONTAINER"] ?? "haus-xmpp-lab-prosody-1",
                             "prosodyctl", "shell", "c2s", "show", jid, "jid smacks_queue"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let row = String(decoding: data, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix(jid + " ") }
        return row?.split(separator: "|").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Two installations of one account. Presence from one reaches the other's hibernating session, where Prosody queues
    /// it (and, with push enabled, pushes for it). A resumed session whose availability did not change sends none.
    @Test func resumedAwaySessionSendsNoPresenceToAnotherHibernatingSession() async throws {
        let other = XMPPClient.makeResource(), resource = XMPPClient.makeResource()
        let hibernating = try await connect(Persistence(), resource: other)
        await hibernating.disconnectAndWait()
        let since = Date().addingTimeInterval(-600)
        let persistence = Persistence()
        // A fresh bind announces itself: the other session queues that presence.
        let first = try await connect(persistence, resource: resource, availability: .away(since: since))
        await first.disconnectAndWait()
        let before = try #require(try queued(resource: other))
        #expect(before >= 1)
        // The next run resumes with the same availability: nothing reaches the other session.
        let unchanged = try await connect(persistence, resource: resource, availability: .away(since: since.addingTimeInterval(0.3)))
        #expect(await unchanged.sessionResumed)
        await unchanged.disconnectAndWait()
        #expect(try queued(resource: other) == before)
        // Back in front is a change, and is announced.
        let active = try await connect(persistence, resource: resource)
        #expect(await active.sessionResumed)
        await active.disconnectAndWait()
        #expect(try queued(resource: other) == before + 1)
    }

    /// Prosody's mod_smacks stamps each stanza it queues for a hibernating session with a delay from the account's bare
    /// JID. A message that waited is dated by that stamp on resume, not by when the resumed stream delivered it.
    @Test func aMessageQueuedForAHibernatingSessionKeepsItsQueueTime() async throws {
        let account = try credentials(), resource = XMPPClient.makeResource(), persistence = Persistence()
        let first = try await connect(persistence, resource: resource)
        await first.disconnectAndWait()
        let sender = try await connect(Persistence(), resource: XMPPClient.makeResource())
        let id = "held-" + UUID().uuidString, queuedAt = Date()
        let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 7,
                                         keys: [.init(recipientJID: account.jid, deviceID: 9, keyExchange: false, data: Data([1]))], payload: Data([2]))
        try await sender.sendEncryptedMessage(to: account.jid + "/" + resource, envelope: envelope, id: id)
        await sender.disconnectAndWait()
        try await Task.sleep(for: .seconds(4))
        let resumed = try await connect(persistence, resource: resource)
        #expect(await resumed.sessionResumed)
        var received: XMPPEncryptedMessage?
        for await event in resumed.events {
            if case .encryptedMessage(let message) = event, message.id == id { received = message; break }
        }
        await resumed.disconnectAndWait()
        let held = try #require(received?.serverStamp)
        #expect(abs(held.timeIntervalSince(queuedAt)) < 2, "stamped \(held), sent \(queuedAt)")
    }
}
