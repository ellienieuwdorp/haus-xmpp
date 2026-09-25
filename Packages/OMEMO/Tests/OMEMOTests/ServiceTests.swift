import Foundation
import XCTest
import MessageStore
import XMPPProtocol
import OMEMOCrypto
import SQLite3
@testable import OMEMO

private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
private func expectNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotEqual(a, b, file: file, line: line) }
private func expectTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a, file: file, line: line) }
private func expectFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(a, file: file, line: line) }
private func expectNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(a, file: file, line: line) }
private func expectNotNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotNil(a, file: file, line: line) }

actor PublicationServer {
    var lists: [String: [UInt32]] = [:]
    var bundles: [String: XMPPOMEMOBundle] = [:]
    func devices(_ jid: String, _ profile: XMPPOMEMOProfile) -> [UInt32] { lists[jid + profile.rawValue] ?? [] }
    func bundle(_ jid: String, _ id: UInt32, _ profile: XMPPOMEMOProfile) throws -> XMPPOMEMOBundle {
        guard let value = bundles[jid + profile.rawValue + String(id)] else { throw XMPPIQError.stanza(condition: "item-not-found") }
        return value
    }
    func publish(_ jid: String, _ ids: [UInt32], _ profile: XMPPOMEMOProfile) { lists[jid + profile.rawValue] = ids }
    func publish(_ jid: String, _ bundle: XMPPOMEMOBundle) { bundles[jid + bundle.profile.rawValue + String(bundle.deviceID)] = bundle }
}
struct TestTransport: OMEMOTransport {
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

private struct OfflineTransport: OMEMOTransport {
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] { throw OMEMOError.unavailable }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle { throw OMEMOError.unavailable }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { throw OMEMOError.unavailable }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { throw OMEMOError.unavailable }
}
private struct RegisterDuringBundlePublication: OMEMOTransport {
    let base: TestTransport
    let otherDevice: UInt32
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] { try await base.fetchOMEMODevices(for: jid, profile: profile) }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle { try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile) }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { try await base.publishOMEMODevices(devices, profile: profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws {
        try await base.publishOMEMOBundle(bundle)
        // Another installation finishes registering while our bundle IQ is in flight.
        await base.server.publish(base.account, [otherDevice], bundle.profile)
    }
}

/// What a transport was asked for, in order: lets tests pin exactly which network work a receive performs.
actor TransportLog {
    enum Call: Equatable {
        case devices(String, XMPPOMEMOProfile)
        case bundle(String, UInt32, XMPPOMEMOProfile)
        case publishDevices(XMPPOMEMOProfile)
        case publishBundle(XMPPOMEMOProfile)
        case refreshRoom(String)
    }
    private(set) var calls: [Call] = []
    private(set) var notes: [String] = []
    /// Requests for someone's devices or keys; publications of our own bundle after a prekey message are not lookups.
    var fetches: [Call] {
        calls.filter { if case .devices = $0 { return true }; if case .bundle = $0 { return true }; return false }
    }
    func record(_ call: Call) { calls.append(call) }
    func note(_ text: String) { notes.append(text) }
}
struct CountingTransport: OMEMOTransport {
    let base: TestTransport
    let log: TransportLog
    /// Runs before a bundle fetch is delegated (for example to check what is already durable at that point).
    var beforeBundle: (@Sendable (String, UInt32) async throws -> Void)? = nil
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        await log.record(.devices(jid, profile))
        return try await base.fetchOMEMODevices(for: jid, profile: profile)
    }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        await log.record(.bundle(jid, deviceID, profile))
        try await beforeBundle?(jid, deviceID)
        return try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile)
    }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws {
        await log.record(.publishDevices(profile))
        try await base.publishOMEMODevices(devices, profile: profile)
    }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws {
        await log.record(.publishBundle(bundle.profile))
        try await base.publishOMEMOBundle(bundle)
    }
}
/// Runs `action` once, on the first device-list fetch, then behaves like `base`.
private actor OnFirstFetch {
    private var action: (@Sendable () async throws -> Void)?
    init(_ action: @escaping @Sendable () async throws -> Void) { self.action = action }
    func run() async throws {
        guard let action else { return }
        self.action = nil
        try await action()
    }
}
private struct InterleavingTransport: OMEMOTransport {
    let base: TestTransport
    let first: OnFirstFetch
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        try await first.run()
        return try await base.fetchOMEMODevices(for: jid, profile: profile)
    }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle { try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile) }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { try await base.publishOMEMODevices(devices, profile: profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { try await base.publishOMEMOBundle(bundle) }
}

@MainActor
final class ServiceFixture {
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
    private var additionalStores: [MessageStore] = []
    func openStore(_ name: String) throws -> MessageStore {
        let store = try MessageStore(url: directory.appendingPathComponent(name))
        additionalStores.append(store)
        return store
    }
    func cleanup() async throws {
        for store in additionalStores { try await store.close() }
        try await aStore.close()
        try await bStore.close()
        try FileManager.default.removeItem(at: directory)
    }
    func initialize(_ profile: XMPPOMEMOProfile, trust: Bool = true) async throws {
        try await aStore.acquireTransportOwnership()
        try await bStore.acquireTransportOwnership()
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
    func message(_ envelope: XMPPOMEMOEnvelope, id: String = "outer-id", fallbackBody: Bool = false) -> XMPPEncryptedMessage {
        XMPPEncryptedMessage(id: id, from: alice + "/phone", to: bob + "/phone", originID: "untrusted-origin-id", envelope: envelope, hasFallbackBody: fallbackBody)
    }
    func engines(_ store: MessageStore, account: String) async throws -> [String: Data] {
        let loaded = try await store.encryptionState(accountID: account)
        let row = try XCTUnwrap(loaded)
        return try JSONDecoder().decode(AccountEncryptionState.self, from: protection.open(row.data, account: account)).engines
    }
}

@MainActor
final class ServiceTests: XCTestCase {
    /// A device that publishes keys only in the other OMEMO version is left out of the envelope and reported, never a
    /// reason to hold the chat: with three own clients on one account that rule kept messages queued indefinitely.
    func testDevicesPublishedOnlyInTheOtherVersionAreReportedNotBlocking() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        // Bob's phone also runs a client that speaks only OMEMO 2, and Alice's other client only OMEMO 2.
        await f.server.publish(f.bob, [4242], .modern)
        await f.server.publish(f.alice, [777, 778], .modern)
        let overview = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        expectEqual(overview.profile, .legacy)
        expectTrue(overview.hasIncompatibleDevices)
        expectEqual(overview.otherVersionOnlyDevices[f.bob], 1)
        expectEqual(overview.otherVersionOnlyDevices[f.alice], 2)
        let outgoing = try await f.queue()
        let preparation = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
        expectEqual(preparation.messageIDs, [outgoing.id])
        expectTrue(preparation.blockedChats.isEmpty)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        expectEqual(envelope.profile, .legacy)
        expectFalse(envelope.keys.contains { $0.deviceID == 4242 || $0.deviceID == 777 || $0.deviceID == 778 })
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport))
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), [outgoing.body])
    }

    private func assertRoundTrip(_ profile: XMPPOMEMOProfile) async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
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
        let reopenedStore = try f.openStore("bob.sqlite")
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
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
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
        expectEqual(try await f.b.pendingConversations(account: f.bob), [f.alice: 1])
        expectTrue(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        let senderDevices = try await f.b.overview(account: f.bob, peer: f.alice).devices
        for device in senderDevices where device.active { try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted) }
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport)
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first?.body, outgoing.body)
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        expectTrue(try await f.b.pendingConversations(account: f.bob).isEmpty)
    }

    func testTamperedPayloadCannotCommitRatchetThenOriginalDecrypts() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let valid = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        let before = try await f.engines(f.bStore, account: f.bob)
        var payload = try XCTUnwrap(valid.payload)
        payload[payload.startIndex] ^= 0x01
        let invalid = XMPPOMEMOEnvelope(profile: valid.profile, senderDeviceID: valid.senderDeviceID, keys: valid.keys, iv: valid.iv, payload: payload)
        do { _ = try await f.b.receive(account: f.bob, message: f.message(invalid), transport: f.bTransport); XCTFail("Tampered payload accepted") }
        catch { expectEqual(error as? OMEMOError, .undecryptable) }
        expectEqual(try await f.engines(f.bStore, account: f.bob), before)
        // A trusted device's ciphertext that fails authentication is a quiet placeholder, never content, never pending.
        let afterTamper = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        expectEqual(afterTamper.count, 1)
        expectEqual(afterTamper.first?.unreadableReason, .decryptFailed)
        expectEqual(afterTamper.first?.body, "")
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(valid), transport: f.bTransport))
        let afterValid = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        expectEqual(afterValid.count, 2)
        expectEqual(afterValid.last?.body, outgoing.body)
        expectNil(afterValid.last?.unreadableReason)
    }

    func testTrustedSenderDecryptFailureLeavesTheTableAndIsNotRetried() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let alice = try await f.a.localIdentity(account: f.alice, profile: .modern)
        let bob = try await f.b.localIdentity(account: f.bob, profile: .modern)
        let garbage = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: alice.deviceID,
                                        keys: [XMPPOMEMOKey(recipientJID: f.bob, deviceID: bob.deviceID, keyExchange: false, data: Data(repeating: 7, count: 64))],
                                        payload: Data(repeating: 9, count: 48))
        let message = f.message(garbage)
        expectFalse(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        let before = try await f.engines(f.bStore, account: f.bob)
        do { _ = try await f.b.receive(account: f.bob, message: message, transport: f.bTransport); XCTFail("Garbage key decrypted") }
        catch { expectEqual(error as? OMEMOError, .undecryptable) }
        expectEqual(try await f.engines(f.bStore, account: f.bob), before)
        let rows = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        expectEqual(rows.map(\.unreadableReason), [.decryptFailed])
        expectEqual(rows.first?.isOutgoing, false)
        expectEqual(rows.first?.senderID, f.alice)
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        expectTrue(try await f.b.pendingConversations(account: f.bob).isEmpty)
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport)
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).count, 1)
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        // Re-seeing the ciphertext (reconnect, archive page) is a replay: no second row, no error.
        expectFalse(try await f.b.receive(account: f.bob, message: message, transport: f.bTransport))
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).count, 1)
    }

    func testUndecryptableKeyTransportIsConsumedWithoutPlaceholder() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let alice = try await f.a.localIdentity(account: f.alice, profile: .modern)
        let bob = try await f.b.localIdentity(account: f.bob, profile: .modern)
        let transport = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: alice.deviceID,
                                          keys: [XMPPOMEMOKey(recipientJID: f.bob, deviceID: bob.deviceID, keyExchange: false, data: Data(repeating: 7, count: 64))],
                                          payload: nil)
        let message = f.message(transport)
        // A key transport was never a message: nothing to show, nothing to retry, and a replay is a no-op.
        expectFalse(try await f.b.receive(account: f.bob, message: message, transport: f.bTransport))
        expectTrue(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        expectFalse(try await f.b.receive(account: f.bob, message: message, transport: f.bTransport))
    }

    func testOwnDeviceSendWithoutKeyForThisDeviceLeavesOutgoingPlaceholder() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        func own(_ profile: XMPPOMEMOProfile, payload: Data) -> XMPPEncryptedMessage {
            XMPPEncryptedMessage(id: "other-device-send", from: f.alice + "/other", to: f.bob, originID: nil,
                                 envelope: XMPPOMEMOEnvelope(profile: profile, senderDeviceID: 424242, keys: [],
                                                             iv: profile == .legacy ? Data(repeating: 1, count: 12) : nil, payload: payload),
                                 provenance: .sentCarbon)
        }
        let legacy = own(.legacy, payload: Data([1, 2, 3]))
        do { _ = try await f.a.receive(account: f.alice, message: legacy, transport: f.aTransport, sentAt: stamp); XCTFail("No key for this device") }
        catch { expectEqual(error as? OMEMOError, .notForThisDevice) }
        let rows = try await f.aStore.messages(accountID: f.alice, chatID: f.bob)
        expectEqual(rows.count, 1)
        let row = try unwrap(rows.first)
        expectTrue(row.isOutgoing)
        expectEqual(row.senderID, f.alice)
        expectEqual(row.sentAt, stamp)
        expectEqual(row.unreadableReason, .notForThisDevice)
        expectEqual(row.encryptionProfile, "unreadable")
        expectNil(row.wireID)
        expectNil(row.transportState)
        expectTrue(try await f.aStore.pendingEncryptedIncoming(accountID: f.alice).isEmpty)
        expectTrue(try await f.a.hasDurableIncomingDisposition(account: f.alice, message: legacy))
        // The live carbon and the archived copy are the same ciphertext: still one row.
        do { _ = try await f.a.receive(account: f.alice, message: legacy, transport: f.aTransport); XCTFail("No key for this device") }
        catch { expectEqual(error as? OMEMOError, .notForThisDevice) }
        expectEqual(try await f.aStore.messages(accountID: f.alice, chatID: f.bob).count, 1)
        // A modern envelope without a body fallback or receipt request may be a reaction or receipt: no bubble.
        let modern = own(.modern, payload: Data([4, 5, 6]))
        do { _ = try await f.a.receive(account: f.alice, message: modern, transport: f.aTransport, sentAt: stamp); XCTFail("No key for this device") }
        catch { expectEqual(error as? OMEMOError, .notForThisDevice) }
        expectEqual(try await f.aStore.messages(accountID: f.alice, chatID: f.bob).count, 1)
        expectTrue(try await f.a.hasDurableIncomingDisposition(account: f.alice, message: modern))
        var requested = modern; requested.requestsReceipt = true
        do { _ = try await f.a.receive(account: f.alice, message: requested, transport: f.aTransport, sentAt: stamp); XCTFail("No key for this device") }
        catch { expectEqual(error as? OMEMOError, .notForThisDevice) }
        expectEqual(try await f.aStore.messages(accountID: f.alice, chatID: f.bob).count, 2)
    }

    func testPendingReasonsFollowDeviceKnowledgeAndTrust() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern, trust: false)
        for device in try await f.a.overview(account: f.alice, peer: f.bob).devices where device.active {
            try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
        }
        let first = try await f.queue("From the known device")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let known = try await f.a.outgoingEnvelope(account: f.alice, messageID: first.id)
        do { _ = try await f.b.receive(account: f.bob, message: f.message(known), transport: f.bTransport); XCTFail("Trust undecided") }
        catch { expectEqual(error as? OMEMOError, .trustRequired) }
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])

        // A second installation of alice that bob has never fetched: while offline its row waits for keys.
        let secondStore = try f.openStore("alice-second.sqlite")
        try await secondStore.acquireTransportOwnership()
        let second = OMEMOService(store: secondStore, protection: f.protection)
        try await second.initialize(account: f.alice, transport: f.aTransport)
        for device in try await second.refreshDevices(account: f.alice, peer: f.bob, profile: .modern, transport: f.aTransport).devices where device.active {
            try await second.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
        }
        try await secondStore.upsertChat(accountID: f.alice, chatID: f.bob, title: "Bob")
        let other = StoredMessage(id: "from-second", accountID: f.alice, chatID: f.bob, senderID: f.alice, body: "From the new device", isOutgoing: true)
        _ = try await secondStore.enqueueOutgoing(other)
        try await second.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let unknown = try await second.outgoingEnvelope(account: f.alice, messageID: other.id)
        do { _ = try await f.b.receive(account: f.bob, message: f.message(unknown, id: "second"), transport: OfflineTransport()); XCTFail("Device unknown") } catch {}
        let pending = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        expectEqual(pending.map(\.reason), [.trustPending, .keysPending])

        // A trust decision retries only trust-pending rows.
        do { try await f.b.retryPendingIncoming(account: f.bob, transport: OfflineTransport(), reasons: [.trustPending]) } catch {}
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).count, 2)
        let author = try unwrap(try await f.b.overview(account: f.bob, peer: f.alice).devices.first { $0.jid == f.alice && $0.active })
        try await f.b.setTrust(account: f.bob, deviceID: author.id, trust: .accepted)
        try await f.b.retryPendingIncoming(account: f.bob, transport: OfflineTransport(), reasons: [.trustPending])
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), [first.body])
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.keysPending])

        // The owner's device list arrives: the row is refreshed and now waits for trust instead.
        do { try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport, reasons: [.keysPending], sender: f.alice); XCTFail("New device undecided") }
        catch { expectEqual(error as? OMEMOError, .trustRequired) }
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
        for device in try await f.b.overview(account: f.bob, peer: f.alice).devices where device.active && device.trust == .undecided {
            try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        }
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport, reasons: [.trustPending])
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), [first.body, other.body])
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
    }

    func testChangedIdentityNeverInheritsTrustOrAllowsSealedRetry() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let original = try await f.a.overview(account: f.alice, peer: f.bob)
        let device = try XCTUnwrap(original.devices.first(where: { $0.jid == f.bob && $0.active }))
        _ = try await f.queue()
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

    func testListedDeviceWithoutBundleIsSkippedNotFatal() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let before = try await f.a.overview(account: f.alice, peer: f.bob)
        let active = before.devices.filter { $0.jid == f.bob && $0.active }.map(\.deviceID)
        await f.server.publish(f.bob, active + [4_242], .modern)
        let updated = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        expectEqual(Set(updated.devices.filter { $0.jid == f.bob && $0.active }.map(\.deviceID)), Set(active))
        expectFalse(updated.devices.contains { $0.deviceID == 4_242 })
        expectEqual(updated.unavailableDevices[f.bob], 1)
    }

    func testEmptyProbeDoesNotPinAVersionThePeerNeverPublished() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.aStore.acquireTransportOwnership()
        try await f.bStore.acquireTransportOwnership()
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        try await f.b.initialize(account: f.bob, transport: f.bTransport)
        let legacy = await f.server.devices(f.bob, .legacy)
        let modern = await f.server.devices(f.bob, .modern)
        await f.server.publish(f.bob, [], .legacy)
        await f.server.publish(f.bob, [], .modern)
        let unreachable = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        expectTrue(unreachable.devices.filter { $0.jid == f.bob }.isEmpty)
        await f.server.publish(f.bob, legacy, .legacy)
        await f.server.publish(f.bob, modern, .modern)
        let recovered = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport)
        expectEqual(recovered.profile, .legacy)
        expectFalse(recovered.devices.filter { $0.jid == f.bob && $0.active }.isEmpty)
    }

    func testPeerIsKnownOnlyAfterACompletedRefresh() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let carol = "carol@localhost"
        try await f.aStore.acquireTransportOwnership()
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        expectFalse(try await f.a.overview(account: f.alice, peer: carol).isPeerKnown)
        do { _ = try await f.a.refreshDevices(account: f.alice, peer: carol, transport: OfflineTransport()); XCTFail("Offline refresh completed") } catch {}
        expectFalse(try await f.a.overview(account: f.alice, peer: carol).isPeerKnown)
        // Carol publishes nothing: a completed answer, so "no devices" is now a stored fact.
        let empty = try await f.a.refreshDevices(account: f.alice, peer: carol, transport: f.aTransport)
        expectTrue(empty.isPeerKnown)
        expectTrue(empty.devices.filter { $0.jid == carol }.isEmpty)
        let reopened = OMEMOService(store: f.aStore, protection: f.protection)
        expectTrue(try await reopened.overview(account: f.alice, peer: carol).isPeerKnown)
    }

    func testOwnSecondDeviceReceivesSameCiphertextAsPeer() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let secondStore = try f.openStore("alice-second.sqlite")
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
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
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
        let received = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        expectEqual(received.first { $0.unreadableReason == nil }?.body, outgoing.body)
        // The tampered copy, now from a trusted device, left the pending table as a placeholder instead of retrying forever.
        expectEqual(received.compactMap(\.unreadableReason), [.decryptFailed])
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
    }

    func testCommittedKeyTransportSurvivesServiceReopenAndConfirmsSessionWithoutBubble() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        expectTrue(envelope.keys.allSatisfy(\.keyExchange))
        _ = try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport)
        let reopened = OMEMOService(store: f.bStore, protection: f.protection)
        let aliceService = f.a, aliceTransport = f.aTransport, account = f.alice, sender = f.bob
        try await reopened.flushUpdates(account: f.bob) { update, prepared in
            guard case .encrypted(let recipient, let response) = prepared else { return XCTFail("key transport is a direct envelope") }
            let id = update.id
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
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
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
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
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
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let carol = "carol@localhost"
        let carolStore = try f.openStore("carol.sqlite")
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
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
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
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
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

    func testTrustedInboundDecryptsOfflineAndRetriesBundlePublicationAfterRestart() async throws {
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
            try await f.initialize(profile)
            let outgoing = try await f.queue("Available offline")
            try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
            let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
            expectTrue(try await f.b.receive(account: f.bob, message: f.message(envelope), transport: OfflineTransport()))
            let row = try unwrap(try await f.bStore.encryptionState(accountID: f.bob))
            let state = try JSONDecoder().decode(AccountEncryptionState.self, from: f.protection.open(row.data, account: f.bob))
            expectEqual(state.pendingBundlePublications, [profile.rawValue])
            let reopened = OMEMOService(store: f.bStore, protection: f.protection)
            try await reopened.flushBundlePublications(account: f.bob, transport: f.bTransport)
            let refreshedRow = try unwrap(try await f.bStore.encryptionState(accountID: f.bob))
            let refreshed = try JSONDecoder().decode(AccountEncryptionState.self, from: f.protection.open(refreshedRow.data, account: f.bob))
            expectTrue(refreshed.pendingBundlePublications.isEmpty)
            let local = try OMEMOEngine(snapshot: XCTUnwrap(refreshed.engines[profile.rawValue]))
            let published = try await f.server.bundle(f.bob, local.deviceID, profile)
            expectEqual(published.preKeys, try local.bundle().preKeys)
            expectFalse(try await reopened.receive(account: f.bob, message: f.message(envelope), transport: OfflineTransport()))
        }
    }

    func testDelayedApprovedSenderStillDecryptsWhenAbsentFromDeviceList() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue("Sent before device retirement")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        await f.server.publish(f.alice, [], .modern)
        let refreshed = try await f.b.refreshDevices(account: f.bob, peer: f.alice, profile: .modern, transport: f.bTransport)
        expectFalse(refreshed.devices.contains { $0.jid == f.alice && $0.active })
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(envelope), transport: OfflineTransport()))
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first?.body, outgoing.body)
    }

    func testExplicitRepairPreservesIdentityDraftCiphertextAndDelayedSession() async throws {
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
            try await f.initialize(profile)
            let first = try await f.queue("Establish session")
            try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
            let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: first.id)
            _ = try await f.b.receive(account: f.bob, message: f.message(envelope), transport: f.bTransport)
            let a = f.a, at = f.aTransport, account = f.alice, sender = f.bob
            try await f.b.flushUpdates(account: f.bob) { update, prepared in
                guard case .encrypted(let recipient, let response) = prepared else { return XCTFail("key transport is a direct envelope") }
                let id = update.id
                _ = try await a.receive(account: account, message: XMPPEncryptedMessage(id: id, from: sender, to: recipient, originID: nil, envelope: response), transport: at)
            }
            let delayed = try await f.queue("In flight before repair")
            try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
            let delayedEnvelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: delayed.id)
            let draft = try await f.queue("Unencrypted queued intention")
            let before = try await f.a.overview(account: f.alice, peer: f.bob)
            let device = try XCTUnwrap(before.devices.first { $0.jid == f.bob && $0.active })
            try await f.a.repairSession(account: f.alice, deviceID: device.id, transport: f.aTransport)
            let after = try await f.a.overview(account: f.alice, peer: f.bob)
            expectEqual(before.localDeviceID, after.localDeviceID)
            expectEqual(before.localFingerprint, after.localFingerprint)
            expectEqual(try await f.a.outgoingEnvelope(account: f.alice, messageID: delayed.id), delayedEnvelope)
            expectNil(try await f.aStore.encryptedOutgoing(accountID: f.alice, messageID: draft.id))
            let b = f.b, bt = f.bTransport, bob = f.bob, alice = f.alice
            let reopened = OMEMOService(store: f.aStore, protection: f.protection)
            try await reopened.flushUpdates(account: f.alice) { update, prepared in
                guard case .encrypted(let recipient, let response) = prepared else { return XCTFail("key transport is a direct envelope") }
                let id = update.id
                XCTAssertTrue(response.keys.allSatisfy(\.keyExchange))
                XCTAssertNil(response.payload)
                let message = XMPPEncryptedMessage(id: id, from: alice, to: recipient, originID: nil, envelope: response)
                let inserted = try await b.receive(account: bob, message: message, transport: bt)
                XCTAssertFalse(inserted)
            }
            expectTrue(try await f.b.receive(account: f.bob, message: f.message(delayedEnvelope), transport: f.bTransport))
            expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).count, 2)
        }
    }

    func testRepairRejectsReplacementFingerprintAndLeavesKeysAndDraftUntouched() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let device = try unwrap(try await f.a.overview(account: f.alice, peer: f.bob).devices.first { $0.jid == f.bob && $0.active })
        let before = try await f.engines(f.aStore, account: f.alice)
        let queued = try await f.queue()
        let replacement = try OMEMOEngine(profile: .modern, deviceID: device.deviceID).bundle()
        await f.server.publish(f.bob, XMPPOMEMOBundle(profile: .modern, deviceID: replacement.deviceID, identityKey: replacement.identityKey, signedPreKeyID: replacement.signedPreKeyID, signedPreKey: replacement.signedPreKey, signedPreKeySignature: replacement.signedPreKeySignature, preKeys: replacement.preKeys))
        do { try await f.a.repairSession(account: f.alice, deviceID: device.id, transport: f.aTransport); XCTFail("Stale fingerprint repaired a replacement") }
        catch { expectEqual(error as? OMEMOError, .identityChanged) }
        expectEqual(try await f.engines(f.aStore, account: f.alice), before)
        expectNil(try await f.aStore.encryptedOutgoing(accountID: f.alice, messageID: queued.id))
        expectNil(try await f.aStore.claimNextUpdate(accountID: f.alice))
    }

    func testOwnDeviceRetirementRemovesBothProfilesAndPreservesOtherDevices() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let secondStore = try f.openStore("alice-second.sqlite")
        let second = OMEMOService(store: secondStore, protection: f.protection)
        try await second.initialize(account: f.alice, transport: f.aTransport)
        let before = try await f.a.refreshDevices(account: f.alice, peer: f.bob, profile: .modern, transport: f.aTransport)
        let selected = try XCTUnwrap(before.devices.first { $0.jid == f.alice && $0.active })
        // A third device registers after the review sheet was opened.
        let thirdStore = try f.openStore("alice-third.sqlite")
        let third = OMEMOService(store: thirdStore, protection: f.protection)
        try await third.initialize(account: f.alice, transport: f.aTransport)
        let thirdID = try await third.overview(account: f.alice, peer: f.alice).localDeviceID
        try await f.a.retireOwnDevice(account: f.alice, deviceID: selected.id, transport: f.aTransport)
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let remaining = await f.server.devices(f.alice, profile)
            expectEqual(Set(remaining), Set([before.localDeviceID, thirdID]))
        }
        let after = try await f.a.overview(account: f.alice, peer: f.bob)
        expectEqual(after.localFingerprint, before.localFingerprint)
        expectEqual(after.devices.first { $0.id == selected.id }?.trust, .rejected)
        expectEqual(after.devices.first { $0.id == selected.id }?.active, false)
    }

    func testOwnAdvertisementMergesConcurrentRegistrationAndRestoresLostPublication() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let transport = RegisterDuringBundlePublication(base: f.aTransport, otherDevice: 424242)
        try await f.a.initialize(account: f.alice, transport: transport)
        let local = try await f.a.overview(account: f.alice, peer: f.alice).localDeviceID
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            expectEqual(Set(await f.server.devices(f.alice, profile)), Set([local, 424242]))
            await f.server.publish(f.alice, [424242, 999999], profile)
            try await f.a.maintainLocalAdvertisement(account: f.alice, profile: profile, transport: f.aTransport)
            expectEqual(Set(await f.server.devices(f.alice, profile)), Set([local, 424242, 999999]))
        }
    }

    func testMalformedSignedBundleDoesNotReplaceReviewedFingerprint() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let before = try await f.a.overview(account: f.alice, peer: f.bob)
        let device = try XCTUnwrap(before.devices.first { $0.jid == f.bob && $0.active })
        let bundle = try await f.server.bundle(f.bob, device.deviceID, .modern)
        var signature = bundle.signedPreKeySignature
        signature[0] ^= 1
        await f.server.publish(f.bob, XMPPOMEMOBundle(profile: .modern, deviceID: bundle.deviceID, identityKey: bundle.identityKey, signedPreKeyID: bundle.signedPreKeyID, signedPreKey: bundle.signedPreKey, signedPreKeySignature: signature, preKeys: bundle.preKeys))
        do { _ = try await f.a.refreshDevices(account: f.alice, peer: f.bob, transport: f.aTransport); XCTFail("Accepted invalid signature") } catch {}
        expectEqual(try await f.a.overview(account: f.alice, peer: f.bob).devices, before.devices)
    }

    func testRetainedArchiveTimestampAndDurableDispositionSurviveTrustRetry() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern, trust: false)
        let devices = try await f.a.overview(account: f.alice, peer: f.bob).devices
        for device in devices where device.active { try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted) }
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        let message = f.message(envelope)
        expectFalse(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        do { _ = try await f.b.receive(account: f.bob, message: message, transport: f.bTransport, sentAt: stamp); XCTFail("Trust missing") } catch {}
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        let approved = try await f.b.overview(account: f.bob, peer: f.alice).devices
        for device in approved where device.active { try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted) }
        let reopened = OMEMOService(store: f.bStore, protection: f.protection)
        try await reopened.retryPendingIncoming(account: f.bob, transport: OfflineTransport())
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first?.sentAt, stamp)
        expectTrue(try await reopened.hasDurableIncomingDisposition(account: f.bob, message: message))
        let notAddressed = XMPPOMEMOEnvelope(profile: envelope.profile, senderDeviceID: envelope.senderDeviceID,
                                            keys: [], iv: envelope.iv, payload: envelope.payload)
        // A would-be bubble without a key for this device is durable only once its placeholder exists.
        let hinted = f.message(notAddressed, fallbackBody: true)
        expectFalse(try await reopened.hasDurableIncomingDisposition(account: f.bob, message: hinted))
        do { _ = try await reopened.receive(account: f.bob, message: hinted, transport: OfflineTransport(), sentAt: stamp); XCTFail("No key for this device") }
        catch { expectEqual(error as? OMEMOError, .notForThisDevice) }
        let placeholders = try await f.bStore.messages(accountID: f.bob, chatID: f.alice).filter { $0.unreadableReason != nil }
        expectEqual(placeholders.count, 1)
        let placeholder = try unwrap(placeholders.first)
        expectEqual(placeholder.unreadableReason, .notForThisDevice)
        expectFalse(placeholder.isOutgoing)
        expectEqual(placeholder.senderID, f.alice)
        expectEqual(placeholder.chatID, f.alice)
        expectEqual(placeholder.sentAt, stamp)
        expectTrue(try await reopened.hasDurableIncomingDisposition(account: f.bob, message: hinted))
        do { _ = try await reopened.receive(account: f.bob, message: hinted, transport: OfflineTransport()); XCTFail("No key for this device") }
        catch { expectEqual(error as? OMEMOError, .notForThisDevice) }
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).count, 2)
        // Without a hint (modern: possibly a reaction or receipt) nothing is stored and nothing is owed.
        var silentPayload = try unwrap(envelope.payload); silentPayload[silentPayload.startIndex] ^= 0x01
        let silent = f.message(XMPPOMEMOEnvelope(profile: envelope.profile, senderDeviceID: envelope.senderDeviceID, keys: [], iv: envelope.iv, payload: silentPayload))
        do { _ = try await reopened.receive(account: f.bob, message: silent, transport: OfflineTransport()); XCTFail("No key for this device") }
        catch { expectEqual(error as? OMEMOError, .notForThisDevice) }
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).count, 2)
        expectTrue(try await reopened.hasDurableIncomingDisposition(account: f.bob, message: silent))
        // Ambiguous duplicate keys no longer wedge the archive walk: a malformed-content placeholder is the disposition.
        // (A distinct payload: the unaddressed identity deliberately ignores keys, so the same payload is the same message.)
        var doubledPayload = try unwrap(envelope.payload); doubledPayload[doubledPayload.startIndex + 1] ^= 0x01
        let ambiguous = XMPPOMEMOEnvelope(profile: envelope.profile, senderDeviceID: envelope.senderDeviceID,
                                          keys: envelope.keys + envelope.keys, iv: envelope.iv, payload: doubledPayload)
        let doubled = f.message(ambiguous, fallbackBody: true)
        expectFalse(try await reopened.hasDurableIncomingDisposition(account: f.bob, message: doubled))
        do { _ = try await reopened.receive(account: f.bob, message: doubled, transport: OfflineTransport(), sentAt: stamp); XCTFail("Ambiguous keys") }
        catch { expectEqual(error as? OMEMOError, .undecryptable) }
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).compactMap(\.unreadableReason).sorted { $0.rawValue < $1.rawValue },
                    [.malformedContent, .notForThisDevice])
        expectTrue(try await reopened.hasDurableIncomingDisposition(account: f.bob, message: doubled))
    }

    func testStreamReplayAndArchiveReconciliationRequireExactSavedCiphertextAndContext() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let queued = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: queued.id)
        expectTrue(try await f.a.canReplay(account: f.alice, xml: XMPPClient.encryptedMessageXML(to: f.bob, envelope: envelope, id: queued.id)))
        expectFalse(try await f.a.canReplay(account: f.alice, xml: XMPPClient.encryptedMessageXML(to: "mallory@localhost", envelope: envelope, id: queued.id)))
        expectFalse(try await f.a.canReplay(account: f.alice, xml: XMPPClient.encryptedMessageXML(to: f.bob, envelope: envelope, id: "control-or-unknown")))
        let forged = XMPPEncryptedMessage(id: queued.id, from: f.alice, to: "mallory@localhost", originID: nil, envelope: envelope, provenance: .sentCarbon)
        expectFalse(try await f.a.reconcileArchivedOutgoing(account: f.alice, message: forged))
        let direct = XMPPEncryptedMessage(id: queued.id, from: f.alice, to: f.bob, originID: nil, envelope: envelope)
        expectFalse(try await f.a.reconcileArchivedOutgoing(account: f.alice, message: direct))
        let archive = XMPPEncryptedMessage(id: queued.id, from: f.alice, to: f.bob, originID: nil, envelope: envelope, provenance: .sentCarbon)
        expectTrue(try await f.a.reconcileArchivedOutgoing(account: f.alice, message: archive))
        expectEqual(try await f.aStore.message(accountID: f.alice, messageID: queued.id)?.transportState, .serverAccepted)
        let device = try unwrap(try await f.a.overview(account: f.alice, peer: f.bob).devices.first { $0.jid == f.bob && $0.active })
        try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .rejected)
        expectFalse(try await f.a.canReplay(account: f.alice, xml: XMPPClient.encryptedMessageXML(to: f.bob, envelope: envelope, id: queued.id)))
    }

    func testPrivateReactionSetsReplaceClearAndDoNotCreateChatBubbles() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue("React to this authenticated message")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let text = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        _ = try await f.b.receive(account: f.bob, message: f.message(text), transport: f.bTransport)
        let target = try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first)
        expectEqual(target.wireID, outgoing.id)
        expectTrue(target.wireIDAuthenticated)
        let bobService = f.b, bobStore = f.bStore, aliceService = f.a, account = f.alice, sender = f.bob, aliceTransport = f.aTransport
        for values in [["👍", "❤️"], ["❤️"], []] {
            let id = try await bobService.queueReactions(account: f.bob, chatID: f.alice, messageID: target.id, reactions: values)
            let prepared = try await bobService.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
            expectTrue(prepared.messageIDs.contains(id))
            let envelope = try await bobService.outgoingUpdateEnvelope(account: f.bob, updateID: id)
            expectNotNil(envelope.payload)
            try await bobService.flushUpdates(account: f.bob, updateIDs: prepared.messageIDs) { update, prepared in
                guard case .encrypted(let recipient, let reactionEnvelope) = prepared else { return XCTFail("direct reaction is an envelope") }
                let updateID = update.id
                let message = XMPPEncryptedMessage(id: updateID, from: sender, to: recipient, originID: updateID, envelope: reactionEnvelope)
                let changed = try await aliceService.receive(account: account, message: message, transport: aliceTransport)
                // Bob's queued key transport (his prekey answer) rides the same drain and changes nothing visible.
                XCTAssertEqual(changed, reactionEnvelope.payload != nil)
            }
            let projected = try await f.a.reactions(account: f.alice, chatID: f.bob, messageID: outgoing.id)
            expectEqual(projected.first?.actorID, f.bob)
            expectEqual(projected.first?.reactions, values.sorted())
            expectEqual(try await f.aStore.messages(accountID: f.alice, chatID: f.bob).count, 1)
            expectEqual(try await bobStore.messages(accountID: f.bob, chatID: f.alice).count, 1)
            expectFalse(try await f.a.receive(account: f.alice, message: XMPPEncryptedMessage(id: id, from: f.bob, to: f.alice, originID: nil, envelope: envelope), transport: OfflineTransport()))
            // A manual retry is immutable and the receiver deduplicates it.
            try await bobService.retryUpdate(account: f.bob, updateID: id)
            expectEqual(try await bobService.outgoingUpdateEnvelope(account: f.bob, updateID: id), envelope)
            // Finish the retry so the following iteration has only its new update queued.
            let next = try await bobService.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
            try await bobService.flushUpdates(account: f.bob, updateIDs: next.messageIDs) { _, _ in }
        }
    }

    func testDelayedOlderReactionDoesNotOverwriteNewerAndTimestampCannotFreeze() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        _ = try await f.b.receive(account: f.bob, message: f.message(try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)), transport: f.bTransport)
        let target = try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first)
        let olderID = try await f.b.queueReactions(account: f.bob, chatID: f.alice, messageID: target.id, reactions: ["👍"])
        _ = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
        let older = try await f.b.outgoingUpdateEnvelope(account: f.bob, updateID: olderID)
        let newerID = try await f.b.queueReactions(account: f.bob, chatID: f.alice, messageID: target.id, reactions: ["❤️"])
        _ = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
        let newer = try await f.b.outgoingUpdateEnvelope(account: f.bob, updateID: newerID)
        let newerMessage = XMPPEncryptedMessage(id: newerID, from: f.bob, to: f.alice, originID: nil, envelope: newer)
        _ = try await f.a.receive(account: f.alice, message: newerMessage, transport: f.aTransport, sentAt: Date(timeIntervalSince1970: 1_700_000_100))
        let olderMessage = XMPPEncryptedMessage(id: olderID, from: f.bob, to: f.alice, originID: nil, envelope: older)
        _ = try await f.a.receive(account: f.alice, message: olderMessage, transport: f.aTransport, sentAt: Date(timeIntervalSince1970: 1_700_000_000))
        expectEqual(try await f.a.reactions(account: f.alice, chatID: f.bob, messageID: outgoing.id).first?.reactions, ["❤️"])
        let futureID = try await f.b.queueReactions(account: f.bob, chatID: f.alice, messageID: target.id, reactions: ["😄"])
        _ = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
        let future = try await f.b.outgoingUpdateEnvelope(account: f.bob, updateID: futureID)
        _ = try await f.a.receive(account: f.alice, message: XMPPEncryptedMessage(id: futureID, from: f.bob, to: f.alice, originID: nil, envelope: future), transport: f.aTransport, sentAt: Date.distantFuture)
        let projected = try await f.a.reactions(account: f.alice, chatID: f.bob, messageID: outgoing.id)
        expectTrue(try unwrap(projected.first).updatedAt <= Date())
    }

    func testValidatedArchiveCorrectsRetainedLiveTimestampBeforeTrustRetry() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        _ = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let snapshots = try await f.engines(f.aStore, account: f.alice)
        let sender = try OMEMOEngine(snapshot: unwrap(snapshots[XMPPOMEMOProfile.modern.rawValue]))
        let receiver = try unwrap(try await f.a.overview(account: f.alice, peer: f.bob).devices.first { $0.jid == f.bob && $0.active })
        let historicalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let xml = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>Delayed delivery</body></content><rpad>padding</rpad><from jid='alice@localhost'/><to jid='bob@localhost'/><time stamp='2023-11-14T22:13:20Z'/></envelope>"
        let payload = try PayloadCrypto.seal(Data(xml.utf8), profile: .modern)
        let key = try sender.encrypt(payload.keyMaterial, to: DeviceAddress(jid: f.bob, deviceID: receiver.deviceID))
        let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: sender.deviceID,
            keys: [XMPPOMEMOKey(recipientJID: f.bob, deviceID: receiver.deviceID, keyExchange: key.isPreKey, data: key.data)],
            iv: nil, payload: payload.payload)
        let incoming = XMPPEncryptedMessage(id: "live", from: f.alice + "/phone", to: nil,
                                            originID: nil, envelope: envelope, provenance: .direct)
        let archived = XMPPEncryptedMessage(id: "archive", from: f.alice + "/phone", to: f.bob,
                                            originID: nil, envelope: envelope, provenance: .receivedCarbon)
        do {
            _ = try await f.b.receive(account: f.bob, message: incoming, transport: OfflineTransport())
            XCTFail("Historical authenticated SCE time must not match a current live arrival context")
        } catch { expectEqual(error as? OMEMOError, .invalidContent) }
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).count, 1)
        let author = try unwrap(try await f.b.overview(account: f.bob, peer: f.alice).devices.first { $0.jid == f.alice && $0.active })
        try await f.b.setTrust(account: f.bob, deviceID: author.id, trust: .rejected)
        let pendingBefore = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        for invalid in [
            XMPPEncryptedMessage(id: "wrong-recipient", from: f.alice, to: "mallory@localhost", originID: nil,
                                 envelope: envelope, provenance: .receivedCarbon),
            XMPPEncryptedMessage(id: "wrong-direction", from: f.alice, to: f.bob, originID: nil,
                                 envelope: envelope, provenance: .sentCarbon)
        ] {
            do {
                _ = try await f.b.receive(account: f.bob, message: invalid, transport: OfflineTransport(), sentAt: historicalDate)
                XCTFail("Archive correction must preserve recipient and direction binding")
            } catch { expectEqual(error as? OMEMOError, .invalidContent) }
            expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).first?.wire, pendingBefore.first?.wire)
        }
        do {
            _ = try await f.b.receive(account: f.bob, message: archived, transport: OfflineTransport(), sentAt: historicalDate)
            XCTFail("Archive context cannot override rejected fingerprint trust")
        } catch { expectEqual(error as? OMEMOError, .trustRequired) }
        let reopened = OMEMOService(store: f.bStore, protection: f.protection)
        try await reopened.setTrust(account: f.bob, deviceID: author.id, trust: .accepted)
        try await reopened.retryPendingIncoming(account: f.bob, transport: OfflineTransport())
        let received = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        expectEqual(received.count, 1)
        expectEqual(received.first?.body, "Delayed delivery")
        expectEqual(received.first?.sentAt, historicalDate)
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
    }

    func testLegacyMessageWithoutOriginIDIsReactableByStanzaID() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        let bare = XMPPEncryptedMessage(id: "stanza-id", from: f.alice + "/phone", to: f.bob, originID: nil, envelope: envelope)
        expectTrue(try await f.b.receive(account: f.bob, message: bare, transport: f.bTransport))
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first?.wireID, "stanza-id")
    }

    func testLegacyReactionQueuesExactPlainStanzaAndPermitsOnlyIdenticalReplay() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        // A legacy peer can only receive plain XEP-0444, so the exact stanza becomes the durable wire.
        let id = try await f.a.queueReactions(account: f.alice, chatID: f.bob, messageID: outgoing.id, reactions: ["👍"])
        let prepared = try await f.a.prepareAvailableUpdates(account: f.alice, transport: f.aTransport)
        expectTrue(prepared.messageIDs == [id] && prepared.blockedChats.isEmpty)
        let xml = String(decoding: try unwrap(try await f.aStore.updateWire(accountID: f.alice, updateID: id)), as: UTF8.self)
        expectEqual(xml, try XMPPClient.reactionXML(to: f.bob, targetID: outgoing.id, reactions: ["👍"], id: id))
        expectTrue(try await f.a.canReplay(account: f.alice, xml: xml))
        expectFalse(try await f.a.canReplay(account: f.alice, xml: xml.replacingOccurrences(of: "👍", with: "❤️")))
        // Preparing again is idempotent, and nothing was ever sealed as an OMEMO envelope.
        expectTrue(try await f.a.prepareAvailableUpdates(account: f.alice, transport: f.aTransport).messageIDs == [id])
        do { _ = try await f.a.outgoingUpdateEnvelope(account: f.alice, updateID: id); XCTFail("plain wire is not an envelope") } catch {}
        // The drain resolves the plain wire back into the deterministic serializer inputs.
        let bob = f.bob, targetID = outgoing.id
        try await f.a.flushUpdates(account: f.alice, updateIDs: [id]) { update, prepared in
            XCTAssertEqual(prepared, .plainReaction(to: bob, targetID: targetID, reactions: ["👍"]))
            XCTAssertEqual(update.kind, .reaction)
        }
        expectEqual(try await f.aStore.update(accountID: f.alice, updateID: id)?.transportState, .unconfirmed)
    }

    func testEveryDurableUpdateKindPermitsResumptionOnlyAsItsExactSealedWire() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        // A first-class message.
        let queued = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let message = try await f.a.outgoingEnvelope(account: f.alice, messageID: queued.id)
        expectTrue(try await f.a.canReplay(account: f.alice, xml: XMPPClient.encryptedMessageXML(to: f.bob, envelope: message, id: queued.id)))
        // A key transport: bob answers alice's prekey message. Previously never replayable.
        _ = try await f.b.receive(account: f.bob, message: f.message(message), transport: f.bTransport)
        let transport = try unwrap(try await f.bStore.queuedUpdates(accountID: f.bob, kind: .keyTransport).first)
        let response = try unwrap(f.b.savedEnvelope(try unwrap(try await f.bStore.updateWire(accountID: f.bob, updateID: transport.id))))
        expectTrue(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: response, id: transport.id)))
        expectFalse(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: "mallory@localhost", envelope: response, id: transport.id)))
        expectFalse(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: message, id: transport.id)))
        // An encrypted reaction.
        let target = try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first)
        let reactionID = try await f.b.queueReactions(account: f.bob, chatID: f.alice, messageID: target.id, reactions: ["👍"])
        let prepared = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
        expectEqual(prepared.messageIDs, [transport.id, reactionID])
        let reaction = try await f.b.outgoingUpdateEnvelope(account: f.bob, updateID: reactionID)
        expectTrue(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: reaction, id: reactionID)))
        // An encrypted delivery receipt and read marker.
        let receiptID = try unwrap(try await f.b.queueReceipt(account: f.bob, chatID: f.alice, messageID: target.id, kind: .receipt))
        let markerID = try unwrap(try await f.b.queueReceipt(account: f.bob, chatID: f.alice, messageID: target.id, kind: .marker))
        let sealed = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
        expectTrue(sealed.messageIDs.isSuperset(of: [receiptID, markerID]))
        let receipt = try await f.b.outgoingUpdateEnvelope(account: f.bob, updateID: receiptID)
        let marker = try await f.b.outgoingUpdateEnvelope(account: f.bob, updateID: markerID)
        expectTrue(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: receipt, id: receiptID)))
        expectTrue(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: marker, id: markerID)))
        expectFalse(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: marker, id: receiptID)))
        // Blocking the addressed device revokes every envelope prepared for it, header-only ones included.
        let device = try unwrap(try await f.b.overview(account: f.bob, peer: f.alice).devices.first { $0.jid == f.alice && $0.active })
        try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .rejected)
        expectFalse(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: response, id: transport.id)))
        expectFalse(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: reaction, id: reactionID)))
        expectFalse(try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: f.alice, envelope: receipt, id: receiptID)))
    }

    func testRequestedReceiptsAndReadMarkersRoundTripInsideTheEnvelope() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue("Please confirm")
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let text = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        // The outer `<request/>` is what Bob's inbound path sees; his delivery receipt is queued durably at commit time.
        let asked = try XMPPClient.decodeOutgoingEncryptedMessageXML(try XMPPClient.encryptedMessageXML(to: f.bob, envelope: text, id: outgoing.id, requestReceipt: true, markable: true), from: f.alice)
        expectTrue(try await f.b.receive(account: f.bob, message: asked, transport: f.bTransport))
        let received = try unwrap(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first)
        var queued = try await f.bStore.queuedReceipts(accountID: f.bob)
        expectEqual(queued.map(\.kind), [.receipt])
        expectEqual(queued.first?.targetMessageID, received.id)
        // Reading it once queues one marker; showing it again does not.
        expectNotNil(try await f.b.queueReceipt(account: f.bob, chatID: f.alice, messageID: received.id, kind: .marker))
        expectNil(try await f.b.queueReceipt(account: f.bob, chatID: f.alice, messageID: received.id, kind: .marker))
        queued = try await f.bStore.queuedReceipts(accountID: f.bob)
        expectEqual(queued.map(\.kind), [.receipt, .marker])
        let prepared = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
        let aliceService = f.a, aliceTransport = f.aTransport, alice = f.alice, bob = f.bob
        try await f.b.flushUpdates(account: f.bob, updateIDs: prepared.messageIDs) { update, prepared in
            guard case .encrypted(let recipient, let envelope) = prepared else { return XCTFail("direct receipts are envelopes") }
            let message = XMPPEncryptedMessage(id: update.id, from: bob, to: recipient, originID: update.id, envelope: envelope)
            let changed = try await aliceService.receive(account: alice, message: message, transport: aliceTransport)
            XCTAssertEqual(changed, envelope.payload != nil)
        }
        let events = try await f.aStore.events(accountID: f.alice, chatID: f.bob, messageID: outgoing.id)
        expectEqual(events.map(\.kind), [.delivered, .displayed])
        expectTrue(events.allSatisfy { $0.actorID == f.bob })
        expectEqual(try await f.aStore.messages(accountID: f.alice, chatID: f.bob).count, 1)
        // Switching delivery receipts off means nothing is queued for the next request.
        try await f.bStore.setAccountPreferences(accountID: f.bob, AccountPreferences(deliveryReceipts: false))
        let second = try await f.queue("Again", id: UUID().uuidString)
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let again = try XMPPClient.decodeOutgoingEncryptedMessageXML(try XMPPClient.encryptedMessageXML(to: f.bob, envelope: try await f.a.outgoingEnvelope(account: f.alice, messageID: second.id), id: second.id, requestReceipt: true), from: f.alice)
        expectTrue(try await f.b.receive(account: f.bob, message: again, transport: f.bTransport))
        expectTrue(try await f.bStore.queuedReceipts(accountID: f.bob).isEmpty)
    }

    func testProtectedStateCannotMoveBetweenAccountsOrUseWrongKey() throws {
        let protection = try StateProtection(key: Data(repeating: 7, count: 32))
        let ciphertext = try protection.seal(Data("secret state".utf8), account: "alice@localhost")
        XCTAssertThrowsError(try protection.open(ciphertext, account: "bob@localhost"))
        let wrong = try StateProtection(key: Data(repeating: 8, count: 32))
        XCTAssertThrowsError(try wrong.open(ciphertext, account: "alice@localhost"))
        expectEqual(try protection.open(ciphertext, account: "alice@localhost"), Data("secret state".utf8))
    }

    // MARK: Receive-path cost (S5)

    func testKnownTrustedSenderDecryptsWithoutRetainingEvenWhenPendingTableIsFull() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        // The table's 1,000-row cap: a retain would now throw `invalidValue`, so success proves the write was skipped.
        for index in 0..<1_000 {
            try await f.bStore.retainEncryptedIncoming(accountID: f.bob, sender: "filler@localhost", digest: "filler-\(index)", wire: Data([1]))
        }
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let message = f.message(try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id))
        expectTrue(try await f.b.receive(account: f.bob, message: message, transport: f.bTransport))
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), [outgoing.body])
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).count, 1_000)
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        // The header-only device ID is the engine's device ID in both profiles.
        let (_, state) = try await f.b.load(f.bob)
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let header = try await f.b.localDeviceID(state, profile)
            let engine = try OMEMOEngine(snapshot: unwrap(state.engines[profile.rawValue]))
            expectEqual(header, engine.deviceID)
        }
    }

    func testUnknownSenderDeviceRetainsBeforeTheTargetedFetchAndFetchesOnlyThatDevice() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.aStore.acquireTransportOwnership()
        try await f.bStore.acquireTransportOwnership()
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        try await f.b.initialize(account: f.bob, transport: f.bTransport)
        // Alice knows and trusts Bob; Bob has never refreshed Alice.
        for device in try await f.a.refreshDevices(account: f.alice, peer: f.bob, profile: .modern, transport: f.aTransport).devices where device.active {
            try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
        }
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        let message = f.message(envelope)
        let key = try unwrap(envelope.keys.first { $0.recipientJID == f.bob })
        let digest = try await f.b.ciphertextDigest(message, key: key)
        let log = TransportLog()
        let bStore = f.bStore, bob = f.bob, alice = f.alice
        let counting = CountingTransport(base: f.bTransport, log: log) { _, _ in
            // Retain before the network: the ciphertext is durable before the bundle request leaves.
            let retained = try await bStore.pendingEncryptedIncoming(accountID: bob, sender: alice, digest: digest)
            await log.note(retained == nil ? "not retained" : "retained \(retained!.reason.rawValue)")
        }
        do { _ = try await f.b.receive(account: f.bob, message: message, transport: counting); XCTFail("New device needs a trust decision") }
        catch { expectEqual(error as? OMEMOError, .trustRequired) }
        let aliceID = envelope.senderDeviceID
        expectEqual(await log.calls, [.devices(f.alice, .modern), .bundle(f.alice, aliceID, .modern)])
        expectEqual(await log.notes, ["retained keysPending"])
        let (_, state) = try await f.b.load(f.bob)
        let stored = state.devices.filter { $0.jid == f.alice }
        expectEqual(stored.count, 1)
        let device = try unwrap(stored.first)
        expectEqual(device.deviceID, aliceID)
        expectEqual(device.profile, .modern)
        expectEqual(device.trust, .undecided)
        expectTrue(device.active)
        expectFalse(device.identityChanged)
        // Selection and incompatibility stay with the sending path's full refresh.
        expectNil(state.profiles[f.alice])
        expectNil(state.incompatiblePeers[f.alice])
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
        try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        try await f.b.retryPendingIncoming(account: f.bob, transport: counting)
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), [outgoing.body])
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        // The retry found the device known and approved: no further lookups (only our own prekey bundle is republished).
        expectEqual(await log.fetches.count, 2)
    }

    func testChangedIdentityOnAKnownDeviceIsNeverDecryptedAndIsFlaggedByTheNextFullRefresh() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let original = try unwrap(try await f.b.overview(account: f.bob, peer: f.alice).devices.first { $0.jid == f.alice && $0.active })
        expectEqual(original.trust, .accepted)
        let bobDevice = try unwrap(try await f.a.overview(account: f.alice, peer: f.bob).devices.first { $0.jid == f.bob && $0.active })
        // Alice's device ID now answers with a new identity (a reinstall that kept its ID, or an attacker).
        let impostor = try OMEMOEngine(profile: .modern, deviceID: original.deviceID)
        let replacement = try impostor.bundle()
        await f.server.publish(f.alice, XMPPOMEMOBundle(profile: .modern, deviceID: replacement.deviceID, identityKey: replacement.identityKey,
                                                        signedPreKeyID: replacement.signedPreKeyID, signedPreKey: replacement.signedPreKey,
                                                        signedPreKeySignature: replacement.signedPreKeySignature, preKeys: replacement.preKeys))
        let bobBundle = try await f.server.bundle(f.bob, bobDevice.deviceID, .modern)
        let address = DeviceAddress(jid: f.bob, deviceID: bobDevice.deviceID)
        try impostor.trustIdentity(bobBundle.identityKey, for: address, resetSession: false)
        try impostor.establishSession(with: address, bundle: DeviceBundle(deviceID: bobBundle.deviceID, identityKey: bobBundle.identityKey,
                                                                           signedPreKeyID: bobBundle.signedPreKeyID, signedPreKey: bobBundle.signedPreKey,
                                                                           signedPreKeySignature: bobBundle.signedPreKeySignature, preKeys: bobBundle.preKeys))
        let xml = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>Not really Alice</body></content><rpad>padding</rpad><from jid='alice@localhost'/><to jid='bob@localhost'/></envelope>"
        let payload = try PayloadCrypto.seal(Data(xml.utf8), profile: .modern)
        let key = try impostor.encrypt(payload.keyMaterial, to: address)
        let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: original.deviceID,
            keys: [XMPPOMEMOKey(recipientJID: f.bob, deviceID: bobDevice.deviceID, keyExchange: key.isPreKey, data: key.data)],
            iv: nil, payload: payload.payload)
        let message = f.message(envelope, id: "impostor")
        let log = TransportLog()
        do { _ = try await f.b.receive(account: f.bob, message: message, transport: CountingTransport(base: f.bTransport, log: log)); XCTFail("A new identity decrypted under the old approval") }
        catch { expectEqual(error as? OMEMOError, .undecryptable) }
        // The stored record is still the approved one: no refresh on the receive path, and nothing readable stored.
        expectEqual(await log.calls, [])
        let rows = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        expectTrue(rows.allSatisfy { $0.unreadableReason != nil && $0.body.isEmpty })
        expectEqual(rows.map(\.unreadableReason), [.decryptFailed])
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message))
        // The sending path's full refresh flags the new key and resets trust; the old record stays for history.
        let refreshed = try await f.b.refreshDevices(account: f.bob, peer: f.alice, transport: f.bTransport)
        let records = refreshed.devices.filter { $0.jid == f.alice && $0.deviceID == original.deviceID }
        expectEqual(records.count, 2)
        let last = try unwrap(records.last)
        expectEqual(last.identityKey, replacement.identityKey)
        expectEqual(last.trust, .undecided)
        expectTrue(last.identityChanged)
        expectEqual(records.first?.identityKey, original.identityKey)
    }

    func testDecryptFailureAfterSkippedRetentionStillHasADurableDisposition() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let valid = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        var payload = try unwrap(valid.payload)
        payload[payload.startIndex] ^= 0x01
        let tampered = f.message(XMPPOMEMOEnvelope(profile: valid.profile, senderDeviceID: valid.senderDeviceID, keys: valid.keys, iv: valid.iv, payload: payload))
        expectFalse(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: tampered))
        do { _ = try await f.b.receive(account: f.bob, message: tampered, transport: f.bTransport); XCTFail("Tampered payload accepted") }
        catch { expectEqual(error as? OMEMOError, .undecryptable) }
        // No pending row was ever needed: the placeholder is the disposition, so the barrier may be acknowledged.
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: tampered))
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.unreadableReason), [.decryptFailed])
        expectTrue(try await f.b.receive(account: f.bob, message: f.message(valid), transport: f.bTransport))
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).last?.body, outgoing.body)
    }

    func testCommitFailureAfterSkippedRetentionWithholdsTheDisposition() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let message = f.message(try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id))
        _ = try await f.b.overview(account: f.bob, peer: f.alice)
        // Another connection holds the write lock: reads still work (WAL), every write fails after the busy timeout.
        var blocker: OpaquePointer?
        let path = f.directory.appendingPathComponent("bob.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &blocker, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await f.b.receive(account: f.bob, message: message, transport: f.bTransport)
            XCTFail("Commit succeeded under a foreign write lock")
        } catch {
            XCTAssertTrue(error is MessageStoreError, "\(error)")
            XCTAssertNil(error as? OMEMOError)
        }
        sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil)
        sqlite3_close(blocker)
        // Nothing durable: no placeholder, no retained row, so the caller must not acknowledge and tears the stream down.
        let reopenedStore = try f.openStore("bob.sqlite")
        let reopened = OMEMOService(store: reopenedStore, protection: f.protection)
        expectFalse(try await reopened.hasDurableIncomingDisposition(account: f.bob, message: message))
        expectTrue(try await reopenedStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        expectTrue(try await reopenedStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        // The ratchet did not move: redelivery decrypts.
        expectTrue(try await f.b.receive(account: f.bob, message: message, transport: f.bTransport))
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), [outgoing.body])
    }

    func testRefusedCommitAfterSkippedRetentionKeepsTheCiphertextForRetry() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        // A legacy message's reaction reference is the outer origin-id; one the store refuses fails the commit on
        // every redelivery. Without the retained copy that would wedge the archive walk on this entry.
        let oversized = XMPPEncryptedMessage(id: "outer-id", from: f.alice + "/phone", to: f.bob + "/phone",
                                             originID: String(repeating: "o", count: 2_000), envelope: envelope)
        do { _ = try await f.b.receive(account: f.bob, message: oversized, transport: f.bTransport); XCTFail("Store accepted an oversized reference") }
        catch { expectEqual(error as? MessageStoreError, .invalidValue) }
        expectTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: oversized))
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
        expectTrue(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport)
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), [outgoing.body])
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
    }

    func testStateCacheFollowsAnotherServicesRevision() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern, trust: false)
        // Two services on two connections to one database: the app and the notification extension.
        let extensionStore = try f.openStore("bob.sqlite")
        let app = f.b, notificationExtension = OMEMOService(store: extensionStore, protection: f.protection)
        let device = try unwrap(try await app.overview(account: f.bob, peer: f.alice).devices.first { $0.jid == f.alice && $0.active })
        expectEqual(device.trust, .undecided)
        try await notificationExtension.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        expectEqual(try await app.overview(account: f.bob, peer: f.alice).devices.first { $0.id == device.id }?.trust, .accepted)
        try await app.setTrust(account: f.bob, deviceID: device.id, trust: .rejected)
        expectEqual(try await notificationExtension.overview(account: f.bob, peer: f.alice).devices.first { $0.id == device.id }?.trust, .rejected)
        expectEqual(try await app.overview(account: f.bob, peer: f.alice).devices.first { $0.id == device.id }?.trust, .rejected)
    }

    func testStateCacheIsDroppedAfterAFailedCommit() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern, trust: false)
        let device = try unwrap(try await f.b.overview(account: f.bob, peer: f.alice).devices.first { $0.jid == f.alice && $0.active })
        // A conflicting write lands while a refresh is in flight: the refresh's CAS save fails, and what it had
        // built in memory must never be served later, even though the row now carries the revision it aimed at.
        let other = OMEMOService(store: try f.openStore("bob.sqlite"), protection: f.protection)
        let bob = f.bob
        let interleaving = InterleavingTransport(base: f.bTransport, first: OnFirstFetch {
            try await other.setTrust(account: bob, deviceID: device.id, trust: .rejected)
        })
        expectNotNil(await f.b.cachedStateRevision(f.bob))
        do { _ = try await f.b.refreshDevices(account: f.bob, peer: f.alice, profile: .modern, transport: interleaving); XCTFail("Stale CAS write succeeded") }
        catch { expectEqual(error as? MessageStoreError, .invalidTransition) }
        // The failed save dropped the cache outright; the next load decodes the row the other service wrote.
        expectNil(await f.b.cachedStateRevision(f.bob))
        expectEqual(try await f.b.overview(account: f.bob, peer: f.alice).devices.first { $0.id == device.id }?.trust, .rejected)
        // A write attempted on a closed store (it fails before any save) leaves the durable state as it was.
        try await f.bStore.close()
        do { try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted); XCTFail("Closed store accepted a write") } catch {}
        let fresh = OMEMOService(store: try f.openStore("bob.sqlite"), protection: f.protection)
        expectEqual(try await fresh.overview(account: f.bob, peer: f.alice).devices.first { $0.id == device.id }?.trust, .rejected)
    }

    func testRetryPendingSkipsRowsWhoseDeviceIsStillUntrusted() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern, trust: false)
        for device in try await f.a.overview(account: f.alice, peer: f.bob).devices where device.active {
            try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
        }
        var bodies: [String] = []
        for text in ["First while undecided", "Second while undecided"] {
            let outgoing = try await f.queue(text)
            try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
            let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
            do { _ = try await f.b.receive(account: f.bob, message: f.message(envelope, id: outgoing.id), transport: f.bTransport); XCTFail("Trust undecided") }
            catch { expectEqual(error as? OMEMOError, .trustRequired) }
            bodies.append(text)
        }
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending, .trustPending])
        let log = TransportLog()
        // Nothing to try: the rows are skipped, so the retry neither works nor reports their known trust failure.
        try await f.b.retryPendingIncoming(account: f.bob, transport: CountingTransport(base: f.bTransport, log: log))
        expectEqual(await log.calls, [])
        expectTrue(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).count, 2)
        for device in try await f.b.overview(account: f.bob, peer: f.alice).devices where device.active && device.jid == f.alice {
            try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        }
        try await f.b.retryPendingIncoming(account: f.bob, transport: CountingTransport(base: f.bTransport, log: log))
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), bodies)
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
        expectEqual(await log.fetches, [])
    }

    func testKeysPendingRowIsRetriedAfterTrustOnceItsDeviceBecameKnownElsewhere() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.aStore.acquireTransportOwnership()
        try await f.bStore.acquireTransportOwnership()
        try await f.a.initialize(account: f.alice, transport: f.aTransport)
        try await f.b.initialize(account: f.bob, transport: f.bTransport)
        for device in try await f.a.refreshDevices(account: f.alice, peer: f.bob, profile: .modern, transport: f.aTransport).devices where device.active {
            try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
        }
        let outgoing = try await f.queue()
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let message = f.message(try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id))
        // The key lookup fails (offline): the ciphertext waits for keys.
        do { _ = try await f.b.receive(account: f.bob, message: message, transport: OfflineTransport()); XCTFail("Keys were unavailable") } catch {}
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.keysPending])
        // The sending path's full refresh (or encryption details) adds Alice's device, undecided.
        _ = try await f.b.refreshDevices(account: f.bob, peer: f.alice, profile: .modern, transport: f.bTransport)
        // The connection retry skips the row without decrypting, but it now waits for a trust decision.
        let log = TransportLog()
        try await f.b.retryPendingIncoming(account: f.bob, transport: CountingTransport(base: f.bTransport, log: log))
        expectEqual(await log.calls, [])
        expectEqual(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
        expectTrue(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        // Accepting the device retries trust-pending rows only (as the app does), and that finds this one.
        for device in try await f.b.overview(account: f.bob, peer: f.alice).devices where device.jid == f.alice && device.active {
            try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        }
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport, reasons: [.trustPending])
        expectEqual(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), [outgoing.body])
        expectTrue(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).isEmpty)
    }

    func testPendingConversationsCountsWithoutDecodingWires() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        let room = "room@conference.localhost", carol = "carol@localhost"
        let incoming = #"{"from":"alice@localhost/phone","provenance":"receivedCarbon","envelope":{},"sentAt":0}"#
        let ownSend = #"{"from":"bob@localhost/other","to":"carol@localhost/tablet","provenance":"sentCarbon","envelope":{},"sentAt":0}"#
        let group = #"{"message":{"room":"room@conference.localhost","sender":"carol@localhost"},"sentAt":0}"#
        // Neither a room envelope nor a direct one with an addressable context: ignored, never counted or thrown.
        let forged = #"{"message":{"room":"other@conference.localhost","sender":"mallory@localhost"},"sentAt":0}"#
        try await f.bStore.retainEncryptedIncoming(accountID: f.bob, sender: f.alice, digest: "1", wire: Data(incoming.utf8))
        try await f.bStore.retainEncryptedIncoming(accountID: f.bob, sender: f.bob, digest: "2", wire: Data(ownSend.utf8), reason: .keysPending)
        try await f.bStore.retainEncryptedIncoming(accountID: f.bob, sender: carol, digest: "3", wire: Data(group.utf8))
        try await f.bStore.retainEncryptedIncoming(accountID: f.bob, sender: "x@localhost", digest: "4", wire: Data([1]))
        try await f.bStore.retainEncryptedIncoming(accountID: f.bob, sender: carol, digest: "5", wire: Data(forged.utf8))
        expectEqual(try await f.b.pendingConversations(account: f.bob), [f.alice: 1, carol: 1, room: 1])
    }
}
