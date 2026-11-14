import Foundation
import Testing
import MessageStore
@testable import XMPPProtocol
@testable import MessagingCore

// A forward walk that pages back from the newest entry at the same time: whatever the two chains fetch, entries are
// processed once each in archive order, the cursor moves only over durable entries, a handed page's tokens follow its
// cursor, and held results are acknowledged as they arrive. The scripted archive pages by RSM ID only.
struct ArchiveNewestPagesTests {
    private let account = "alice@localhost"
    private enum Failure: Error { case undurable }

    // RSM over a list: `after` and `before` by ID, `pageSize` per page, one token per result.
    private actor Archive {
        private(set) var entries: [XMPPArchiveMessage]
        private let pageSize: Int
        private let session = UUID()
        private var sequence: UInt64 = 0
        private(set) var asked: [String] = []
        // The archive entry each token carried, and the bound that fetched it.
        private(set) var carried: [UInt64: (id: String, forward: Bool)] = [:]
        var refuse: Set<String> = []
        var contradict = false
        // Appended once the newest page has been answered.
        var arriving: [XMPPArchiveMessage] = []
        // Entries fetched by `before` and not yet processed, at most.
        private(set) var heldPeak = 0
        private var held: Set<String> = []
        private(set) var olderServed = 0

        init(entries: [XMPPArchiveMessage], pageSize: Int) { self.entries = entries; self.pageSize = pageSize }

        func configure(refuse: Set<String> = [], contradict: Bool = false, arriving: [XMPPArchiveMessage] = []) {
            self.refuse = refuse; self.contradict = contradict; self.arriving = arriving
        }

        func page(_ bound: XMPPArchiveBound) throws -> XMPPArchivePage {
            let name = describe(bound)
            asked.append(name)
            if refuse.contains(name) { throw XMPPIQError.stanza(condition: "forbidden") }
            let ids = entries.map(\.archiveID)
            func index(_ id: String) throws -> Int {
                guard let index = ids.firstIndex(of: id) else { throw XMPPIQError.stanza(condition: "item-not-found") }
                return index
            }
            var slice: ArraySlice<XMPPArchiveMessage>
            let complete: Bool
            switch bound {
            case .after(let id):
                let start = try id.map { try index($0) + 1 } ?? 0
                slice = entries[start..<min(start + pageSize, entries.count)]
                complete = slice.endIndex == entries.endIndex
            case .before(let id):
                let end = try id.map { try index($0) } ?? entries.count
                slice = entries[max(0, end - pageSize)..<end]
                complete = slice.startIndex == 0
                if contradict, slice.count > 1 { slice = ArraySlice(slice.reversed()) }
                for entry in slice { held.insert(entry.archiveID) }
                heldPeak = max(heldPeak, held.count)
                if id == nil, !arriving.isEmpty { entries += arriving; arriving = [] }
                olderServed += 1
            case .since:
                throw XMPPIQError.malformedResponse
            }
            let forward = if case .after = bound { true } else { false }
            var tokens: [XMPPInboundToken] = []
            for entry in slice {
                sequence += 1
                tokens.append(.init(session: session, sequence: sequence))
                carried[sequence] = (entry.archiveID, forward)
            }
            return .init(messages: Array(slice), complete: complete || slice.isEmpty, firstID: slice.first?.archiveID,
                         lastID: slice.last?.archiveID, handledTokens: tokens)
        }

        func processed(_ id: String) { held.remove(id) }
        var issued: Int { Int(sequence) }
    }

    private actor Record {
        var processed: [String] = []
        var acknowledged: [UInt64] = []
        var early: [String] = []
        var disconnects = 0
        func process(_ id: String) { processed.append(id) }
        func acknowledge(_ sequences: [UInt64], cursor: Int?, carried: [UInt64: (id: String, forward: Bool)], positions: [String: Int]) {
            acknowledged += sequences
            // A handed page's tokens only once the cursor covers what they carried.
            for sequence in sequences {
                guard let entry = carried[sequence], entry.forward, let at = positions[entry.id] else { continue }
                if at > (cursor ?? -1) { early.append(entry.id) }
            }
        }
        func disconnect() { disconnects += 1 }
    }

    private static func entries(_ count: Int, stamp: (Int) -> TimeInterval = { TimeInterval($0) }) -> [XMPPArchiveMessage] {
        (0..<count).map { XMPPArchiveMessage(archiveID: "own-\($0)", timestamp: Date(timeIntervalSince1970: stamp($0)), message: nil, encryptedMessage: nil) }
    }

    private func fixture(_ body: (MessageStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "archive-newest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do { try await body(store) }
        catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func operations(_ archive: Archive, _ record: Record, store: MessageStore,
                            failAt: String? = nil, olderFirst: Int = 0) async -> ArchiveSyncOperations {
        let positions = Dictionary(uniqueKeysWithValues: (await archive.entries + archive.arriving).enumerated().map { ($1.archiveID, $0) })
        let account = account
        var operations = ArchiveSyncOperations(
            knownRooms: { [] }, refreshRoom: { _ in },
            fetchPage: { bound, _ in
                // Forward pages after the first wait for that many older pages, so the chains meet where the test says.
                if case .after(let id) = bound, id != "own-0", olderFirst > 0 {
                    try await eventually("\(olderFirst) older pages") { await archive.olderServed >= olderFirst }
                }
                return try await archive.page(bound)
            },
            process: { archived in
                if archived.archiveID == failAt { throw Failure.undurable }
                await record.process(archived.archiveID)
                await archive.processed(archived.archiveID)
            },
            acknowledge: { tokens in
                let cursor = try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor
                // Entries arriving after the walk started have positions past the original list.
                let all = Dictionary(uniqueKeysWithValues: (await archive.entries).enumerated().map { ($1.archiveID, $0) })
                await record.acknowledge(tokens.map(\.sequence), cursor: cursor.flatMap { all[$0] ?? positions[$0] },
                                         carried: await archive.carried, positions: all)
            },
            disconnect: { await record.disconnect() }, progress: { _ in })
        operations.prefetchesPages = true
        operations.pagesFromNewest = true
        return operations
    }

    private func walk(_ archive: Archive, from cursor: String, failAt: String? = nil, olderFirst: Int = 0,
                      store: MessageStore) async throws -> (ArchiveSyncOutcome, Record) {
        _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: cursor)
        let record = Record()
        let operations = await operations(archive, record, store: store, failAt: failAt, olderFirst: olderFirst)
        let outcome = try await bounded { try await ArchiveSynchronizer(store: store).synchronize(account: self.account, operations: operations) }
        return (outcome, record)
    }

    // Everything after the cursor once, in order; every token once; none of a handed page's before its cursor.
    private func expectExact(_ archive: Archive, _ record: Record, after cursor: Int, store: MessageStore) async throws {
        let ids = await archive.entries.map(\.archiveID)
        #expect(await record.processed == Array(ids[(cursor + 1)...]))
        #expect(await record.acknowledged.sorted() == Array(1...UInt64(await archive.issued)))
        #expect(await record.early.isEmpty)
        #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == ids.last)
    }

    @Test func aLongGapMeetsThePagesFromTheNewestAndNeedsFewerForwardPages() async throws {
        try await fixture { store in
            let archive = Archive(entries: Self.entries(25), pageSize: 2)
            let (outcome, record) = try await walk(archive, from: "own-0", olderFirst: 4, store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
            #expect(await record.disconnects == 0)
            let asked = await archive.asked
            #expect(asked.first == "after(own-0)")
            // On its own the walk asks 12 pages for these 24 entries; the 4 newest pages hold 8 of them, and the page
            // after them tells the walk nothing was archived since.
            #expect(Array(asked.filter { $0.hasPrefix("before") }.prefix(4)) == ["before(nil)", "before(own-23)", "before(own-21)", "before(own-19)"])
            #expect(asked.filter { $0.hasPrefix("after") }.count <= 9 + 1)
            #expect(asked.contains("after(own-24)"))
        }
    }

    @Test(arguments: [3, 4, 5, 6, 7, 8, 9]) func chainsMeetingOnAnyBoundaryHandEachEntryOnce(_ count: Int) async throws {
        // Page size 2 from entry 0: the forward pages end on even entries, the newest pages on whatever the count makes.
        try await fixture { store in
            let archive = Archive(entries: Self.entries(count), pageSize: 2)
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
        }
    }

    @Test func equalAndBackwardStampsChangeNothing() async throws {
        // A server clock that stood still, then stepped back: the walk pages by ID and never reads a stamp.
        try await fixture { store in
            let stamps: (Int) -> TimeInterval = { $0 < 8 ? 100 : 100 - TimeInterval($0) }
            let archive = Archive(entries: Self.entries(19, stamp: stamps), pageSize: 3)
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
        }
    }

    @Test func entriesArchivedDuringTheWalkFollowTheHeldPages() async throws {
        try await fixture { store in
            let archive = Archive(entries: Self.entries(12), pageSize: 2)
            await archive.configure(arriving: (12..<15).map {
                XMPPArchiveMessage(archiveID: "own-\($0)", timestamp: Date(timeIntervalSince1970: TimeInterval($0)), message: nil, encryptedMessage: nil)
            })
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
            #expect(await record.processed.last == "own-14")
        }
    }

    @Test func aRefusedNewestPageLeavesTheWalkToFinishByItself() async throws {
        try await fixture { store in
            let archive = Archive(entries: Self.entries(11), pageSize: 2)
            await archive.configure(refuse: ["before(nil)"])
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
            #expect(await record.disconnects == 0)
            #expect(await archive.asked.filter { $0.hasPrefix("before") } == ["before(nil)"])
        }
    }

    @Test func aRefusedOlderPageMidWayKeepsWhatWasHeld() async throws {
        try await fixture { store in
            let archive = Archive(entries: Self.entries(21), pageSize: 2)
            await archive.configure(refuse: ["before(own-17)"])
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
        }
    }

    @Test func aRefusedForwardPageKeepsTheConnectionAndAcknowledgesEverythingFetched() async throws {
        try await fixture { store in
            let archive = Archive(entries: Self.entries(21), pageSize: 2)
            await archive.configure(refuse: ["after(own-4)"])
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(!outcome.ownArchiveComplete)
            #expect(await record.disconnects == 0)
            #expect(await record.processed == ["own-1", "own-2", "own-3", "own-4"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "own-4")
            // Nothing stays unacknowledged on the connection it keeps.
            #expect(await record.acknowledged.sorted() == Array(1...UInt64(await archive.issued)))
            #expect(await record.early.isEmpty)
        }
    }

    @Test func aPageThatFailsToCommitDisconnectsWithTheCursorOnTheLastDurablePage() async throws {
        try await fixture { store in
            let archive = Archive(entries: Self.entries(21), pageSize: 2)
            await #expect(throws: Failure.self) { _ = try await self.walk(archive, from: "own-0", failAt: "own-7", store: store) }
            let cursor = try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor
            #expect(cursor == "own-6")
        }
    }

    @Test func aServerThatContradictsItselfLeavesOnlyTheWalksOwnPages() async throws {
        // Older pages in the wrong order: the remainder check refuses them and the walk asks for every page itself.
        try await fixture { store in
            let archive = Archive(entries: Self.entries(15), pageSize: 3)
            await archive.configure(contradict: true)
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
        }
    }

    @Test func heldEntriesStayWithinTheLimit() async throws {
        try await fixture { store in
            let archive = Archive(entries: Self.entries(1_601), pageSize: 50)
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
            #expect(await archive.heldPeak <= ArchivePageSource.heldLimit + 50)
        }
    }

    @Test func aShortGapAsksNothingFromTheNewest() async throws {
        try await fixture { store in
            let archive = Archive(entries: Self.entries(3), pageSize: 2)
            let (outcome, record) = try await walk(archive, from: "own-0", store: store)
            #expect(outcome.isComplete)
            try await expectExact(archive, record, after: 0, store: store)
            #expect(await archive.asked == ["after(own-0)"])
        }
    }
}
