import Foundation
import Testing
@testable import XMPPProtocol

/// XEP-0198 resumption against the local lab Prosody. Runs only when configured:
///   HAUS_LAB_RESUME_ACCOUNT  credential JSON ({"jid", "password"}) of a disposable lab account
///   HAUS_LAB_CA              the lab CA (PEM)
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
    private func connect(_ persistence: Persistence, resource: String) async throws -> XMPPClient {
        let account = try credentials()
        let parts = account.jid.split(separator: "@").map(String.init)
        let client = XMPPClient(labCertificateAuthority: try certificateAuthority())
        try await client.configureStreamManagement(persistence: persistence)
        try await client.configureResource(resource)
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
}
