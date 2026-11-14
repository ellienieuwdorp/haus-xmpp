import Foundation
import MessageStore
import SQLite3
import XCTest
import XMPPProtocol
@testable import OMEMO

// Plain functions, so their arguments may await.
private func equal<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, message, file: file, line: line)
}
private func isTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a, file: file, line: line) }
private func isFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(a, file: file, line: line) }

@MainActor
final class ArchivedReceiveTests: XCTestCase {
    // Alice's next `count` messages as Bob's archive returns them, each asking for a receipt.
    private func send(_ f: ServiceFixture, _ count: Int) async throws -> [XMPPEncryptedMessage] {
        var ids: [String] = []
        for index in 0..<count { ids.append(try await f.queue("Message \(index + 1)").id) }
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        var messages: [XMPPEncryptedMessage] = []
        for id in ids {
            var message = XMPPEncryptedMessage(id: id, from: f.alice + "/phone", to: f.bob + "/phone", originID: id,
                                               envelope: try await f.a.outgoingEnvelope(account: f.alice, messageID: id), provenance: .receivedCarbon,
                                               requestsReceipt: true, markable: true, hasFallbackBody: true)
            message.archiveStanzaID = "archive-\(id)"
            messages.append(message)
        }
        return messages
    }

    private func archived(_ messages: [XMPPEncryptedMessage]) -> [ArchivedEncryptedMessage] {
        messages.map { ArchivedEncryptedMessage(message: $0, sentAt: nil) }
    }

    private func state(_ f: ServiceFixture) async throws -> AccountEncryptionState {
        let loaded = try await f.bStore.encryptionState(accountID: f.bob)
        let row = try XCTUnwrap(loaded)
        return try JSONDecoder().decode(AccountEncryptionState.self, from: f.protection.open(row.data, account: f.bob))
    }

    private func execute(_ store: URL, _ sql: String) {
        var db: OpaquePointer?
        equal(sqlite3_open(store.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        equal(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    // A run of prekey messages commits every message, its receipt, one key transport for the device and the pending
    // bundle publication together; seeing the run again changes nothing.
    func testRunCommitsMessagesReceiptsAndOneKeyTransport() async throws {
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let f = try ServiceFixture()
            try await f.initialize(profile)
            let messages = try await send(f, 4)
            isTrue(messages.allSatisfy { $0.envelope.keys.allSatisfy(\.keyExchange) })
            let stored0 = try await f.bStore.encryptionStateRevision(accountID: f.bob)
            let revision = try XCTUnwrap(stored0)
            try await f.b.receiveArchived(account: f.bob, messages: archived(messages), transport: f.bTransport)
            equal(try await f.bStore.encryptionStateRevision(accountID: f.bob), revision + 1, "one state write for the run")
            let stored = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
            equal(stored.map(\.body), (1...4).map { "Message \($0)" })
            equal(Set(try await f.bStore.queuedReceipts(accountID: f.bob).map(\.targetMessageID)), Set(stored.map(\.id)))
            equal(try await f.bStore.queuedUpdates(accountID: f.bob, kind: .keyTransport).count, 1)
            isTrue(try await state(f).pendingBundlePublications.contains(profile.rawValue))
            try await f.b.receiveArchived(account: f.bob, messages: archived(messages), transport: f.bTransport)
            let reopened = OMEMOService(store: f.bStore, protection: f.protection)
            for message in messages { isFalse(try await reopened.receive(account: f.bob, message: message, transport: f.bTransport)) }
            equal(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).count, 4)
            equal(try await f.bStore.queuedReceipts(accountID: f.bob).count, 4)
            // The key transport answers the session: Alice's next message is an ordinary one Bob reads.
            try await f.b.flushUpdates(account: f.bob) { _, prepared in
                guard case .encrypted(let to, let envelope) = prepared, to == f.alice else { return }
                _ = try await f.a.receive(account: f.alice, message: XMPPEncryptedMessage(id: UUID().uuidString, from: f.bob + "/phone", to: f.alice,
                                                                                         originID: nil, envelope: envelope),
                                          transport: f.aTransport)
            }
            let next = try await send(f, 1)
            isFalse(try XCTUnwrap(next.first?.envelope.keys.first).keyExchange)
            try await f.b.receiveArchived(account: f.bob, messages: archived(next), transport: f.bTransport)
            equal(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).last?.body, "Message 1")
            try await f.cleanup()
        }
    }

    // A tampered copy between two valid messages becomes a placeholder; the engine reverts its step, so the original
    // decrypts right after it in the same run.
    func testTamperedMessageRevertsOnlyItsOwnStep() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let messages = try await send(f, 3)
        let valid = messages[1].envelope
        var payload = try XCTUnwrap(valid.payload)
        payload[payload.startIndex] ^= 0x01
        let envelope = XMPPOMEMOEnvelope(profile: valid.profile, senderDeviceID: valid.senderDeviceID, keys: valid.keys, iv: valid.iv, payload: payload)
        let tampered = XMPPEncryptedMessage(id: "tampered", from: messages[1].from, to: messages[1].to, originID: nil, envelope: envelope,
                                            provenance: .receivedCarbon, hasFallbackBody: true)
        try await f.b.receiveArchived(account: f.bob, messages: archived([messages[0], tampered, messages[1], messages[2]]), transport: f.bTransport)
        let stored = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        equal(stored.map(\.body), ["Message 1", "", "Message 2", "Message 3"])
        equal(stored.map(\.unreadableReason), [nil, .decryptFailed, nil, nil])
    }

    // The run's transaction fails after the state write and before the messages: nothing of it, ratchet steps
    // included, is durable. Each message then takes the single path, which retains it; once the store works again
    // the stored ratchet state still opens every one of them.
    func testFailedRunCommitNeverKeepsARatchetStepWithoutItsMessage() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        let messages = try await send(f, 3)
        let before = try await f.engines(f.bStore, account: f.bob)
        let database = f.directory.appendingPathComponent("bob.sqlite")
        execute(database, "CREATE TRIGGER injected BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'injected'); END")
        try await f.b.receiveArchived(account: f.bob, messages: archived(messages), transport: f.bTransport)
        equal(try await f.engines(f.bStore, account: f.bob), before)
        isTrue(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).isEmpty)
        equal(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).count, 3)
        for message in messages { isTrue(try await f.b.hasDurableIncomingDisposition(account: f.bob, message: message)) }
        execute(database, "DROP TRIGGER injected")
        try await f.b.retryPendingIncoming(account: f.bob, transport: f.bTransport)
        equal(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), ["Message 1", "Message 2", "Message 3"])
    }

    // A run cancelled before its commit leaves the stored state as it was; another process receives the same run from it.
    func testAnUncommittedRunIsReceivedAgainFromTheStoredState() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let messages = try await send(f, 3)
        let before = try await f.engines(f.bStore, account: f.bob)
        let task = Task { try await f.b.receiveArchived(account: f.bob, messages: archived(messages), transport: f.bTransport) }
        task.cancel()
        _ = try? await task.value
        equal(try await f.engines(f.bStore, account: f.bob), before)
        let restarted = OMEMOService(store: f.bStore, protection: f.protection)
        try await restarted.receiveArchived(account: f.bob, messages: archived(messages), transport: f.bTransport)
        equal(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), ["Message 1", "Message 2", "Message 3"])
    }

    // A device Bob has not reviewed sits between two runs: what came before commits first, its message waits for
    // trust, and the messages after it still commit.
    func testUnreviewedDeviceWaitsInArchiveOrder() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        let store = try f.openStore("alice-second.sqlite")
        try await store.acquireTransportOwnership()
        let second = OMEMOService(store: store, protection: f.protection)
        try await second.initialize(account: f.alice, transport: f.aTransport)
        try await f.a.maintainLocalAdvertisement(account: f.alice, profile: .legacy, transport: f.aTransport)
        for service in [second, f.a] {
            let overview = try await service.refreshDevices(account: f.alice, peer: f.bob, profile: .legacy, transport: f.aTransport)
            for device in overview.devices where device.active {
                try await service.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
            }
        }
        try await store.upsertChat(accountID: f.alice, chatID: f.bob, title: "Bob")
        let outgoing = StoredMessage(id: UUID().uuidString, accountID: f.alice, chatID: f.bob, senderID: f.alice, body: "From the second device",
                                     isOutgoing: true)
        _ = try await store.enqueueOutgoing(outgoing)
        try await second.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let unreviewed = XMPPEncryptedMessage(id: outgoing.id, from: f.alice + "/tablet", to: f.bob, originID: outgoing.id,
                                              envelope: try await second.outgoingEnvelope(account: f.alice, messageID: outgoing.id),
                                              provenance: .receivedCarbon, hasFallbackBody: true)
        let first = try await send(f, 2), later = try await send(f, 1)
        try await f.b.receiveArchived(account: f.bob, messages: archived(first + [unreviewed] + later), transport: f.bTransport)
        equal(try await f.bStore.messages(accountID: f.bob, chatID: f.alice).map(\.body), ["Message 1", "Message 2", "Message 1"])
        equal(try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason), [.trustPending])
    }

    // Receipts deferred during a walk stay queued and unclaimable; the pass after it seals all of them behind one
    // device refresh for the chat.
    func testDeferredReceiptsSealTogetherBehindOneRefresh() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        try await f.b.receiveArchived(account: f.bob, messages: archived(try await send(f, 3)), transport: f.bTransport)
        let receipts = Set(try await f.bStore.queuedReceipts(accountID: f.bob).map(\.id))
        equal(receipts.count, 3)
        let deferred = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport, deferringReceipts: true)
        isTrue(deferred.messageIDs.isDisjoint(with: receipts))
        for id in receipts { equal(try await f.bStore.updateWire(accountID: f.bob, updateID: id), nil) }
        let log = TransportLog()
        let prepared = try await f.b.prepareAvailableUpdates(account: f.bob, transport: CountingTransport(base: f.bTransport, log: log))
        isTrue(receipts.isSubset(of: prepared.messageIDs))
        equal(await log.fetches.count, 5, "one refresh: both versions' lists of both accounts and the peer device's bundle")
    }

    // Receipts between messages: our own delivery receipt and a peer's receipt for a message already stored leave the
    // run whole, one state write; our own marker moves the read pointer, so the messages before it commit first and
    // only the message after it counts as unread.
    func testReceiptsInARunKeepArchiveOrder() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.legacy)
        try await f.bStore.upsertChat(accountID: f.bob, chatID: f.alice, title: "Alice")
        _ = try await f.bStore.insertMessage(StoredMessage(id: "sent", accountID: f.bob, chatID: f.alice, senderID: f.bob, body: "Earlier",
                                                           isOutgoing: true, wireID: "sent-wire"))
        let messages = try await send(f, 3)
        let own = XMPPReceipt(id: "own", from: f.bob + "/tablet", to: f.alice, targetID: "elsewhere", kind: .delivered, provenance: .sentCarbon)
        let peer = XMPPReceipt(id: "peer", from: f.alice + "/phone", to: f.bob, targetID: "sent-wire", kind: .delivered)
        let stored = try await f.bStore.encryptionStateRevision(accountID: f.bob)
        let first = try XCTUnwrap(stored)
        try await f.b.receiveArchived(account: f.bob, entries: [.encrypted(archived([messages[0]])[0]), .receipt(own, sentAt: nil),
                                                                .receipt(peer, sentAt: nil), .encrypted(archived([messages[1]])[0])],
                                      transport: f.bTransport)
        equal(try await f.bStore.encryptionStateRevision(accountID: f.bob), first + 1)
        equal(try await f.bStore.events(accountID: f.bob, chatID: f.alice, messageID: "sent").map(\.kind), [.delivered])
        let read = XMPPReceipt(id: "read", from: f.bob + "/tablet", to: f.alice, targetID: messages[1].id, kind: .displayed, provenance: .sentCarbon)
        let third = archived([messages[2]])[0]
        try await f.b.receiveArchived(account: f.bob, entries: [.receipt(read, sentAt: nil), .encrypted(third)], transport: f.bTransport)
        equal(try await f.bStore.encryptionStateRevision(accountID: f.bob), first + 2)
        equal(try await f.bStore.unreadCounts(accountID: f.bob)[f.alice], 1)
    }
}
