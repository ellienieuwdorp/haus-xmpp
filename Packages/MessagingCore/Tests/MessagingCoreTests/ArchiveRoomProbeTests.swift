import Foundation
import Testing
import MessageStore
@testable import XMPPProtocol
@testable import MessagingCore

// A room whose newest archive entry is its checkpoint needs neither a membership read nor a page; anything short of
// that proof refreshes and walks the room after the own archive, which classifies any failure.
struct ArchiveRoomProbeTests {
    private let account = "alice@localhost"
    private let room = "quiet@rooms.localhost"
    private let other = "busy@rooms.localhost"
    private enum Failure: Error { case acknowledgement }

    private actor Log {
        var events: [String] = []
        func record(_ value: String) { events.append(value) }
        func contains(_ value: String) -> Bool { events.contains(value) }
        func containsAll(_ values: [String]) -> Bool { values.allSatisfy(events.contains) }
    }

    private func fixture(_ body: (MessageStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "room-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do { try await body(store) }
        catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func page(_ id: String, sequence: UInt64) -> XMPPArchivePage {
        .init(messages: [.init(archiveID: id, timestamp: Date(timeIntervalSince1970: 200), message: nil, encryptedMessage: nil)],
              complete: true, firstID: id, lastID: id, handledTokens: [.init(session: UUID(), sequence: sequence)])
    }

    private let emptyPage = XMPPArchivePage(messages: [], complete: true, firstID: nil, lastID: nil, handledTokens: [])

    private func newest(_ id: String?, sequence: UInt64 = 9) -> XMPPArchiveNewest {
        XMPPArchiveNewest(id: id, handledTokens: id == nil ? [] : [.init(session: UUID(), sequence: sequence)])
    }

    // Own archive and `rooms` all have checkpoints, so every walk is forward.
    private func checkpoints(_ store: MessageStore, rooms: [String: String]) async throws {
        _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "own-1")
        for (room, cursor) in rooms {
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: room, expectedRevision: nil, cursor: cursor,
                                                      stamp: Date(timeIntervalSince1970: 100))
        }
    }

    private func operations(_ log: Log, rooms: [String], newest: @escaping @Sendable (String) async throws -> XMPPArchiveNewest,
                            refresh: @escaping @Sendable (String) async throws -> Void = { _ in },
                            acknowledge: @escaping @Sendable ([XMPPInboundToken]) async throws -> Void = { _ in },
                            fetch: (@Sendable (XMPPArchiveBound, String?) async throws -> XMPPArchivePage)? = nil) -> ArchiveSyncOperations {
        var operations = ArchiveSyncOperations(
            knownRooms: { rooms },
            refreshRoom: { room in await log.record("refresh:\(room)"); try await refresh(room) },
            fetchPage: { bound, room in
                await log.record("fetch:\(room ?? "own"):\(describe(bound))")
                return try await fetch?(bound, room) ?? emptyPage
            },
            process: { await log.record("durable:\($0.archiveID)") },
            acknowledge: { tokens in
                await log.record("ack:" + tokens.map { String($0.sequence) }.joined(separator: ","))
                try await acknowledge(tokens)
            },
            disconnect: { await log.record("disconnect") },
            progress: { _ in })
        operations.newestEntry = { room in
            await log.record("probe:\(room)")
            return try await newest(room)
        }
        return operations
    }

    @Test func aRoomWhoseNewestEntryIsItsCheckpointIsNeitherReadNorWalked() async throws {
        try await fixture { store in
            try await checkpoints(store, rooms: [room: "room-9"])
            let log = Log()
            let outcome = try await ArchiveSynchronizer(store: store).synchronize(
                account: account, operations: operations(log, rooms: [room], newest: { _ in newest("room-9") }))
            #expect(outcome.isComplete)
            #expect(Set(await log.events) == ["probe:\(room)", "ack:9", "fetch:own:after(own-1)"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room)?.cursor == "room-9")
        }
    }

    @Test func aRoomThatMovedIsReadAndWalkedAfterTheOwnArchiveAsBefore() async throws {
        try await fixture { store in
            try await checkpoints(store, rooms: [room: "room-9", other: "busy-3"])
            let log = Log()
            let operations = operations(log, rooms: [other, room], newest: { probed in newest(probed == room ? "room-9" : "busy-4") },
                                        fetch: { bound, selected in
                                            selected == other && bound == .after("busy-3") ? page("busy-4", sequence: 4) : emptyPage
                                        })
            let outcome = try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(outcome.isComplete)
            let events = await log.events
            let walk = try #require(events.firstIndex(of: "refresh:\(other)"))
            // Every probe and the own archive come before the room's read; only the room that moved is read and walked.
            #expect(events[..<walk].contains("fetch:own:after(own-1)"))
            #expect(Array(events[walk...]) == ["refresh:\(other)", "fetch:\(other):after(busy-3)", "durable:busy-4", "ack:4"])
            #expect(!events.contains("refresh:\(room)"))
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: other)?.cursor == "busy-4")
        }
    }

    @Test func aFailedProbeWalksTheRoomSoTheWalkClassifiesTheFailure() async throws {
        try await fixture { store in
            try await checkpoints(store, rooms: [room: "room-9"])
            let log = Log()
            let operations = operations(log, rooms: [room], newest: { _ in throw XMPPIQError.stanza(condition: "forbidden") },
                                        refresh: { _ in throw XMPPGroupError.incompleteMembership })
            let outcome = try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(outcome.unfinishedRooms == [room])
            #expect(await log.contains("refresh:\(room)"))
            #expect(await !log.contains("disconnect"))
        }
    }

    @Test func aRoomNeverWalkedStartsAtItsNewestPageWithoutAProbe() async throws {
        try await fixture { store in
            try await checkpoints(store, rooms: [:])
            let log = Log()
            let operations = operations(log, rooms: [room], newest: { _ in newest("room-1") })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            let events = await log.events
            #expect(!events.contains("probe:\(room)"))
            #expect(events.suffix(2) == ["refresh:\(room)", "fetch:\(room):before(nil)"])
        }
    }

    @Test func anEmptyArchiveUnderACheckpointRecordsOneGapAndFetchesNothing() async throws {
        try await fixture { store in
            try await checkpoints(store, rooms: [room: "room-9"])
            let log = Log()
            let synchronizer = ArchiveSynchronizer(store: store)
            for _ in 0..<2 {
                let outcome = try await synchronizer.synchronize(account: account, operations: operations(log, rooms: [room], newest: { _ in newest(nil) }))
                #expect(outcome.isComplete)
            }
            let gaps = try await store.archiveGaps(accountID: account)
            #expect(gaps.map(\.archiveID) == [room])
            #expect(gaps.first?.since == Date(timeIntervalSince1970: 100))
            #expect(await log.events.allSatisfy { !$0.hasPrefix("refresh:") && !$0.hasPrefix("fetch:\(room)") })
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room)?.cursor == "room-9")
        }
    }

    @Test func probesRunBesideTheOwnArchiveAndProcessNothing() async throws {
        try await fixture { store in
            try await checkpoints(store, rooms: [room: "room-9", other: "busy-3"])
            let log = Log()
            // The own archive's page waits for both probes, so it returns only if they are in flight beside it.
            let operations = operations(log, rooms: [other, room], newest: { probed in newest(probed == room ? "room-9" : "busy-3") },
                                        fetch: { _, selected in
                                            if selected == nil {
                                                try await eventually("both probes") {
                                                    await log.containsAll(["probe:\(self.room)", "probe:\(self.other)"])
                                                }
                                                return page("own-2", sequence: 1)
                                            }
                                            return emptyPage
                                        })
            let outcome = try await bounded { try await ArchiveSynchronizer(store: store).synchronize(account: self.account, operations: operations) }
            #expect(outcome.isComplete)
            #expect(await log.events.filter { $0.hasPrefix("durable:") } == ["durable:own-2"])
        }
    }

    @Test func aProbeAcknowledgementThatFailsDisconnectsWithoutMovingTheRoom() async throws {
        try await fixture { store in
            try await checkpoints(store, rooms: [room: "room-9"])
            let log = Log()
            let operations = operations(log, rooms: [room], newest: { _ in newest("room-9", sequence: 7) },
                                        acknowledge: { tokens in if tokens.map(\.sequence) == [7] { throw Failure.acknowledgement } })
            await #expect(throws: Failure.self) { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            #expect(await log.events.last == "disconnect")
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room)?.cursor == "room-9")
        }
    }
}
