import Foundation
import Testing
import MessageStore
@testable import XMPPProtocol
@testable import MessagingCore

/// Every test starts from a first sync that already happened: checkpoint `n9`, backfill cursor `n1` (incomplete).
struct BackfillTests {
    private let account = "alice@localhost"
    private let room = "test@rooms.localhost"
    private enum Failure: Error { case storage }

    private func fixture(archive: String? = nil, seedCheckpoint: Bool = true, seedCursor: (String, Bool)? = ("n1", false),
                         _ body: (MessageStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "backfill-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        let archiveID = archive ?? account
        if seedCheckpoint { _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: archiveID, expectedRevision: nil, cursor: "n9") }
        if let (oldest, complete) = seedCursor {
            _ = try await store.saveArchiveBackfillCursor(accountID: account, archiveID: archiveID, expectedRevision: nil, oldestID: oldest, complete: complete)
        }
        do { try await body(store) }
        catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func page(_ ids: [String], sequence: UInt64, complete: Bool) -> XMPPArchivePage {
        .init(messages: ids.map { .init(archiveID: $0, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil) },
              complete: complete, firstID: ids.first, lastID: ids.last, handledTokens: [.init(session: UUID(), sequence: sequence)])
    }

    private func operations(trace: BackfillTrace,
                            fetch: @escaping @Sendable (XMPPArchiveBound, String?) async throws -> XMPPArchivePage,
                            refresh: (@Sendable (String) async throws -> Void)? = nil,
                            process: (@Sendable (XMPPArchiveMessage) async throws -> Void)? = nil,
                            acknowledge: (@Sendable ([XMPPInboundToken]) async throws -> Void)? = nil,
                            progress: (@Sendable (ArchiveSyncProgress) async -> Void)? = nil) -> ArchiveSyncOperations {
        ArchiveSyncOperations(
            knownRooms: { Issue.record("backfill never lists rooms"); return [] },
            refreshRoom: { room in
                await trace.record("refresh:\(room)")
                try await refresh?(room)
            },
            fetchPage: { bound, archive in
                await trace.record("fetch:\(describe(bound))")
                return try await fetch(bound, archive)
            },
            process: { archived in
                await trace.record("durable:\(archived.archiveID)")
                try await process?(archived)
            },
            acknowledge: { tokens in
                try await acknowledge?(tokens)
                await trace.record("ack:" + tokens.map { String($0.sequence) }.joined(separator: ","))
            },
            disconnect: { await trace.record("disconnect") },
            progress: { await progress?($0) })
    }

    private func cursor(_ store: MessageStore, _ archive: String? = nil) async throws -> ArchiveBackfillCursor? {
        try await store.archiveBackfillCursor(accountID: account, archiveID: archive ?? account)
    }

    @Test func backfillPagesBackwardsCommittingEachPageBeforeTheCursorMoves() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let progress = BackfillProgressLog()
            let ops = operations(trace: trace, fetch: { bound, archive in
                #expect(archive == nil)
                switch bound {
                case .before("n1"): return page(["x1", "x2", "x3"], sequence: 1, complete: false)
                case .before("x1"): return page(["w1"], sequence: 2, complete: true)
                default: Issue.record("unexpected \(bound)"); throw Failure.storage
                }
            }, acknowledge: { tokens async throws in
                // The cursor names the page's oldest entry before its tokens are released.
                let expected = tokens.first?.sequence == 1 ? "x1" : "w1"
                #expect(try await store.archiveBackfillCursor(accountID: account, archiveID: account)?.oldestID == expected)
            }, progress: { await progress.append($0) })
            let outcome = try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops)
            #expect(outcome == .complete)
            let final = try #require(try await cursor(store))
            #expect(final.oldestID == "w1" && final.complete)
            #expect(await trace.events == ["fetch:before(n1)", "durable:x1", "durable:x2", "durable:x3", "ack:1",
                                           "fetch:before(x1)", "durable:w1", "ack:2"])
            #expect(await progress.values == [.init(archive: nil, pages: 1, messages: 3), .init(archive: nil, pages: 2, messages: 4)])
            // The forward checkpoint is never touched by a backfill.
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "n9")
            // A complete cursor has nothing more to do.
            let again = try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops)
            #expect(again == .nothingToDo)
        }
    }

    @Test func backfillStopsAtTheBudgetOnTheLastCommittedPage() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { bound, _ in
                bound == .before("n1") ? page(["x1", "x2", "x3"], sequence: 1, complete: false) : page(["w1"], sequence: 2, complete: true)
            })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 1, operations: ops) == .budgetExhausted)
            #expect(await trace.events.filter { $0.hasPrefix("fetch") } == ["fetch:before(n1)"])
            #expect(try await cursor(store) == ArchiveBackfillCursor(revision: 2, oldestID: "x1", complete: false))
        }
    }

    @Test func backfillWithoutAForwardCheckpointDoesNothing() async throws {
        try await fixture(seedCheckpoint: false) { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in Issue.record("no fetch without a checkpoint"); throw Failure.storage })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 3, operations: ops) == .nothingToDo)
            #expect(await trace.events.isEmpty)
        }
    }

    @Test func backfillWithACompleteCursorDoesNothing() async throws {
        try await fixture(seedCursor: ("n1", true)) { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in Issue.record("no fetch for a complete cursor"); throw Failure.storage })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 3, operations: ops) == .nothingToDo)
            #expect(await trace.events.isEmpty)
        }
    }

    @Test func backfillOfAnArchiveSyncedBeforeSchemaSixteenDoesNothing() async throws {
        // Checkpoint without a backfill row: that archive was walked forward from its start.
        try await fixture(seedCursor: nil) { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in Issue.record("no fetch for a pre-v16 archive"); throw Failure.storage })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 3, operations: ops) == .nothingToDo)
            #expect(await trace.events.isEmpty)
        }
    }

    @Test func cancellationBetweenPagesLeavesTheCursorAndTheConnection() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { bound, _ in
                bound == .before("n1") ? page(["x1", "x2", "x3"], sequence: 1, complete: false) : page(["w1"], sequence: 2, complete: true)
            }, acknowledge: { _ in withUnsafeCurrentTask { $0?.cancel() } })
            let task = Task { try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops) }
            #expect(try await task.value == .stopped)
            #expect(try await cursor(store)?.oldestID == "x1")
            #expect(await trace.events == ["fetch:before(n1)", "durable:x1", "durable:x2", "durable:x3", "ack:1"])
            #expect(await !trace.events.contains("disconnect"))
        }
    }

    @Test func cancellationInsideAPageDisconnectsWithoutMovingTheCursor() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in page(["x1", "x2", "x3"], sequence: 1, complete: false) },
                                 process: { _ in withUnsafeCurrentTask { $0?.cancel() } })
            let task = Task { try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops) }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await trace.events.last == "disconnect")
            #expect(await !trace.events.contains { $0.hasPrefix("ack") })
            #expect(try await cursor(store) == ArchiveBackfillCursor(revision: 1, oldestID: "n1", complete: false))
        }
    }

    @Test func storageFailureInsideAPageDisconnects() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in page(["x1", "x2"], sequence: 1, complete: false) },
                                 process: { archived in if archived.archiveID == "x2" { throw Failure.storage } })
            await #expect(throws: Failure.self) {
                try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops)
            }
            #expect(await trace.events == ["fetch:before(n1)", "durable:x1", "durable:x2", "disconnect"])
            #expect(try await cursor(store)?.oldestID == "n1")
        }
    }

    @Test func fetchFailureOnTheDirectArchiveDisconnects() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in throw XMPPIQError.malformedResponse })
            await #expect(throws: XMPPIQError.self) {
                try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops)
            }
            #expect(await trace.events == ["fetch:before(n1)", "disconnect"])
            #expect(try await cursor(store)?.oldestID == "n1")
        }
    }

    @Test func roomErrorsEndTheBackfillQuietly() async throws {
        try await fixture(archive: room) { store async throws in
            for error: any Error in [XMPPGroupError.incompleteMembership, XMPPIQError.stanza(condition: "forbidden")] {
                let trace = BackfillTrace()
                let ops = operations(trace: trace, fetch: { bound, archive in
                    #expect(bound == .before("n1") && archive == room)
                    throw error
                })
                #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: room, pageBudget: 5, operations: ops) == .stopped)
                #expect(await trace.events == ["refresh:\(room)", "fetch:before(n1)"])
            }
            #expect(try await cursor(store, room)?.oldestID == "n1")
            // The direct archive has its own (absent) rows: nothing to do there.
            let trace = BackfillTrace()
            let direct = operations(trace: trace, fetch: { _, _ in Issue.record("direct archive has no cursor"); throw Failure.storage })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: direct) == .nothingToDo)
        }
    }

    @Test func roomBackfillRevalidatesMembershipBeforeItsFirstPage() async throws {
        try await fixture(archive: room) { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { bound, _ in
                bound == .before("n1") ? page(["x1", "x2"], sequence: 1, complete: false) : page(["w1"], sequence: 2, complete: true)
            })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: room, pageBudget: 5, operations: ops) == .complete)
            // Once per run, before anything is fetched; later pages reuse that validation.
            #expect(await trace.events == ["refresh:\(room)", "fetch:before(n1)", "durable:x1", "durable:x2", "ack:1",
                                           "fetch:before(x1)", "durable:w1", "ack:2"])

            // A room whose membership can no longer be read is skipped without a fetch or a disconnect.
            _ = try await store.saveArchiveBackfillCursor(accountID: account, archiveID: room, expectedRevision: 3, oldestID: "w1", complete: false)
            for error: any Error in [XMPPGroupError.incompleteMembership, XMPPIQError.stanza(condition: "forbidden")] {
                let refused = BackfillTrace()
                let skip = operations(trace: refused, fetch: { _, _ in Issue.record("no fetch after a refused refresh"); throw Failure.storage },
                                      refresh: { _ in throw error })
                #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: room, pageBudget: 5, operations: skip) == .stopped)
                #expect(await refused.events == ["refresh:\(room)"])
            }
            #expect(try await cursor(store, room) == ArchiveBackfillCursor(revision: 4, oldestID: "w1", complete: false))
        }
    }

    @Test func anExpiredCursorEndsTheHistoryWithoutDisconnecting() async throws {
        // Prosody answers an RSM id it no longer holds with item-not-found (archive expiry removed it and all older).
        for archive in [nil, room] as [String?] {
            try await fixture(archive: archive) { store async throws in
                let trace = BackfillTrace()
                let ops = operations(trace: trace, fetch: { _, _ in throw XMPPIQError.stanza(condition: "item-not-found") })
                #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: archive, pageBudget: 5, operations: ops) == .complete)
                #expect(await !trace.events.contains("disconnect"))
                #expect(await trace.events.filter { $0.hasPrefix("fetch") } == ["fetch:before(n1)"])
                #expect(try await cursor(store, archive) == ArchiveBackfillCursor(revision: 2, oldestID: "n1", complete: true))
                // The next reach-top has nothing to ask for.
                #expect(try await !ArchiveSynchronizer(store: store).hasPendingBackfill(account: account, archive: archive))
                #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: archive, pageBudget: 5, operations: ops) == .nothingToDo)
            }
        }
    }

    @Test func otherQueryRefusalsOnTheDirectArchiveStopWithoutDisconnecting() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in throw XMPPIQError.stanza(condition: "resource-constraint") })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops) == .stopped)
            #expect(await trace.events == ["fetch:before(n1)"])
            #expect(try await cursor(store) == ArchiveBackfillCursor(revision: 1, oldestID: "n1", complete: false))
            #expect(try await ArchiveSynchronizer(store: store).hasPendingBackfill(account: account, archive: nil))
        }
    }

    @Test func aConcurrentArchiveQueryStopsWithoutDisconnecting() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in throw XMPPClientError.invalidConfiguration })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops) == .stopped)
            #expect(await trace.events == ["fetch:before(n1)"])
        }
    }

    @Test func noProgressPageIsMalformed() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in page(["n1"], sequence: 1, complete: false) })
            await #expect(throws: XMPPIQError.malformedResponse) {
                try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops)
            }
            #expect(await trace.events == ["fetch:before(n1)", "durable:n1", "disconnect"])
            #expect(try await cursor(store) == ArchiveBackfillCursor(revision: 1, oldestID: "n1", complete: false))
        }
    }

    @Test func anEmptyCompletePageMarksTheCursorComplete() async throws {
        try await fixture { store async throws in
            let trace = BackfillTrace()
            let ops = operations(trace: trace, fetch: { _, _ in XMPPArchivePage(messages: [], complete: true, firstID: nil, lastID: nil, handledTokens: []) })
            #expect(try await ArchiveSynchronizer(store: store).backfill(account: account, archive: nil, pageBudget: 5, operations: ops) == .complete)
            #expect(try await cursor(store) == ArchiveBackfillCursor(revision: 2, oldestID: "n1", complete: true))
            #expect(await trace.events == ["fetch:before(n1)"])
        }
    }
}

private actor BackfillTrace {
    var events: [String] = []
    func record(_ value: String) { events.append(value) }
}

private actor BackfillProgressLog {
    var values: [ArchiveSyncProgress] = []
    func append(_ value: ArchiveSyncProgress) { values.append(value) }
}
