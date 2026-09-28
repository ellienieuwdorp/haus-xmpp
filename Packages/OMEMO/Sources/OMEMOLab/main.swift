import Foundation
import Security
import CryptoKit
import MessageStore
import OMEMO
import XMPPProtocol

/// Deliberately narrow integration executable for disposable localhost accounts. The explicit
/// trust flag is a test harness policy, never the app's device-trust policy.
@main struct OMEMOLab {
    enum Failure: Error { case arguments, permissions, unexpectedState, plaintextReceived, timeout, mismatch }
    struct Credentials: Decodable { let jid: String; let password: String }
    struct IdentityRecord: Codable, Equatable {
        let account: String
        let profile: XMPPOMEMOProfile
        let deviceID: UInt32
        let fingerprint: String
        var canonical: IdentityRecord {
            // The initial harness stored legacy serialized-key prefix 05. Display fingerprints
            // now correctly use the raw Curve25519 key; that formatting change is not a new key.
            let normalized = profile == .legacy && fingerprint.count == 66 && fingerprint.hasPrefix("05") ? String(fingerprint.dropFirst(2)) : fingerprint
            return IdentityRecord(account: account, profile: profile, deviceID: deviceID, fingerprint: normalized)
        }
    }

    static func main() async {
        do { try await run() }
        catch {
            // Errors from network or parsers can include peer-controlled text. Keep logs generic.
            if let error = error as? OMEMOError { print("OMEMO_INTEGRATION_FAILED \(error)") }
            else if let error = error as? Failure { print("OMEMO_INTEGRATION_FAILED \(error)") }
            else { print("OMEMO_INTEGRATION_FAILED \(String(describing: type(of: error)))") }
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let switches: Set<String> = ["--accept-test-devices", "--prepare-only", "--resume-prepared"]
        let valued: Set<String> = ["--credentials", "--ca", "--state", "--to", "--profile"]
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if switches.contains(option) { guard flags.insert(option).inserted else { throw Failure.arguments }; index += 1 }
            else {
                guard valued.contains(option), index + 1 < arguments.count, options[option] == nil else { throw Failure.arguments }
                options[option] = arguments[index + 1]; index += 2
            }
        }
        guard flags.contains("--accept-test-devices"),
              !(flags.contains("--prepare-only") && flags.contains("--resume-prepared")),
              let credentialsPath = options["--credentials"], let caPath = options["--ca"],
              let statePath = options["--state"], let peer = options["--to"],
              let profile = XMPPOMEMOProfile(rawValue: options["--profile"] ?? "legacy") else { throw Failure.arguments }
        try requirePrivateFile(credentialsPath)
        let credentials = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: credentialsPath)))
        guard fixtureJID(credentials.jid), fixtureJID(peer), credentials.jid != peer, !credentials.password.isEmpty else { throw Failure.arguments }
        let stateURL = URL(fileURLWithPath: statePath).standardizedFileURL
        guard stateURL.path.contains("/work/"), !stateURL.path.hasSuffix("/work") else { throw Failure.arguments }
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let databaseURL = stateURL.appendingPathComponent("messages.sqlite")
        let keyURL = stateURL.appendingPathComponent("state.key")
        let identityURL = stateURL.appendingPathComponent("identity-\(profile.rawValue).json")
        let key: Data
        if FileManager.default.fileExists(atPath: keyURL.path) {
            try requirePrivateFile(keyURL.path)
            key = try Data(contentsOf: keyURL)
        } else {
            guard !FileManager.default.fileExists(atPath: databaseURL.path) else { throw Failure.unexpectedState }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unexpectedState }
            key = Data(bytes)
            try writePrivate(key, to: keyURL)
        }
        let store = try MessageStore(url: databaseURL)
        try await store.acquireTransportOwnership()
        try await store.recoverInterruptedSubmissions(accountID: credentials.jid)
        let service = OMEMOService(store: store, protection: try StateProtection(key: key))
        let client = XMPPClient(labCertificateAuthority: try Data(contentsOf: URL(fileURLWithPath: caPath)))
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await client.disconnect()
        }
        defer { deadline.cancel() }
        let username = String(credentials.jid.prefix { $0 != "@" })
        try await client.connect(host: "127.0.0.1", domain: "localhost", username: username, password: credentials.password)
        let features = try await client.discoveryFeatures()
        if features.contains("urn:xmpp:carbons:2") { try await client.setCarbonsEnabled() }
        try await service.initialize(account: credentials.jid, transport: client)
        try await service.flushUpdates(account: credentials.jid) { update, prepared in
            guard case .encrypted(let to, let envelope) = prepared else { return }
            try await client.sendEncryptedMessage(to: to, envelope: envelope, id: update.id)
        }
        let overview = try await service.refreshDevices(account: credentials.jid, peer: peer, profile: profile, transport: client)
        let identity = IdentityRecord(account: credentials.jid, profile: profile, deviceID: overview.localDeviceID, fingerprint: overview.localFingerprint)
        if FileManager.default.fileExists(atPath: identityURL.path) {
            try requirePrivateFile(identityURL.path)
            guard try JSONDecoder().decode(IdentityRecord.self, from: Data(contentsOf: identityURL)).canonical == identity.canonical else { throw Failure.mismatch }
            print("PERSISTED_IDENTITY_VERIFIED")
        } else {
            try writePrivate(JSONEncoder().encode(identity), to: identityURL)
        }
        guard overview.devices.contains(where: { $0.jid == peer && $0.active }) else { throw Failure.unexpectedState }
        // Credentials and destination are restricted to generated localhost fixtures above.
        for device in overview.devices where device.active {
            try await service.setTrust(account: credentials.jid, deviceID: device.id, trust: .accepted)
        }
        let message: StoredMessage
        let previousWire: Data?
        if flags.contains("--resume-prepared") {
            let queued = try await store.queuedOutgoing(accountID: credentials.jid)
            guard queued.count == 1, let existing = queued.first, existing.chatID == peer,
                  let wire = try await store.encryptedOutgoing(accountID: credentials.jid, messageID: existing.id) else { throw Failure.unexpectedState }
            message = existing; previousWire = wire
        } else {
            let queued = try await store.queuedOutgoing(accountID: credentials.jid)
            guard queued.isEmpty else { throw Failure.unexpectedState }
            let id = UUID().uuidString
            message = StoredMessage(id: id, accountID: credentials.jid, chatID: peer, senderID: credentials.jid,
                                    body: "Disposable Swift OMEMO check 👋 & <xml> " + UUID().uuidString, isOutgoing: true)
            previousWire = nil
            try await store.upsertChat(accountID: credentials.jid, chatID: peer, title: "Independent test peer")
            try await store.enqueueOutgoing(message)
        }
        try await service.prepareQueuedMessages(account: credentials.jid, transport: client)
        let envelope = try await service.outgoingEnvelope(account: credentials.jid, messageID: message.id)
        guard envelope.profile == profile else { throw Failure.mismatch }
        if let previousWire {
            guard try await store.encryptedOutgoing(accountID: credentials.jid, messageID: message.id) == previousWire else { throw Failure.mismatch }
            print("PERSISTED_CIPHERTEXT_VERIFIED")
        }
        if flags.contains("--prepare-only") {
            print("ENCRYPTED_OUTBOX_PREPARED")
            await client.disconnect()
            return
        }
        guard let submission = try await store.claimNextOutgoing(accountID: credentials.jid), submission.message.id == message.id else { throw Failure.unexpectedState }
        try await client.sendEncryptedMessage(to: peer, envelope: envelope, id: message.id)
        try await store.finishOutgoingSubmission(submission)
        print("ENCRYPTED_SENT")
        for await event in client.events {
            switch event {
            case .encryptedMessage(let incoming):
                guard String(incoming.from.prefix { $0 != "/" }) == peer else { continue }
                _ = try await service.receive(account: credentials.jid, message: incoming, transport: client)
                try await service.flushUpdates(account: credentials.jid) { update, prepared in
                    guard case .encrypted(let to, let envelope) = prepared else { return }
                    try await client.sendEncryptedMessage(to: to, envelope: envelope, id: update.id)
                }
                let messages = try await store.messages(accountID: credentials.jid, chatID: peer, limit: 1_000)
                if messages.contains(where: { !$0.isOutgoing && $0.body == message.body && $0.encryptionProfile == profile.rawValue }) {
                    print("ENCRYPTED_ECHO_VERIFIED \(profile.rawValue)")
                    await client.disconnect()
                    return
                }
            case .message(let incoming):
                if String(incoming.from.prefix { $0 != "/" }) == peer { throw Failure.plaintextReceived }
            case .encryptionFailure: throw Failure.mismatch
            case .state(.disconnected): throw Failure.timeout
            case .state, .omemoDevices, .avatarMetadata, .streamAcknowledged, .streamManagementBarrier, .encryptedGroupMessage, .groupPresence, .reaction, .retraction, .receipt, .chatState, .contactPresence, .subscription, .rosterItems, .displayedSync: break
            }
        }
        throw Failure.timeout
    }

    static func fixtureJID(_ value: String) -> Bool {
        value.range(of: #"^omemo-[a-z0-9-]+@localhost$"#, options: .regularExpression) != nil
    }
    static func requirePrivateFile(_ path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o777 == 0o600 else { throw Failure.permissions }
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure.permissions }
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        try requirePrivateFile(url.path)
    }
}
