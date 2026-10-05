import Foundation
import Testing
@testable import XMPPProtocol

/// An account signed in with capitals in its localpart, against the local lab Prosody (which binds the lowercase JID).
/// Runs only when the lab is configured:
///   HAUS_LAB_JID_ACCOUNT / HAUS_LAB_JID_PEER  credential JSON files ({"jid", "password"}) under work/, lowercase JIDs
///   HAUS_LAB_CA                               the lab CA (PEM)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_JID_ACCOUNT"] != nil), .serialized)
struct JIDLabTests {
    private struct Credentials: Decodable { let jid: String; let password: String }

    private actor Persistence: XMPPStreamManagementPersistence {
        var value: XMPPStreamManagementSnapshot?
        func load() -> XMPPStreamManagementSnapshot? { value }
        func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
            guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
            value = snapshot
        }
    }

    private actor Events {
        var all: [XMPPEvent] = []
        func append(_ event: XMPPEvent) { all.append(event) }
    }

    private let env = ProcessInfo.processInfo.environment

    private func credentials(_ key: String) throws -> Credentials {
        try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env[key]))))
    }

    private func certificateAuthority() throws -> Data {
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        return try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
    }

    /// `p0-jid-a` becomes `P0-Jid-A`: what a password manager or a paste can deliver.
    private func capitalised(_ localpart: Substring) -> String {
        localpart.split(separator: "-", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
    }

    private func connect(_ localpart: String, _ password: String, persistence: Persistence? = nil) async throws -> (XMPPClient, Events, Task<Void, Never>) {
        let client = XMPPClient(labCertificateAuthority: try certificateAuthority())
        if let persistence { try await client.configureStreamManagement(persistence: persistence) }
        let events = Events()
        let consumer = Task {
            for await event in client.events {
                if case .streamManagementBarrier(let token) = event { try? await client.acknowledgeInbound(token) }
                await events.append(event)
            }
        }
        try await client.connect(host: "127.0.0.1", port: 5223, domain: "localhost", username: localpart, password: password)
        return (client, events, consumer)
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<50 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("timed out waiting for \(what)")
    }

    @Test func capitalisedSignInResumesAndRecognisesItsOwnTraffic() async throws {
        let own = try credentials("HAUS_LAB_JID_ACCOUNT"), peer = try credentials("HAUS_LAB_JID_PEER")
        let account = own.jid, typed = capitalised(own.jid.split(separator: "@")[0])
        let typedPeer = capitalised(peer.jid.split(separator: "@")[0]) + "@LocalHost"
        let persistence = Persistence()
        let (first, events, consumer) = try await connect(typed, own.password, persistence: persistence)
        defer { consumer.cancel() }
        let online = await events.all.compactMap { if case .state(.online(let jid)) = $0 { jid } else { nil } }.first
        #expect(online.map { $0.hasPrefix(account + "/") } == true)
        try await first.setCarbonsEnabled()

        // A query addressed as typed is answered by the lowercase entity; before normalisation it timed out.
        do { _ = try await first.discoveryFeatures(for: typedPeer) }
        catch XMPPClientError.timedOut { Issue.record("reply to \(typedPeer) was not matched") }
        catch {}

        // A second session of the same account, spelled differently again: its send comes back to us as a sent
        // carbon, and its device-list publish as our own PEP notification, both in normal form.
        let (second, _, secondConsumer) = try await connect(typed.uppercased(), own.password)
        defer { secondConsumer.cancel() }
        let id = UUID().uuidString
        try await second.sendMessage(to: typedPeer, body: "jid lab \(id)", id: id)
        let device = UInt32.random(in: 1_000_000...2_000_000)
        try await second.publishOMEMODevices([device], profile: .modern)
        try await eventually("sent carbon") {
            await events.all.contains { if case .message(let m) = $0 { m.id == id && m.provenance == .sentCarbon && m.from.hasPrefix(account + "/") && m.to == peer.jid } else { false } }
        }
        try await eventually("own device-list push") {
            await events.all.contains { if case .omemoDevices(let owner, .modern, let devices) = $0 { owner == account && devices.contains(device) } else { false } }
        }
        try await second.publishOMEMODevices([], profile: .modern)
        await second.disconnectAndWait()

        // The saved session names the account as typed; the next connection still resumes it.
        #expect(await persistence.value?.streamID != nil)
        await first.disconnectAndWait()
        let (resumed, _, resumedConsumer) = try await connect(typed, own.password, persistence: persistence)
        defer { resumedConsumer.cancel() }
        #expect(await resumed.sessionResumed)
        await resumed.disconnectAndWait()
    }
}
