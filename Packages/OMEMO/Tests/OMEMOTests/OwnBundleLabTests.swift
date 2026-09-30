import Foundation
import Testing
import MessageStore
import XMPPProtocol
@testable import OMEMO

/// Our device listed in the account's device lists without its bundle, against the local lab Prosody. The fake server
/// in `ServiceTests` answers item-not-found by construction; this checks what the real server answers for a missing
/// bundle node (the first device) and for the shared OMEMO 2 node that holds another device's item but not ours (the
/// second device). Runs only when the lab is configured:
///   HAUS_LAB_OWNBUNDLE_ACCOUNT  fixture JSON ({"jid", "password"}) of a fresh disposable account under work/
///   HAUS_LAB_CA (PEM)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_OWNBUNDLE_ACCOUNT"] != nil), .serialized)
struct OwnBundleLabTests {
    private let env = ProcessInfo.processInfo.environment
    private struct Fixture: Decodable { let jid: String; let password: String }
    /// Creates local encryption state and then fails, so nothing reaches the server.
    private struct Unreachable: OMEMOTransport {
        func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] { throw OMEMOError.unavailable }
        func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle { throw OMEMOError.unavailable }
        func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { throw OMEMOError.unavailable }
        func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { throw OMEMOError.unavailable }
    }

    private func connect(_ fixture: Fixture) async throws -> XMPPClient {
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        let ca = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let client = XMPPClient(labCertificateAuthority: ca)
        let parts = fixture.jid.split(separator: "@").map(String.init)
        try await client.connect(host: "127.0.0.1", port: 5223, domain: parts[1], username: parts[0], password: fixture.password)
        return client
    }

    @Test func listedDevicesWithoutBundlesPublishThemOnInitialize() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env["HAUS_LAB_OWNBUNDLE_ACCOUNT"]))))
        let account = fixture.jid
        let directory = FileManager.default.temporaryDirectory.appending(path: "ownbundle-lab-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try await connect(fixture)
        for name in ["first", "second"] {
            let store = try MessageStore(url: directory.appending(path: "\(name).sqlite"))
            try await store.acquireTransportOwnership()
            let service = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 9, count: 32)))
            await #expect(throws: OMEMOError.unavailable) { try await service.initialize(account: account, transport: Unreachable()) }
            let local = try await service.overview(account: account, peer: account).localDeviceID
            for profile in [XMPPOMEMOProfile.legacy, .modern] {
                // The own device-list notification during setup, before initialize published anything.
                try await service.maintainLocalAdvertisement(account: account, profile: profile, transport: client)
                let listed = try await client.fetchOMEMODevices(for: account, profile: profile)
                #expect(!listed.contains(local))
                // What another client, an earlier build or a server that lost PEP data can leave behind anyway.
                try await client.publishOMEMODevices(listed.filter { $0 != local } + [local], profile: profile)
                await #expect(throws: XMPPIQError.stanza(condition: "item-not-found")) {
                    try await client.fetchOMEMOBundle(for: account, deviceID: local, profile: profile)
                }
            }
            try await service.initialize(account: account, transport: client)
            for profile in [XMPPOMEMOProfile.legacy, .modern] {
                #expect(try await client.fetchOMEMOBundle(for: account, deviceID: local, profile: profile).deviceID == local)
                #expect(try await client.fetchOMEMODevices(for: account, profile: profile).contains(local))
            }
            // A second pass finds its own identity under its ID in both versions.
            try await service.initialize(account: account, transport: client)
            try await store.close()
        }
        await client.disconnectAndWait()
    }
}
