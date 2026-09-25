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
        var cursor: String?, found = Set<String>(), pages = 0, sawIQSlot = false
        while true {
            let page = try await client.fetchArchivePage(.after(cursor), limit: 2)
            pages += 1
            // The page IQ was journaled before its write; it must occupy a slot without bytes.
            let journal = await persistence.snapshot?.journal ?? []
            guard journal.allSatisfy({ $0.kind != .iq || $0.xml == nil }) else { throw XMPPClientError.unexpectedProtocol }
            sawIQSlot = sawIQSlot || journal.contains { $0.kind == .iq }
            for item in page.messages { if let id = item.message?.id { found.insert(id) } }
            // Same shape as the app's archive adapter: one batch per page, then <r/> so the server trims our journal.
            if !page.handledTokens.isEmpty {
                try await client.acknowledgeInbound(page.handledTokens)
                try await client.requestAcknowledgement()
            }
            if page.complete { break }
            guard page.lastID != cursor, pages < 100 else { throw XMPPClientError.unexpectedProtocol }
            cursor = page.lastID
        }
        guard found.isSuperset(of: ids), pages >= 2 else { throw XMPPClientError.unexpectedProtocol }
        print("MAM_PAGED_CATCHUP_VERIFIED")
        guard sawIQSlot, await persistence.snapshot?.journal.allSatisfy({ $0.kind != .iq || $0.xml == nil }) == true else {
            throw XMPPClientError.unexpectedProtocol
        }
        print("SM_IQ_JOURNAL_BYTES_ABSENT")
        try await verifyStreamCounters(client: client, persistence: persistence, env: env)
    }

    /// Stream-management counters seen from the server: the `h` we advertise must be durable, a
    /// graceful disconnect must persist handled advances, and an iq journaled but never written
    /// must not shift our outbound count after resume.
    private static func verifyStreamCounters(client: XMPPClient, persistence: LabRecoveryPersistence, env: [String: String]) async throws {
        let domain = env["HAUS_LAB_DOMAIN"]!, user = env["HAUS_LAB_USERNAME"]!, password = env["HAUS_LAB_PASSWORD"]!
        let host = env["HAUS_LAB_HOST"] ?? domain, own = user + "@" + domain
        let inbox = LabInbox()
        let consumer = Task {
            for await event in client.events {
                switch event {
                case .message(let message): await inbox.add(message.id)
                case .streamManagementBarrier(let token): if await !inbox.hold(token) { try? await client.acknowledgeInbound(token) }
                default: break
                }
            }
        }
        defer { consumer.cancel() }
        func resume() async throws {
            let jid = await persistence.snapshot?.fullJID
            try await client.connect(host: host, domain: domain, username: user, password: password)
            // A failed resume binds a fresh resource; only an accepted <resume/> keeps the old one.
            try require(await persistence.snapshot?.fullJID == jid, "server refused <resume/>")
        }

        // 1. The server's <r/> is answered only with a persisted count. The disco result is handled
        // in memory; nothing but the <r/> reply can persist it. An abrupt disconnect skips every
        // other flush, and Prosody refuses a <resume h> below any h we already sent on the wire.
        let before = await persistence.snapshot?.inboundHandled ?? 0
        _ = try await client.discoveryFeatures()
        try require(await waitUntil({ await (persistence.snapshot?.inboundHandled ?? 0) > before }), "server <r/> reply did not persist the handled disco result")
        await client.disconnect()
        try await resume()
        print("SM_ADVERTISED_H_DURABLE_VERIFIED")

        // 2. disconnectAndWait persists handled advances that no <r/> has seen. Barriers are held
        // until the server's ack requests for these messages were answered with a lower count.
        await inbox.setHolding(true)
        let flushIDs = (0..<2).map { _ in "flush-" + UUID().uuidString }
        for id in flushIDs { try await client.sendMessage(to: own, body: "Recovery fixture", id: id) }
        try require(await waitUntil({ let held = await inbox.held.count, seen = await inbox.count(flushIDs); return held == 2 && seen == 2 }), "flush fixtures did not arrive")
        try await Task.sleep(for: .milliseconds(500))
        let held = await inbox.release()
        let persistedBefore = await persistence.snapshot?.inboundHandled ?? 0
        for token in held { try await client.acknowledgeInbound(token) }
        let target = held.map(\.sequence).max() ?? 0
        // Precondition: the advance is in memory only, so the flush below is what persists it.
        try require(persistedBefore < target, "handled advance already persisted before the flush (\(persistedBefore) >= \(target))")
        try require(await persistence.snapshot?.inboundHandled == persistedBefore, "single handled tokens were persisted before disconnectAndWait")
        await client.disconnectAndWait()
        try require(await persistence.snapshot?.inboundHandled ?? 0 >= target, "disconnectAndWait did not persist handled advances")
        try await resume()
        try await Task.sleep(for: .seconds(1))
        // The resumed server count covers both messages, so neither is redelivered.
        try require(await inbox.count(flushIDs) == 2, "server redelivered flushed messages after resume")
        print("SM_DISCONNECT_FLUSH_VERIFIED")

        // 3. An iq journaled but never written (the connection dropped between journal and write).
        try await client.requestAcknowledgement()
        try require(await waitUntil({ await persistence.snapshot?.journal.isEmpty == true }), "journal not trimmed before the drop fixture")
        await persistence.setSaveDelay(.milliseconds(400))
        let lost = Task { try await client.discoveryFeatures() }
        try await Task.sleep(for: .milliseconds(100))
        await client.disconnect()
        _ = try? await lost.value
        // The failed iq returns as soon as the stream ends; its journal commit lands after the delay.
        _ = try await waitUntil({ await persistence.snapshot?.journal.isEmpty == false })
        await persistence.setSaveDelay(nil)
        let dropped = await persistence.snapshot
        try require(dropped?.journal.map(\.kind) == [.iq] && dropped.map { $0.outboundSent == $0.outboundAcknowledged + 1 } == true,
                    "drop fixture did not leave exactly one unwritten iq slot: \(String(describing: dropped?.journal.map(\.kind)))")
        try await resume()
        let resumed = await persistence.snapshot
        try require(resumed?.journal.isEmpty == true && resumed.map { $0.outboundSent == $0.outboundAcknowledged } == true,
                    "resume kept the unwritten iq slot in the outbound count")
        let probe = "drift-" + UUID().uuidString
        try await client.sendMessage(to: own, body: "Recovery fixture", id: probe)
        try await client.requestAcknowledgement()
        // The server's count for the probe must confirm the probe itself, not the dead iq slot.
        try require(await waitUntil({ let accepted = await persistence.acknowledged.contains(probe), empty = await persistence.snapshot?.journal.isEmpty; return accepted && empty == true }),
                    "server acknowledgement did not confirm the probe")
        await client.disconnectAndWait()
        try await resume()
        try await Task.sleep(for: .seconds(1))
        // A second resume retransmits nothing, so the probe arrives exactly once.
        try require(await inbox.count([probe]) == 1, "probe delivered \(await inbox.count([probe])) times")
        print("SM_RESUME_DROPS_UNSENT_IQ_SLOTS_VERIFIED")
    }

    private static func require(_ condition: Bool, _ failure: String) throws {
        if !condition { throw LabCheckFailed(description: failure) }
    }

    private static func waitUntil(_ condition: () async -> Bool, timeout: Duration = .seconds(5)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
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
    /// Widens the window between journaling a stanza and writing it, to model a drop inside it.
    var saveDelay: Duration?
    func load() -> XMPPStreamManagementSnapshot? { snapshot }
    func setSaveDelay(_ delay: Duration?) { saveDelay = delay }
    func save(_ value: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) async throws {
        guard snapshot?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
        if let saveDelay { try? await Task.sleep(for: saveDelay) }
        guard snapshot?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
        snapshot = value; acknowledged.formUnion(acknowledgedMessageIDs)
    }
}

private struct LabCheckFailed: Error, CustomStringConvertible { let description: String }

/// Counts deliveries per message ID and can hold stream barriers back from acknowledgement.
private actor LabInbox {
    private var ids: [String] = []
    private(set) var held: [XMPPInboundToken] = []
    private var holding = false
    func add(_ id: String) { ids.append(id) }
    func count(_ wanted: [String]) -> Int { ids.filter(wanted.contains).count }
    func setHolding(_ value: Bool) { holding = value }
    func hold(_ token: XMPPInboundToken) -> Bool { if holding { held.append(token) }; return holding }
    func release() -> [XMPPInboundToken] { holding = false; defer { held = [] }; return held }
}
