import Foundation
import Testing
import MessageStore
@testable import XMPPProtocol
@testable import MessagingCore

// The next page's query goes out while a page is processed. Messages, then cursor, then tokens stay in page order,
// and a walk that fails cancels and joins the query ahead before the stream closes.
struct ArchivePrefetchTests {
    private let account = "alice@localhost"
    private enum Failure: Error { case undurable }

    private actor Log {
        var events: [String] = []
        func record(_ value: String) { events.append(value) }
        func contains(_ value: String) -> Bool { events.contains(value) }
    }

    private func fixture(_ body: (MessageStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "archive-prefetch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do { try await body(store) }
        catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func page(_ id: String, sequence: UInt64, complete: Bool) -> XMPPArchivePage {
        .init(messages: [.init(archiveID: id, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil)],
              complete: complete, firstID: id, lastID: id, handledTokens: [.init(session: UUID(), sequence: sequence)])
    }

    private func operations(_ log: Log, store: MessageStore, fetch: @escaping @Sendable (XMPPArchiveBound) async throws -> XMPPArchivePage,
                            process: @escaping @Sendable (String) async throws -> Void = { _ in }) -> ArchiveSyncOperations {
        var operations = ArchiveSyncOperations(
            knownRooms: { [] }, refreshRoom: { _ in },
            fetchPage: { bound, _ in
                await log.record("fetch:\(describe(bound))")
                return try await fetch(bound)
            },
            process: { archived in
                try await process(archived.archiveID)
                await log.record("durable:\(archived.archiveID)")
            },
            acknowledge: { tokens in
                let cursor = try await store.archiveCheckpoint(accountID: self.account, archiveID: self.account)?.cursor ?? "none"
                await log.record("ack:\(tokens.map { String($0.sequence) }.joined(separator: ",")) at \(cursor)")
            },
            disconnect: { await log.record("disconnect") }, progress: { _ in })
        operations.prefetchesPages = true
        return operations
    }

    @Test func theNextPageIsAskedWhileThisOneIsProcessed() async throws {
        try await fixture { store in
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "own-1")
            let log = Log()
            let operations = operations(log, store: store, fetch: { bound in
                switch bound {
                case .after("own-1"): page("own-2", sequence: 1, complete: false)
                case .after("own-2"): page("own-3", sequence: 2, complete: true)
                default: throw XMPPIQError.malformedResponse
                }
            }, process: { id in
                // Returns only once the query for the page after this one is out.
                if id == "own-2" { try await eventually("the next query") { await log.contains("fetch:after(own-2)") } }
            })
            let outcome = try await bounded { try await ArchiveSynchronizer(store: store).synchronize(account: self.account, operations: operations) }
            #expect(outcome.isComplete)
            #expect(await log.events == ["fetch:after(own-1)", "fetch:after(own-2)", "durable:own-2", "ack:1 at own-2",
                                         "durable:own-3", "ack:2 at own-3"])
        }
    }

    @Test func noQueryGoesAheadOfTheLastPage() async throws {
        try await fixture { store in
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "own-1")
            let log = Log()
            let operations = operations(log, store: store, fetch: { _ in page("own-2", sequence: 1, complete: true) })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await log.events == ["fetch:after(own-1)", "durable:own-2", "ack:1 at own-2"])
        }
    }

    @Test func aPageThatFailsCancelsAndJoinsTheQueryAheadBeforeTheStreamCloses() async throws {
        try await fixture { store in
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "own-1")
            let log = Log()
            let operations = operations(log, store: store, fetch: { bound in
                guard bound == .after("own-1") else {
                    await untilCancelled()
                    await log.record("ahead cancelled")
                    throw CancellationError()
                }
                return page("own-2", sequence: 1, complete: false)
            }, process: { _ in
                try await eventually("the query ahead") { await log.contains("fetch:after(own-2)") }
                throw Failure.undurable
            })
            await #expect(throws: Failure.self) {
                try await bounded { try await ArchiveSynchronizer(store: store).synchronize(account: self.account, operations: operations) }
            }
            #expect(await log.events == ["fetch:after(own-1)", "fetch:after(own-2)", "ahead cancelled", "disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "own-1")
        }
    }
}
