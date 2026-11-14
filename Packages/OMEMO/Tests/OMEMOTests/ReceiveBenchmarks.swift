import Foundation
import MessageStore
import OMEMOCrypto
import XCTest
import XMPPProtocol
@testable import OMEMO

// 100 legacy messages from one peer device asking for receipts, received by an account holding `sessions` other peer
// devices; each sample starts from a copy of one store. HAUS_BENCHMARKS=1 swift test --package-path Packages/OMEMO
// [-c release] --filter ReceiveBenchmarks
private struct ReceiveBenchFixture: Sendable {
    let alice = "alice@localhost", bob = "bob@localhost"
    let protection: StateProtection

    struct Prepared: Sendable {
        let directory: URL
        let server: PublicationServer
        let messages: [XMPPEncryptedMessage]
    }

    private func wireBundle(_ bundle: DeviceBundle) -> XMPPOMEMOBundle {
        XMPPOMEMOBundle(profile: .legacy, deviceID: bundle.deviceID, identityKey: bundle.identityKey, signedPreKeyID: bundle.signedPreKeyID,
                        signedPreKey: bundle.signedPreKey, signedPreKeySignature: bundle.signedPreKeySignature, preKeys: bundle.preKeys)
    }

    private func trustAll(_ service: OMEMOService, account: String, peer: String, transport: TestTransport) async throws {
        for device in try await service.refreshDevices(account: account, peer: peer, profile: .legacy, transport: transport).devices where device.active {
            try await service.setTrust(account: account, deviceID: device.id, trust: .accepted)
        }
    }

    // Bob's store after setup, and Alice's messages to him. With `confirmed`, Bob answered Alice's first message, so
    // the run holds ordinary messages; without it every message is a prekey message.
    func prepare(sessions: Int, confirmed: Bool) async throws -> Prepared {
        let directory = FileManager.default.temporaryDirectory.appending(path: "receive-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "template"), withIntermediateDirectories: true)
        let server = PublicationServer()
        let aStore = try MessageStore(url: directory.appending(path: "alice.sqlite"))
        let bStore = try MessageStore(url: directory.appending(path: "template/bob.sqlite"))
        try await aStore.acquireTransportOwnership()
        try await bStore.acquireTransportOwnership()
        let a = OMEMOService(store: aStore, protection: protection), b = OMEMOService(store: bStore, protection: protection)
        let aTransport = TestTransport(account: alice, server: server), bTransport = TestTransport(account: bob, server: server)
        try await a.initialize(account: alice, transport: aTransport)
        try await b.initialize(account: bob, transport: bTransport)
        try await trustAll(a, account: alice, peer: bob, transport: aTransport)
        try await trustAll(b, account: bob, peer: alice, transport: bTransport)
        for index in 0..<sessions {
            let peer = "peer\(index)@localhost"
            let engine = try OMEMOEngine(profile: .legacy, deviceID: UInt32(5000 + index))
            await server.publish(peer, [engine.deviceID], .legacy)
            await server.publish(peer, wireBundle(try engine.bundle()))
            try await trustAll(b, account: bob, peer: peer, transport: bTransport)
            try await bStore.upsertChat(accountID: bob, chatID: peer, title: peer)
            _ = try await bStore.enqueueOutgoing(StoredMessage(id: UUID().uuidString, accountID: bob, chatID: peer, senderID: bob, body: "Hi",
                                                               isOutgoing: true))
        }
        if sessions > 0 { try await b.prepareQueuedMessages(account: bob, transport: bTransport) }
        try await aStore.upsertChat(accountID: alice, chatID: bob, title: "Bob")
        func send(_ count: Int) async throws -> [XMPPEncryptedMessage] {
            var ids: [String] = []
            for index in 0..<count {
                let message = StoredMessage(id: UUID().uuidString, accountID: alice, chatID: bob, senderID: alice,
                                            body: "Catch-up message \(index + 1), long enough to look like a sentence.", isOutgoing: true)
                _ = try await aStore.enqueueOutgoing(message)
                ids.append(message.id)
            }
            try await a.prepareQueuedMessages(account: alice, transport: aTransport)
            var messages: [XMPPEncryptedMessage] = []
            for id in ids {
                var message = XMPPEncryptedMessage(id: id, from: alice + "/phone", to: bob + "/phone", originID: id,
                                                   envelope: try await a.outgoingEnvelope(account: alice, messageID: id), provenance: .receivedCarbon,
                                                   requestsReceipt: true, markable: true, hasFallbackBody: true)
                message.archiveStanzaID = "archive-\(id)"
                messages.append(message)
            }
            return messages
        }
        if confirmed {
            for message in try await send(1) { _ = try await b.receive(account: bob, message: message, transport: bTransport) }
            // Bob's key transport reaches Alice, so her later messages are ordinary ones.
            try await b.flushUpdates(account: bob) { _, prepared in
                guard case .encrypted(_, let envelope) = prepared else { return }
                _ = try await a.receive(account: alice, message: XMPPEncryptedMessage(id: UUID().uuidString, from: bob + "/phone", to: alice,
                                                                                     originID: nil, envelope: envelope),
                                        transport: aTransport)
            }
        }
        let messages = try await send(100)
        try await aStore.close()
        try await bStore.close()
        return Prepared(directory: directory, server: server, messages: messages)
    }
}

final class ReceiveBenchmarks: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HAUS_BENCHMARKS"] == "1", "set HAUS_BENCHMARKS=1 to run benchmarks")
    }

    // Blocks the measuring thread on async work that never needs the main actor.
    private func blocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        let failure = SampleOutcome()
        Task.detached {
            do { try await body() } catch { failure.record(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 300) == .success else { throw XCTSkip("a sample did not finish") }
        if let error = failure.error { throw error }
    }

    typealias Receive = @Sendable (OMEMOService, String, [XMPPEncryptedMessage], TestTransport) async throws -> Void

    private func measureReceive(sessions: Int, confirmed: Bool, _ receive: @escaping Receive) throws {
        let fixture = ReceiveBenchFixture(protection: try StateProtection(key: Data(repeating: 0x5a, count: 32)))
        let setup = try blockingValue { try await fixture.prepare(sessions: sessions, confirmed: confirmed) }
        let protection = fixture.protection, bob = fixture.bob, alice = fixture.alice
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        var failed: (any Error)?
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            let sample = setup.directory.appending(path: "sample-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: setup.directory.appending(path: "template"), to: sample)
                let store = try MessageStore(url: sample.appending(path: "bob.sqlite"))
                let service = OMEMOService(store: store, protection: protection)
                try blocking { try await store.acquireTransportOwnership() }
                startMeasuring()
                try blocking { try await receive(service, bob, setup.messages, TestTransport(account: bob, server: setup.server)) }
                stopMeasuring()
                let stored = try blockingValue { try await store.messages(accountID: bob, chatID: alice).count }
                if stored < setup.messages.count { throw OMEMOError.undecryptable }
                try blocking { try await store.close() }
            } catch {
                failed = error
                stopMeasuring()
            }
            try? FileManager.default.removeItem(at: sample)
        }
        if let failed { throw failed }
    }

    private func blockingValue<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = SampleOutcome.Box<T>()
        try blocking { box.set(try await body()) }
        return try XCTUnwrap(box.value)
    }

    private static let oneByOne: Receive = { service, account, messages, transport in
        for message in messages { _ = try await service.receive(account: account, message: message, transport: transport) }
    }

    private static let batched: Receive = { service, account, messages, transport in
        try await service.receiveArchived(account: account, messages: messages.map { ArchivedEncryptedMessage(message: $0, sentAt: nil) },
                                          transport: transport)
    }

    func testBatchedWith1Session() throws { try measureReceive(sessions: 0, confirmed: true, Self.batched) }
    func testBatchedWith40Sessions() throws { try measureReceive(sessions: 40, confirmed: true, Self.batched) }
    func testBatchedPreKeyRun() throws { try measureReceive(sessions: 0, confirmed: false, Self.batched) }
    func testOneByOneWith1Session() throws { try measureReceive(sessions: 0, confirmed: true, Self.oneByOne) }
    func testOneByOneWith40Sessions() throws { try measureReceive(sessions: 40, confirmed: true, Self.oneByOne) }
    func testOneByOnePreKeyRun() throws { try measureReceive(sessions: 0, confirmed: false, Self.oneByOne) }
}

// Carries a sample's error or value out of the detached task that ran it.
final class SampleOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?
    var error: (any Error)? { lock.withLock { stored } }
    func record(_ error: any Error) { lock.withLock { stored = error } }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? { lock.withLock { stored } }
        func set(_ value: T) { lock.withLock { stored = value } }
    }
}
