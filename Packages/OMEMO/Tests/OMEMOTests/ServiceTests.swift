import Foundation
import XCTest
import MessageStore
import XMPPProtocol
import OMEMOCrypto
@testable import OMEMO

private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
private func expectNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotEqual(a, b, file: file, line: line) }
private func expectTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a, file: file, line: line) }
private func expectFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(a, file: file, line: line) }
private func expectNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(a, file: file, line: line) }
private func expectNotNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotNil(a, file: file, line: line) }

private actor PublicationServer {
    var lists: [String: [UInt32]] = [:]
    var bundles: [String: XMPPOMEMOBundle] = [:]
    func devices(_ jid: String, _ profile: XMPPOMEMOProfile) -> [UInt32] { lists[jid + profile.rawValue] ?? [] }
    func bundle(_ jid: String, _ id: UInt32, _ profile: XMPPOMEMOProfile) throws -> XMPPOMEMOBundle {
        guard let value = bundles[jid + profile.rawValue + String(id)] else { throw OMEMOError.noDevices }
        return value
    }
    func publish(_ jid: String, _ ids: [UInt32], _ profile: XMPPOMEMOProfile) { lists[jid + profile.rawValue] = ids }
    func publish(_ jid: String, _ bundle: XMPPOMEMOBundle) { bundles[jid + bundle.profile.rawValue + String(bundle.deviceID)] = bundle }
}
private struct TestTransport: OMEMOTransport {
    let account: String
    let server: PublicationServer
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] { await server.devices(jid, profile) }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle { try await server.bundle(jid, deviceID, profile) }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { await server.publish(account, devices, profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { await server.publish(account, bundle) }
}
private actor EnqueueOnFirstFetch {
    let store: MessageStore
    let message: StoredMessage
    var inserted = false
    init(store: MessageStore, message: StoredMessage) { self.store = store; self.message = message }
    func run() async throws {
        guard !inserted else { return }
        inserted = true
        _ = try await store.enqueueOutgoing(message)
    }
}
private struct InjectingTransport: OMEMOTransport {
    let base: TestTransport
    let injection: EnqueueOnFirstFetch
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        try await injection.run()
        return try await base.fetchOMEMODevices(for: jid, profile: profile)
    }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle { try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile) }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { try await base.publishOMEMODevices(devices, profile: profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { try await base.publishOMEMOBundle(bundle) }
}

@MainActor
private final class ServiceFixture {
    let directory: URL
    let server = PublicationServer()
    let alice = "alice@localhost"
    let bob = "bob@localhost"
    let aStore: MessageStore
    let bStore: MessageStore
    let a: OMEMOService
    let b: OMEMOService
    let protection: StateProtection
    var aTransport: TestTransport { TestTransport(account: alice, server: server) }
    var bTransport: TestTransport { TestTransport(account: bob, server: server) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        aStore = try MessageStore(url: directory.appendingPathComponent("alice.sqlite"))
        bStore = try MessageStore(url: directory.appendingPathComponent("bob.sqlite"))
        protection = try StateProtection(key: Data(repeating: 0x71, count: 32))
        a = OMEMOService(store: aStore, protection: protection)
        b = OMEMOService(store: bStore, protection: protection)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func initialize(_ profile: XMPPOMEMOProfile, trust: Bool = true) async throws {
        try await a.initialize(account: alice, transport: aTransport)
        try await b.initialize(account: bob, transport: bTransport)
        let aOverview = try await a.refreshDevices(account: alice, peer: bob, profile: profile, transport: aTransport)
        let bOverview = try await b.refreshDevices(account: bob, peer: alice, profile: profile, transport: bTransport)
        if trust {
            for device in aOverview.devices where device.active { try await a.setTrust(account: alice, deviceID: device.id, trust: .accepted) }
            for device in bOverview.devices where device.active { try await b.setTrust(account: bob, deviceID: device.id, trust: .accepted) }
        }
    }
    func queue(_ body: String = "Hello encrypted world 👋", id: String = UUID().uuidString, reply: MessageReply? = nil) async throws -> StoredMessage {
        try await aStore.upsertChat(accountID: alice, chatID: bob, title: "Bob")
        let message = StoredMessage(id: id, accountID: alice, chatID: bob, senderID: alice, body: body, isOutgoing: true, reply: reply)
        _ = try await aStore.enqueueOutgoing(message)
        return message
    }
    func message(_ envelope: XMPPOMEMOEnvelope, id: String = "outer-id") -> XMPPEncryptedMessage {
        XMPPEncryptedMessage(id: id, from: alice + "/phone", to: bob + "/phone", originID: "untrusted-origin-id", envelope: envelope)
    }
    func engines(_ store: MessageStore, account: String) async throws -> [String: Data] {
        let loaded = try await store.encryptionState(accountID: account)
        let row = try XCTUnwrap(loaded)
        return try JSONDecoder().decode(AccountEncryptionState.self, from: protection.open(row.data, account: account)).engines
    }
}

@MainActor
final class ServiceTests: XCTestCase {
    private func assertRoundTrip(_ profile: XMPPOMEMOProfile) async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(profile)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        expectEqual(envelope.profile, profile)
        expectNotNil(envelope.payload)
        expectEqual(envelope.keys.count, 1)
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport))
        let received = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        expectEqual(received.count, 1)
        expectEqual(received.first?.body, outgoing.body)
        expectEqual(received.first?.encryptionProfile, profile.rawValue)
        expectFalse(try await f.b.receive(account: f.bob, message: f.message(envelope, id: "different-outer-id"), transport: f.bTransport))
        let reopenedStore = try MessageStore(url: f.directory.appendingPathComponent("bob.sqlite"))
        let reopened = OMEMOService(store: reopenedStore, protection: f.protection)
        expectFalse(try await reopened.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport))
        expectEqual(try await reopenedStore.messages(accountID: f.bob, chatID: f.alice).count, 1)
        expectEqual(try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id), envelope)
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        expectEqual(try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id), envelope)
    }
    func testLegacyDirectRoundTripPersistsAndDeduplicates() async throws { try await assertRoundTrip(.legacy) }
    func testModernDirectRoundTripPersistsAndDeduplicates() async throws { try await assertRoundTrip(.modern) }

    func testUnknownTrustPreservesQueuedAndPendingMessagesUntilAccepted() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern, trust: false)
        let outgoing = try await f.queue()
        do { try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport); XCTFail("Unknown devices must block send") }
        catch { expectEqual(error as? OMEMOError, .trustRequired) }
        expectNil(try await f.aStore.encryptedOutgoing(accountID: f.alice, messageID: outgoing.id))
        let devices = try await f.a.overview(account: f.alice, peer: f.bob).devices
        for device in devices where device.active { try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted) }
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        do { _ = try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport); XCTFail("Unknown sender trust must retain ciphertext") }
        catch { expectEqual(error as? OMEMOError, .trustRequired) }
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).count, 1)
        expectTrue(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        let senderDevices = try await f.b.overview(account: f.bob, peer: f.alice).devices
        for device in senderDevices where device.active { try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted) }
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport)
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first?.body, outgoing.body)
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
    }

    func testTamperedPayloadCannotCommitRatchetThenOriginalDecrypts() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let valid = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        let before = try await f.engines(f.bStore, account: f.bob)
        var payload = try XCTUnwrap(valid.payload)
        payload[payload.startIndex] ^= 0x01
        let invalid = XMPPOMEMOEnvelope(profile: valid.profile, senderDeviceID: valid.senderDeviceID, keys: valid.keys, iv: valid.iv, payload: payload)
        do { _ = try await f.b.receive(account: f.bob, message: f.message(invalid), transport: f.bTransport); XCTFail("Tampered payload accepted") } catch {}
        expectEqual(try await f.engines(f.bStore, account: f.bob), before)
        expectTrue(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(valid), transport: f.bTransport))
    }

    func testChangedIdentityNeverInheritsTrustOrAllowsSealedRetry() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern)
        let original = try await f.a.overview(account: f.alice, peer: f.bob)
        let device = try XCTUnwrap(original.devices.first(where: { $0.jid == f.bob && $0.active }))
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let replacement = try OMEMOEngine(profile: .modern, deviceID: device.deviceID).bundle()
        await f.server.publish(f.bob, XMPPOMEMOBundle(profile: .modern, deviceID: replacement.deviceID, identityKey: replacement.identityKey, signedPreKeyID: replacement.signedPreKeyID, signedPreKey: replacement.signedPreKey, signedPreKeySignature: replacement.signedPreKeySignature, preKeys: replacement.preKeys))
        let updated = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        let changed = try XCTUnwrap(updated.devices.first(where: { $0.jid == f.bob && $0.active }))
        expectTrue(changed.identityChanged)
        expectEqual(changed.trust, .undecided)
        expectNotEqual(changed.id, device.id)
        do { try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .verified); XCTFail("Stale trust sheet accepted replacement") }
        catch { expectEqual(error as? OMEMOError, .identityChanged) }
        do { try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport); XCTFail("Sealed send may not ignore changed recipient") } catch {}
    }

    func testOwnSecondDeviceReceivesSameCiphertextAsPeer() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern)
        let secondStore = try MessageStore(url: f.directory.appendingPathComponent("alice-second.sqlite"))
        let second = OMEMOService(store: secondStore, protection: f.protection)
        try await second.initialize(account: f.alice, transport: f.aTransport)
        let secondOverview = try await second.refreshDevices(account: f.alice, peer: f.bob, profile: .modern, transport: f.aTransport)
        for device in secondOverview.devices where device.active { try await second.setTrust(account: f.alice, deviceID: device.id, trust: .accepted) }
        let firstOverview = try await f.a.refreshDevices(account: f.alice, peer: f.bob, profile: .modern, transport: f.aTransport)
        for device in firstOverview.devices where device.active { try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted) }
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        expectEqual(envelope.keys.count, 2)
        expectTrue(envelope.keys.contains { $0.recipientJID == f.alice && $0.deviceID == secondOverview.localDeviceID })
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport))
        let reordered = XMPPOMEMOEnvelope(profile: envelope.profile, senderDeviceID: envelope.senderDeviceID, keys: envelope.keys.reversed(), iv: envelope.iv, payload: envelope.payload)
        expectFalse(try await f.b.receive(account: f.bob, message: f.message(reordered), transport: f.bTransport))
        let carbon = XMPPEncryptedMessage(id: "carbon-id", from: f.alice + "/phone", to: f.bob, originID: nil, envelope: envelope, provenance: .sentCarbon)
        expectTrue(try await second.receive(account: f.alice, message: carbon, transport: f.aTransport))
        let copies = try await secondStore.messages(accountID: f.alice, chatID: f.bob)
        expectEqual(copies.first?.body, outgoing.body)
        expectEqual(copies.first?.isOutgoing, true)
    }

    func testInvalidPendingCiphertextDoesNotStarveLaterValidMessage() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern, trust: false)
        let senderDevices = try await f.a.overview(account: f.alice, peer: f.bob).devices
        for device in senderDevices where device.active { try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted) }
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let valid = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        var payload = try XCTUnwrap(valid.payload)
        payload[payload.startIndex] ^= 1
        let invalid = XMPPOMEMOEnvelope(profile: valid.profile, senderDeviceID: valid.senderDeviceID, keys: valid.keys, iv: valid.iv, payload: payload)
        do { _ = try await f.b.receive(account: f.bob, message: f.message(invalid), transport: f.bTransport); XCTFail("Expected trust gate") } catch {}
        do { _ = try await f.b.receive(account: f.bob, message: f.message(valid), transport: f.bTransport); XCTFail("Expected trust gate") } catch {}
        let recipientDevices = try await f.b.overview(account: f.bob, peer: f.alice).devices
        for device in recipientDevices where device.active { try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted) }
        // Failure reporting is allowed, starvation of the later independent work is not.
        do { try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport) } catch {}
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first?.body, outgoing.body)
    }

    func testCommittedKeyTransportSurvivesServiceReopenAndConfirmsSessionWithoutBubble() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        expectTrue(envelope.keys.allSatisfy(\.keyExchange))
        _ = try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport)
        let reopened = OMEMOService(store: f.bStore, protection: f.protection)
        let aliceService = f.a, aliceTransport = f.aTransport, account = f.alice, sender = f.bob
        try await reopened.flushKeyTransports(account: f.bob) { recipient, id, response in
            XCTAssertEqual(recipient, account)
            XCTAssertNil(response.payload)
            let message = XMPPEncryptedMessage(id: id, from: sender, to: account, originID: nil, envelope: response)
            let inserted = try await aliceService.receive(account: account, message: message, transport: aliceTransport)
            XCTAssertFalse(inserted)
        }
        expectEqual(try await f.aStore.messages(accountID: f.alice, chatID: f.bob).count, 1)
        let next = try await f.queue("After confirmation")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let confirmed = try await f.a.outgoingEnvelope(account: f.alice, messageID: next.id)
        expectFalse(confirmed.keys.contains( where: \.keyExchange))
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(confirmed), transport: f.bTransport))
    }

    func testOnePublishedDeviceHasSameIdentityAcrossProfilesAndRelaunch() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        let legacy = try await f.a.refreshDevices(account: f.alice, peer: f.alice, profile: .legacy, transport: f.aTransport)
        let modern = try await f.a.refreshDevices(account: f.alice, peer: f.alice, profile: .modern, transport: f.aTransport)
        expectEqual(legacy.localDeviceID, modern.localDeviceID)
        expectEqual(legacy.localFingerprint, modern.localFingerprint)
        let reopened = OMEMOService(store: f.aStore, protection: f.protection)
        try await reopened.initialize(account: f.alice, transport: f.aTransport)
        let after = try await reopened.overview(account: f.alice, peer: f.alice)
        expectEqual(after.localDeviceID, modern.localDeviceID)
        expectEqual(after.localFingerprint, modern.localFingerprint)
    }

    func testPreparationReturnsFixedSnapshotAndDefersConcurrentEnqueue() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern)
        let original = try await f.queue("Already queued")
        let late = StoredMessage(id: "queued-during-network", accountID: f.alice, chatID: f.bob, senderID: f.alice, body: "Added during preparation", isOutgoing: true)
        let injection = EnqueueOnFirstFetch(store: f.aStore, message: late)
        let transport = InjectingTransport(base: f.aTransport, injection: injection)
        let result = try await f.a.prepareAvailableMessages(account: f.alice, transport: transport)
        expectEqual(result.messageIDs, [original.id])
        expectTrue(result.blockedChats.isEmpty)
        expectNil(try await f.aStore.encryptedOutgoing(accountID: f.alice, messageID: late.id))
        let next = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        expectEqual(next.messageIDs, [original.id, late.id])
    }

    func testUntrustedChatDoesNotBlockIndependentTrustedChat() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern)
        let carol = "carol@localhost"
        let carolStore = try MessageStore(url: f.directory.appendingPathComponent("carol.sqlite"))
        let carolService = OMEMOService(store: carolStore, protection: f.protection)
        let transport = TestTransport(account: carol, server: f.server)
        try await carolService.initialize(account: carol, transport: transport)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: carol, title: "Carol")
        let blocked = StoredMessage(id: "blocked-first", accountID: f.alice, chatID: carol, senderID: f.alice, body: "Wait for device acceptance", sentAt: Date(timeIntervalSince1970: 0), isOutgoing: true)
        _ = try await f.aStore.enqueueOutgoing(blocked)
        let allowed = try await f.queue("Deliver independently")
        let result = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        expectEqual(result.messageIDs, [allowed.id])
        expectNotNil(result.blockedChats[carol])
        expectNil(try await f.aStore.encryptedOutgoing(accountID: f.alice, messageID: blocked.id))
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: allowed.id)
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport))
    }

    func testReturningHistoricalIdentityRequiresNewApprovalOnceThenWorks() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern)
        let initial = try await f.a.overview(account: f.alice, peer: f.bob)
        let aIdentity = try XCTUnwrap(initial.devices.first(where: { $0.jid == f.bob && $0.active }))
        try await f.a.setTrust(account: f.alice, deviceID: aIdentity.id, trust: .verified)
        let originalBundle = try await f.server.bundle(f.bob, aIdentity.deviceID, .modern)
        let temporaryIdentity = try OMEMOEngine(profile: .modern, deviceID: aIdentity.deviceID).bundle()
        await f.server.publish(f.bob, XMPPOMEMOBundle(profile: .modern, deviceID: temporaryIdentity.deviceID, identityKey: temporaryIdentity.identityKey, signedPreKeyID: temporaryIdentity.signedPreKeyID, signedPreKey: temporaryIdentity.signedPreKey, signedPreKeySignature: temporaryIdentity.signedPreKeySignature, preKeys: temporaryIdentity.preKeys))
        let changed = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        let bIdentity = try XCTUnwrap(changed.devices.first(where: { $0.jid == f.bob && $0.active }))
        expectNotEqual(bIdentity.id, aIdentity.id)
        try await f.a.setTrust(account: f.alice, deviceID: bIdentity.id, trust: .accepted)
        await f.server.publish(f.bob, originalBundle)
        let returned = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        let returning = try XCTUnwrap(returned.devices.first(where: { $0.jid == f.bob && $0.active }))
        expectEqual(returning.id, aIdentity.id)
        expectEqual(returning.trust, .undecided)
        expectTrue(returning.identityChanged)
        let queued = try await f.queue("After explicit renewed approval")
        let blocked = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        expectFalse(blocked.messageIDs.contains(queued.id))
        expectNotNil(blocked.blockedChats[f.bob])
        try await f.a.setTrust(account: f.alice, deviceID: returning.id, trust: .accepted)
        let refreshed = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        expectEqual(refreshed.devices.first(where: { $0.id == aIdentity.id })?.trust, .accepted)
        let prepared = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        expectTrue(prepared.messageIDs.contains(queued.id))
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: queued.id)
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport))
        let after = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        expectEqual(after.devices.first(where: { $0.id == aIdentity.id })?.identityChanged, false)
        expectEqual(after.devices.first(where: { $0.id == aIdentity.id })?.trust, .accepted)
    }

    func testSavedCiphertextKeepsOriginalProfileWhenSelectionChanges() async throws {
        let f = try ServiceFixture(); defer { f.cleanup() }
        try await f.initialize(.modern)
        let queued = try await f.queue("Exact old-profile ciphertext")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let original = try await f.a.outgoingEnvelope(account: f.alice, messageID: queued.id)
        let legacy = try await f.a.refreshDevices(account: f.alice, peer: f.bob, profile: .legacy, transport: f.aTransport)
        expectEqual(legacy.profile, .legacy)
        // A trust decision about a different profile must not rewrite the prepared ciphertext.
        for device in legacy.devices where device.active { try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .rejected) }
        let prepared = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        expectTrue(prepared.messageIDs.contains(queued.id))
        expectTrue(prepared.blockedChats.isEmpty)
        let retained = try await f.a.outgoingEnvelope(account: f.alice, messageID: queued.id)
        expectEqual(retained, original)
        expectEqual(retained.profile, .modern)
        expectEqual(try await f.a.overview(account: f.alice, peer: f.bob).profile, .legacy)
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(retained), transport: f.bTransport))
    }

    func testProtectedStateCannotMoveBetweenAccountsOrUseWrongKey() throws {
        let protection = try StateProtection(key: Data(repeating: 7, count: 32))
        let ciphertext = try protection.seal(Data("secret state".utf8), account: "alice@localhost")
        XCTAssertThrowsError(try protection.open(ciphertext, account: "bob@localhost"))
        let wrong = try StateProtection(key: Data(repeating: 8, count: 32))
        XCTAssertThrowsError(try wrong.open(ciphertext, account: "alice@localhost"))
        expectEqual(try protection.open(ciphertext, account: "alice@localhost"), Data("secret state".utf8))
    }
}
