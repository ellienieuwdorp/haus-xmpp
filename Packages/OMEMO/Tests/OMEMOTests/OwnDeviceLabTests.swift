import Foundation
import Testing
import MessageStore
import XMPPProtocol
@testable import OMEMO

/// A second installation signs in to an account against the local lab Prosody: the first one finds it through the
/// account-level refresh (real PEP device lists and bundles, both versions), holds sending until it is reviewed, and one
/// decision releases the send to the contact and the new installation. The new installation lists the first at once.
/// Message delivery itself is not exercised here: the prepared envelope is handed to the receivers directly.
/// Runs only when the lab is configured:
///   HAUS_LAB_OWNDEVICE_APP, HAUS_LAB_OWNDEVICE_PEER  fixture JSONs ({"jid", "password"}) of fresh disposable accounts
///   HAUS_LAB_CA (PEM)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_OWNDEVICE_APP"] != nil), .serialized)
struct OwnDeviceLabTests {
    private let env = ProcessInfo.processInfo.environment
    private struct Fixture: Decodable { let jid: String; let password: String }

    private func fixture(_ key: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env[key]))))
    }

    private func connect(_ fixture: Fixture) async throws -> XMPPClient {
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        let ca = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let client = XMPPClient(labCertificateAuthority: ca)
        let parts = fixture.jid.split(separator: "@").map(String.init)
        try await client.connect(host: "127.0.0.1", port: 5223, domain: parts[1], username: parts[0], password: fixture.password)
        return client
    }

    @Test func reviewingTheNewInstallationReleasesTheHeldSend() async throws {
        let app = try fixture("HAUS_LAB_OWNDEVICE_APP"), peer = try fixture("HAUS_LAB_OWNDEVICE_PEER")
        let directory = FileManager.default.temporaryDirectory.appending(path: "owndevice-lab-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let protection = try StateProtection(key: Data(repeating: 7, count: 32))
        func service(_ name: String) async throws -> (MessageStore, OMEMOService) {
            let store = try MessageStore(url: directory.appending(path: "\(name).sqlite"))
            try await store.acquireTransportOwnership()
            return (store, OMEMOService(store: store, protection: protection))
        }
        let appClient = try await connect(app), peerClient = try await connect(peer)
        let (firstStore, first) = try await service("first")
        let (secondStore, second) = try await service("second")
        let (peerStore, contact) = try await service("peer")
        try await first.initialize(account: app.jid, transport: appClient)
        try await contact.initialize(account: peer.jid, transport: peerClient)
        // The contact's device is reviewed in the chat as usual; no own device exists yet.
        for device in try await first.refreshDevices(account: app.jid, peer: peer.jid, profile: .modern, transport: appClient).devices
        where device.active && device.jid == peer.jid {
            try await first.setTrust(account: app.jid, deviceID: device.id, trust: .accepted)
        }
        #expect(try await first.refreshOwnDevices(account: app.jid, transport: appClient).isEmpty)

        // A second installation of the account signs in.
        try await second.initialize(account: app.jid, transport: appClient)
        let secondID = try await second.localIdentity(account: app.jid, profile: .modern).deviceID
        let found = try await first.refreshOwnDevices(account: app.jid, transport: appClient)
        #expect(found.map(\.deviceID) == [secondID, secondID])
        #expect(Set(found.map(\.profile)) == [.legacy, .modern])
        #expect(found.allSatisfy { $0.trust == .undecided && $0.active })
        #expect(Set(found.map(\.fingerprint)).count == 1)

        try await firstStore.upsertChat(accountID: app.jid, chatID: peer.jid, title: "Peer")
        let message = StoredMessage(id: UUID().uuidString, accountID: app.jid, chatID: peer.jid, senderID: app.jid, body: "Reviewed", isOutgoing: true)
        _ = try await firstStore.enqueueOutgoing(message)
        let held = try await first.prepareAvailableMessages(account: app.jid, transport: appClient)
        #expect(held.messageIDs.isEmpty)
        #expect(held.blockedChats[peer.jid] == OMEMOError.trustRequired.errorDescription)

        try await first.setTrust(account: app.jid, deviceIDs: found.map(\.id), trust: .accepted)
        let released = try await first.prepareAvailableMessages(account: app.jid, transport: appClient)
        #expect(released.messageIDs == [message.id])
        let envelope = try await first.outgoingEnvelope(account: app.jid, messageID: message.id)
        #expect(envelope.keys.contains { $0.recipientJID == app.jid && $0.deviceID == secondID })

        // The contact reviews the account's devices on their side, as they would in their chat.
        for device in try await contact.refreshDevices(account: peer.jid, peer: app.jid, profile: .modern, transport: peerClient).devices
        where device.active && device.jid == app.jid {
            try await contact.setTrust(account: peer.jid, deviceID: device.id, trust: .accepted)
        }
        let toPeer = XMPPEncryptedMessage(id: "lab-send", from: app.jid + "/first", to: peer.jid, originID: nil, envelope: envelope)
        #expect(try await contact.receive(account: peer.jid, message: toPeer, transport: peerClient))
        #expect(try await peerStore.messages(accountID: peer.jid, chatID: app.jid).map(\.body) == ["Reviewed"])

        // The new installation lists the first one at once, undecided; once it accepts it, the carbon opens there.
        let firstID = try await first.localIdentity(account: app.jid, profile: .modern).deviceID
        let seenBySecond = try await second.refreshOwnDevices(account: app.jid, transport: appClient)
        #expect(Set(seenBySecond.map(\.deviceID)) == [firstID])
        #expect(seenBySecond.allSatisfy { $0.trust == .undecided })
        try await second.setTrust(account: app.jid, deviceIDs: seenBySecond.map(\.id), trust: .accepted)
        let carbon = XMPPEncryptedMessage(id: "lab-carbon", from: app.jid + "/first", to: peer.jid, originID: nil, envelope: envelope, provenance: .sentCarbon)
        #expect(try await second.receive(account: app.jid, message: carbon, transport: appClient))
        #expect(try await secondStore.messages(accountID: app.jid, chatID: peer.jid).map(\.body) == ["Reviewed"])

        for store in [firstStore, secondStore, peerStore] { try await store.close() }
        await appClient.disconnectAndWait()
        await peerClient.disconnectAndWait()
    }
}
