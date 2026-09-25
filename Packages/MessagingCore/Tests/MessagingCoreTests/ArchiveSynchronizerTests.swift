import Foundation
import Testing
import MessageStore
@testable import XMPPProtocol
@testable import MessagingCore

struct ArchiveSynchronizerTests {
    private let account = "alice@localhost"
    private let room = "test@rooms.localhost"
    private enum Failure: Error { case refused, undurable, acknowledgement }

    private func fixture(_ body: (MessageStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "archive-sync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do { try await body(store) }
        catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func page(_ id: String, sequence: UInt64 = 1, complete: Bool = true) -> XMPPArchivePage {
        .init(messages: [.init(archiveID: id, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil)],
              complete: complete, lastID: id, handledTokens: [.init(session: UUID(), sequence: sequence)])
    }

    @Test func refreshesRoomProvenanceBeforeOwnArchiveAndSeparatesPagedCheckpoints() async throws {
        try await fixture { store async throws in
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: room, expectedRevision: nil, cursor: "older-room")
            let trace = Trace()
            let operations = ArchiveSyncOperations(
                knownRooms: { [room] },
                refreshRoom: { try await trace.refresh($0) },
                fetchPage: { cursor, selectedRoom in
                    await trace.record("fetch:\(selectedRoom ?? account):\(cursor ?? "nil")")
                    if selectedRoom == nil { return page("own", sequence: 1) }
                    #expect(selectedRoom == room)
                    if cursor == "older-room" { return page("room-first", sequence: 2, complete: false) }
                    #expect(cursor == "room-first")
                    return page("room-last", sequence: 3)
                },
                process: { await trace.record("durable:\($0.archiveID)") },
                acknowledge: { tokens async throws in
                    let sequence = try #require(tokens.first).sequence
                    let expected = sequence == 1 ? "own" : sequence == 2 ? "room-first" : "room-last"
                    let archive = sequence == 1 ? account : room
                    #expect(try await store.archiveCheckpoint(accountID: account, archiveID: archive)?.cursor == expected)
                    await trace.record("ack:" + tokens.map { String($0.sequence) }.joined(separator: ","))
                }, disconnect: { await trace.record("disconnect") })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await trace.events == ["refresh:\(room)", "fetch:\(account):nil", "durable:own", "ack:1",
                "fetch:\(room):older-room", "durable:room-first", "ack:2", "fetch:\(room):room-first", "durable:room-last", "ack:3"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "own")
            #expect(try await store.archiveCheckpoint(accountID: "bob@localhost", archiveID: room) == nil)
        }
    }

    @Test func undurableRoomMessageDisconnectsWithoutCheckpointOrAcknowledgement() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in },
                fetchPage: { _, selectedRoom in selectedRoom == nil ? .init(messages: [], complete: true, lastID: nil, handledTokens: []) : page("failed-room") },
                process: { _ in throw Failure.undurable },
                acknowledge: { _ in await trace.record("ack") }, disconnect: { await trace.record("disconnect") })
            await #expect(throws: Failure.self) { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            #expect(await trace.events == ["disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room) == nil)
        }
    }

    @Test func revokedRoomDoesNotBlockDirectArchiveOrAdvanceRoomCheckpoint() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in throw XMPPGroupError.incompleteMembership },
                fetchPage: { _, selected in #expect(selected == nil); await trace.record("fetch-direct"); return page("direct") },
                process: { _ in }, acknowledge: { _ in await trace.record("ack") }, disconnect: { await trace.record("disconnect") })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await trace.events == ["fetch-direct", "ack"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "direct")
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room) == nil)
        }
    }

    @Test func malformedRoomResponseStillDisconnectsBeforeAnyCursor() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in throw XMPPIQError.malformedResponse },
                fetchPage: { _, _ in await trace.record("fetch"); return page("unexpected") },
                process: { _ in }, acknowledge: { _ in await trace.record("ack") }, disconnect: { await trace.record("disconnect") })
            await #expect(throws: XMPPIQError.self) { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            #expect(await trace.events == ["disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account) == nil)
        }
    }

    @Test func rejectedGroupContentIsDurableBeforeCursorAndCannotInventArchiveOwner() async throws {
        try await fixture { store async throws in
            let sync = ArchiveSynchronizer(store: store)
            var rejected = XMPPArchiveMessage(archiveID: "rejected", timestamp: Date(), message: nil, encryptedMessage: nil)
            rejected.rejectedContent = .unverifiableEncryptedGroup
            await #expect(throws: XMPPIQError.self) { _ = try await sync.persistRejectedContent(account: account, archived: rejected) }
            rejected.rejectionArchive = account
            #expect(try await sync.persistRejectedContent(account: account, archived: rejected))
            #expect(try await store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "rejected"))
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account) == nil)
            #expect(try await store.messages(accountID: account, chatID: room).isEmpty)
        }
    }

    @Test func failedAckKeepsAlreadyDurableCheckpointAndDisconnects() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { _, _ in page("durable") }, process: { _ in await trace.record("durable") },
                acknowledge: { _ in throw Failure.acknowledgement }, disconnect: { await trace.record("disconnect") })
            await #expect(throws: Failure.self) { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            #expect(await trace.events == ["durable", "disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "durable")
        }
    }

    @Test func pageTokensAreAcknowledgedInOneBatchAfterTheCursor() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let session = UUID()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { _, _ in
                    .init(messages: ["a", "b", "c"].map { .init(archiveID: $0, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil) },
                          complete: true, lastID: "c", handledTokens: (1...3).map { XMPPInboundToken(session: session, sequence: $0) })
                },
                process: { await trace.record("durable:\($0.archiveID)") },
                acknowledge: { tokens async throws in
                    #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "c")
                    await trace.record("ack:" + tokens.map { String($0.sequence) }.joined(separator: ","))
                }, disconnect: { await trace.record("disconnect") })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await trace.events == ["durable:a", "durable:b", "durable:c", "ack:1,2,3"])
        }
    }

    @Test func pageWithoutTokensDoesNotCallAcknowledge() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { _, _ in
                    .init(messages: [.init(archiveID: "only", timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil)],
                          complete: true, lastID: "only", handledTokens: [])
                },
                process: { await trace.record("durable:\($0.archiveID)") },
                acknowledge: { tokens in await trace.record("ack:" + tokens.map { String($0.sequence) }.joined(separator: ",")) },
                disconnect: { await trace.record("disconnect") })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await trace.events == ["durable:only"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "only")
        }
    }

    @Test func cancellationAfterDurableMessageDoesNotAdvanceCursorOrAck() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in }, fetchPage: { _, _ in page("cancelled") },
                process: { _ in withUnsafeCurrentTask { $0?.cancel() }; await trace.record("durable") },
                acknowledge: { _ in await trace.record("ack") }, disconnect: { await trace.record("disconnect") })
            let task = Task { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await trace.events == ["durable", "disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account) == nil)
        }
    }
}

private actor Trace {
    var events: [String] = []
    func record(_ value: String) { events.append(value) }
    func refresh(_ room: String) throws { events.append("refresh:" + room) }
}
