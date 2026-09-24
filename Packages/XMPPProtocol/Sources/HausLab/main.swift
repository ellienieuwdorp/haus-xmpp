import Foundation
import XMPPProtocol

@main struct Lab {
    static func main() async {
        do { try await run() } catch { print("FAILED: TLS or XMPP session could not be established (\(error))"); exit(1) }
    }
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let domain = env["HAUS_LAB_DOMAIN"], let user = env["HAUS_LAB_USERNAME"], let password = env["HAUS_LAB_PASSWORD"] else {
            print("Required environment: HAUS_LAB_DOMAIN, HAUS_LAB_USERNAME, HAUS_LAB_PASSWORD; optional HAUS_LAB_HOST, HAUS_LAB_PORT, HAUS_LAB_CA_DER, HAUS_LAB_TO, HAUS_LAB_BODY. Lab plaintext only.")
            return
        }
        let ca = try env["HAUS_LAB_CA_DER"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let client = XMPPClient(labCertificateAuthority: ca)
        let recovery = LabRecoveryPersistence()
        if env["HAUS_LAB_RECOVERY_SMOKE"] == "1" || env["HAUS_LAB_PUSH_SMOKE"] == "1" { try await client.configureStreamManagement(persistence: recovery) }
        let timeout = Task { try await Task.sleep(for: .seconds(30)); await client.disconnectAndWait() }
        try await client.connect(host: env["HAUS_LAB_HOST"] ?? domain, port: UInt16(env["HAUS_LAB_PORT"] ?? "5223") ?? 5223, domain: domain, username: user, password: password)
        if env["HAUS_LAB_PUSH_SMOKE"] == "1" {
            try await verifyPush(client: client, persistence: recovery)
            timeout.cancel(); await client.disconnectAndWait(); return
        }
        if env["HAUS_LAB_RECOVERY_SMOKE"] == "1" {
            try await verifyRecovery(client: client, persistence: recovery, env: env)
            timeout.cancel(); await client.disconnectAndWait(); return
        }
        if env["HAUS_LAB_CARBONS_SMOKE"] == "1" {
            try await verifyCarbons(client: client, env: env, ca: ca)
            timeout.cancel()
            await client.disconnectAndWait()
            return
        }
        if env["HAUS_LAB_OMEMO_WIRE_SMOKE"] == "1" {
            try await verifyOMEMOWire(client: client, ownJID: user + "@" + domain)
            timeout.cancel()
            await client.disconnectAndWait()
            return
        }
        if env["HAUS_LAB_REPLY_SMOKE"] == "1" {
            guard let to = env["HAUS_LAB_TO"], let sourceID = env["HAUS_LAB_ID"] else { throw XMPPClientError.invalidConfiguration }
            try await verifyReply(client: client, to: to, sourceID: sourceID)
            timeout.cancel()
            await client.disconnectAndWait()
            return
        }
        var receivedCount = 0
        let cycles = max(1, Int(env["HAUS_LAB_CYCLES"] ?? "1") ?? 1)
        for await event in client.events {
            switch event {
            case .streamManagementBarrier(let token): try await client.acknowledgeInbound(token)
            case .state(.online):
                print("ONLINE")
                if let to = env["HAUS_LAB_TO"] {
                    let id = try await client.sendMessage(to: to, body: env["HAUS_LAB_BODY"] ?? "Local protocol smoke test", id: env["HAUS_LAB_ID"] ?? UUID().uuidString)
                    print("SENT \(id)")
                }
            case .state(.disconnected(let reason)):
                print("DISCONNECTED \(reason ?? "requested")")
                if receivedCount > 0 && receivedCount < cycles {
                    try await client.connect(host: env["HAUS_LAB_HOST"] ?? domain, port: UInt16(env["HAUS_LAB_PORT"] ?? "5223") ?? 5223, domain: domain, username: user, password: password)
                } else {
                    timeout.cancel()
                    return
                }
            case .avatarMetadata(let owner, let metadata): print("AVATAR \(owner) \(metadata?.id ?? "removed")")
            case .encryptedMessage, .omemoDevices, .encryptionFailure, .streamAcknowledged: break
            case .state, .encryptedGroupMessage, .groupPresence, .reaction, .retraction, .receipt, .chatState: break
            case .message(let message):
                if let expected = env["HAUS_LAB_EXPECT_BODY"], message.body != expected { throw XMPPClientError.unexpectedProtocol }
                if let expectedID = env["HAUS_LAB_ID"], message.id != expectedID || message.originID != expectedID { throw XMPPClientError.unexpectedProtocol }
                receivedCount += 1
                print("RECEIVED \(message.id) bytes=\(message.body.utf8.count)")
                await client.disconnectAndWait()
            }
        }
    }
    private static func verifyPush(client: XMPPClient, persistence: LabRecoveryPersistence) async throws {
        guard try await client.supportsPushNotifications(), await client.supportsClientStateIndication else { throw XMPPClientError.unexpectedProtocol }
        let before = await persistence.snapshot?.outboundSent
        try await client.setClientActive(false)
        try await client.setClientActive(true)
        guard await persistence.snapshot?.outboundSent == before else { throw XMPPClientError.unexpectedProtocol }
        // Deliberately no APNs gateway or device token: this verifies account-server configuration only.
        let config = try XMPPPushConfiguration(serviceJID: "fixture-push.localhost", node: UUID().uuidString, publishOptions: ["secret": UUID().uuidString])
        try await client.enablePush(config)
        try await client.disablePush(serviceJID: config.serviceJID, node: config.node)
        print("PUSH_REGISTRATION_AND_CSI_VERIFIED")
    }

    private static func verifyRecovery(client: XMPPClient, persistence: LabRecoveryPersistence, env: [String: String]) async throws {
        let domain = env["HAUS_LAB_DOMAIN"]!, user = env["HAUS_LAB_USERNAME"]!
        let ids = (0..<3).map { _ in UUID().uuidString }
        for id in ids { try await client.sendMessage(to: user + "@" + domain, body: "Recovery fixture", id: id) }
        try await client.requestAcknowledgement()
        var received = Set<String>()
        for await event in client.events {
            switch event {
            case .message(let message): received.insert(message.id)
            case .streamManagementBarrier(let token): try await client.acknowledgeInbound(token)
            case .state(.disconnected): throw XMPPClientError.connectionClosed
            default: break
            }
            if received.isSuperset(of: ids), await persistence.acknowledged.isSuperset(of: ids),
               await persistence.snapshot?.inboundHandled ?? 0 >= 3 { break }
        }
        let oldJID = await persistence.snapshot?.fullJID
        await client.disconnectAndWait()
        try await client.connect(host: env["HAUS_LAB_HOST"] ?? domain, domain: domain, username: user, password: env["HAUS_LAB_PASSWORD"]!)
        guard await persistence.snapshot?.fullJID == oldJID else { throw XMPPClientError.unexpectedProtocol }
        print("SM_DURABLE_ACK_AND_RESUME_VERIFIED")
        var cursor: String?, found = Set<String>(), pages = 0
        while true {
            let page = try await client.fetchArchivePage(after: cursor, limit: 2)
            pages += 1
            for item in page.messages { if let id = item.message?.id { found.insert(id) } }
            for token in page.handledTokens { try await client.acknowledgeInbound(token) }
            if page.complete { break }
            guard page.lastID != cursor, pages < 100 else { throw XMPPClientError.unexpectedProtocol }
            cursor = page.lastID
        }
        guard found.isSuperset(of: ids), pages >= 2 else { throw XMPPClientError.unexpectedProtocol }
        print("MAM_PAGED_CATCHUP_VERIFIED")
    }

    /// Verifies delivered fallback body, not incoming structured-reply reconciliation.
    static func verifyReply(client: XMPPClient, to: String, sourceID: String) async throws {
        let source = "Original 👩🏽‍💻 & <text>\nSecond line"
        let answer = "Reply e\u{301} & <answer>"
        let replyID = sourceID + "-reply"
        let expectedReplyBody = "> Original 👩🏽‍💻 & <text>\n> Second line\n" + answer
        _ = try await client.sendMessage(to: to, body: source, id: sourceID)
        var awaitingReply = false
        for await event in client.events {
            switch event {
            case .streamManagementBarrier(let token): try await client.acknowledgeInbound(token)
            case .message(let message):
                guard message.id == (awaitingReply ? replyID : sourceID),
                      message.originID == message.id,
                      message.body == (awaitingReply ? expectedReplyBody : source) else { throw XMPPClientError.unexpectedProtocol }
                if awaitingReply {
                    print("REPLY_BODY_VERIFIED")
                    return
                }
                print("REPLY_SOURCE_VERIFIED")
                awaitingReply = true
                _ = try await client.sendMessage(to: to, body: answer, id: replyID,
                                                 reply: XMPPReply(id: sourceID, to: message.from, body: source))
            case .state(.disconnected): throw XMPPClientError.connectionClosed
            case .avatarMetadata(let owner, let metadata): print("AVATAR \(owner) \(metadata?.id ?? "removed")")
            case .encryptedMessage, .omemoDevices, .encryptionFailure, .streamAcknowledged: break
            case .state, .encryptedGroupMessage, .groupPresence, .reaction, .retraction, .receipt, .chatState: break
            }
        }
        throw XMPPClientError.connectionClosed
    }

    /// Uses intentionally synthetic key bytes: this verifies XML/PEP transport, not cryptography.
    static func verifyOMEMOWire(client: XMPPClient, ownJID: String) async throws {
        let features = try await client.discoveryFeatures()
        guard features.contains("http://jabber.org/protocol/pubsub") else { throw XMPPClientError.unexpectedProtocol }
        for profile in XMPPOMEMOProfile.allCases {
            guard try await client.fetchOMEMODevices(for: ownJID, profile: profile).isEmpty else { throw XMPPClientError.unexpectedProtocol }
            let key = profile == .legacy ? Data([5] + Array(repeating: UInt8(42), count: 32)) : Data(repeating: 42, count: 32)
            let bundle = XMPPOMEMOBundle(profile: profile, deviceID: 123, identityKey: key, signedPreKeyID: 7,
                                         signedPreKey: key, signedPreKeySignature: Data(repeating: 10, count: 64),
                                         preKeys: Dictionary(uniqueKeysWithValues: (1...100).map { (UInt32($0), key) }))
            try await client.publishOMEMOBundle(bundle)
            try await client.publishOMEMODevices([123], profile: profile)
            guard try await client.fetchOMEMODevices(for: ownJID, profile: profile) == [123],
                  try await client.fetchOMEMOBundle(for: ownJID, deviceID: 123, profile: profile) == bundle else { throw XMPPClientError.unexpectedProtocol }
            let envelope = XMPPOMEMOEnvelope(profile: profile, senderDeviceID: 91,
                                            keys: [XMPPOMEMOKey(recipientJID: profile == .modern ? ownJID : nil,
                                                                deviceID: 123, keyExchange: true, data: Data([1, 2, 3]))],
                                            iv: profile == .legacy ? Data(repeating: 10, count: 12) : nil, payload: Data([4, 5, 6]))
            let id = UUID().uuidString
            try await client.sendEncryptedMessage(to: ownJID, envelope: envelope, id: id)
            for await event in client.events {
                if case .state(.disconnected) = event { throw XMPPClientError.connectionClosed }
                if case .encryptionFailure = event { throw XMPPClientError.unexpectedProtocol }
                if case .encryptedMessage(let message) = event {
                    guard message.id == id, message.originID == id, message.envelope == envelope else { throw XMPPClientError.unexpectedProtocol }
                    break
                }
            }
            print("OMEMO_WIRE_\(profile.rawValue.uppercased())_VERIFIED")
        }
    }

    static func verifyCarbons(client: XMPPClient, env: [String: String], ca: Data?) async throws {
        guard let username = env["HAUS_LAB_USERNAME"], let password = env["HAUS_LAB_PASSWORD"],
              let peerUser = env["HAUS_LAB_PEER_USERNAME"], let peerPassword = env["HAUS_LAB_PEER_PASSWORD"],
              let domain = env["HAUS_LAB_DOMAIN"] else { throw XMPPClientError.invalidConfiguration }
        let sibling = XMPPClient(labCertificateAuthority: ca)
        let peer = XMPPClient(labCertificateAuthority: ca)
        try await sibling.connect(host: env["HAUS_LAB_HOST"] ?? domain, domain: domain, username: username, password: password)
        try await peer.connect(host: env["HAUS_LAB_HOST"] ?? domain, domain: domain, username: peerUser, password: peerPassword)
        var siblingJID: String?
        for await event in sibling.events {
            if case .state(.online(let jid)) = event { siblingJID = jid; break }
        }
        guard let siblingJID else { throw XMPPClientError.connectionClosed }
        try await client.setCarbonsEnabled()
        try await sibling.setCarbonsEnabled()
        func sample(_ recipient: String) -> XMPPOMEMOEnvelope {
            XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 91,
                              keys: [XMPPOMEMOKey(recipientJID: recipient, deviceID: 123, keyExchange: true, data: Data([1, 2, 3]))],
                              payload: Data([4, 5, 6]))
        }
        let outgoingID = UUID().uuidString
        try await sibling.sendEncryptedMessage(to: peerUser + "@" + domain, envelope: sample(peerUser + "@" + domain), id: outgoingID)
        for await event in client.events {
            if case .state(.disconnected) = event { throw XMPPClientError.connectionClosed }
            if case .encryptedMessage(let message) = event, message.id == outgoingID {
                guard message.provenance == .sentCarbon, message.from == siblingJID else { throw XMPPClientError.unexpectedProtocol }
                break
            }
        }
        let incomingID = UUID().uuidString
        try await peer.sendEncryptedMessage(to: siblingJID, envelope: sample(username + "@" + domain), id: incomingID)
        for await event in client.events {
            if case .state(.disconnected) = event { throw XMPPClientError.connectionClosed }
            if case .encryptedMessage(let message) = event, message.id == incomingID {
                guard message.provenance == .receivedCarbon, message.to == siblingJID else { throw XMPPClientError.unexpectedProtocol }
                break
            }
        }
        await sibling.disconnectAndWait()
        await peer.disconnectAndWait()
        print("OMEMO_CARBONS_BOTH_DIRECTIONS_VERIFIED")
    }

}

/// Disposable generated-fixture persistence; app uses transactional SQLite and process ownership.
private actor LabRecoveryPersistence: XMPPStreamManagementPersistence {
    var snapshot: XMPPStreamManagementSnapshot?
    var acknowledged: Set<String> = []
    func load() -> XMPPStreamManagementSnapshot? { snapshot }
    func save(_ value: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
        guard snapshot?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
        snapshot = value; acknowledged.formUnion(acknowledgedMessageIDs)
    }
}
