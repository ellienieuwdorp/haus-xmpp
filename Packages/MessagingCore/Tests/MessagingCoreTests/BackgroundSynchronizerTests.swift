import Foundation
import Testing
import MessageStore
@testable import XMPPProtocol
import Darwin
import SQLite3
@testable import MessagingCore

private actor BackgroundProbe {
    var events: [String] = []
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func record(_ value: String) { events.append(value) }
    func begin() { started = true; waiter?.resume(); waiter = nil }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

struct BackgroundSynchronizerTests {
    @Test func presentationRunsWhileKernelLeaseHeldAndFailureStillReleasesIt() async throws {
        enum PresentationFailure: Error { case cancelledAuthorization }
        let directory = FileManager.default.temporaryDirectory.appending(path: "presentation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "messages.sqlite")
        for shouldFail in [false, true] {
            let store = try MessageStore(url: url)
            try await store.acquireTransportOwnership()
            let present: @Sendable (MessageStore) async throws -> Void = { store in
                #expect(try await store.pendingNotifications(accountID: "alice").candidates.isEmpty)
                let descriptor = Darwin.open(url.resolvingSymlinksInPath().path + ".transport-lock", O_RDWR | O_CLOEXEC)
                #expect(descriptor >= 0)
                guard descriptor >= 0 else { throw PresentationFailure.cancelledAuthorization }
                defer { Darwin.close(descriptor) }
                #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
                #expect(errno == EWOULDBLOCK)
                if shouldFail { throw PresentationFailure.cancelledAuthorization }
            }
            if shouldFail {
                await #expect(throws: PresentationFailure.self) {
                    try await finishBackgroundPresentation(store: store, presentation: present)
                }
            } else {
                try await finishBackgroundPresentation(store: store, presentation: present)
            }
            let nextOwner = try MessageStore(url: url)
            try await nextOwner.acquireTransportOwnership()
            try await nextOwner.close()
        }
        try FileManager.default.removeItem(at: directory)
    }

    @Test func timeoutStopsTransportAndJoinsLateDurableCommit() async throws {
        let probe = BackgroundProbe()
        await #expect(throws: BackgroundSynchronizationError.deadlineExceeded) {
            try await runBackgroundWork(timeBudget: .milliseconds(25), operation: {
                try await Task.sleep(for: .seconds(20))
            }, consume: {
                await probe.begin()
                do { try await Task.sleep(for: .seconds(20)) } catch {}
                // A SQLite commit may already have started when cancellation arrives.
                await probe.record("commit finished")
            }, stop: { await probe.record("transport stopped") })
        }
        await probe.record("lease released")
        let events = await probe.events
        #expect(events.contains("commit finished"))
        #expect(events.contains("transport stopped"))
        #expect(events.last == "lease released")
    }

    @Test func callerCancellationJoinsConsumerBeforeReturning() async throws {
        let probe = BackgroundProbe()
        let task = Task {
            try await runBackgroundWork(timeBudget: .seconds(20), operation: {
                try await Task.sleep(for: .seconds(20))
            }, consume: {
                await probe.begin()
                do { try await Task.sleep(for: .seconds(20)) } catch {}
                await probe.record("consumer joined")
                try Task.checkCancellation()
            }, stop: { await probe.record("transport stopped") })
        }
        await probe.waitForStart()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.events.contains("consumer joined"))
        #expect(await probe.events.contains("transport stopped"))
    }

    @Test func successfulArchiveStopsAndJoinsLiveConsumer() async throws {
        let probe = BackgroundProbe()
        try await runBackgroundWork(timeBudget: .seconds(20), operation: {
            await probe.waitForStart()
        }, consume: {
            await probe.begin()
            do { try await Task.sleep(for: .seconds(20)) } catch {}
            await probe.record("consumer joined")
        }, stop: { await probe.record("transport stopped") })
        #expect(await probe.events.contains("consumer joined"))
        #expect(await probe.events.contains("transport stopped"))
    }

    /// The XEP-0490 pull after catch-up is best effort: a connection lost during it (the consumer sees the disconnect
    /// first) still ends the run successfully once the walk committed; before the walk it fails the run as always.
    @Test func connectionLostAfterCatchUpStillSucceeds() async throws {
        let caughtUp = CatchUpMark()
        try await runBackgroundWork(timeBudget: .seconds(20), operation: {
            await caughtUp.reach()
            try await Task.sleep(for: .seconds(20))   // a slow pull, cut short by the ended connection
        }, consume: {
            try await consumeUntilDisconnect(after: caughtUp) {
                while await !caughtUp.reached { await Task.yield() }
                throw BackgroundSynchronizationError.connectionEnded
            }
        }, stop: {})
        let early = CatchUpMark()
        await #expect(throws: BackgroundSynchronizationError.connectionEnded) {
            try await runBackgroundWork(timeBudget: .seconds(20), operation: {
                try await Task.sleep(for: .seconds(20))
            }, consume: {
                try await consumeUntilDisconnect(after: early) { throw BackgroundSynchronizationError.connectionEnded }
            }, stop: {})
        }
    }

    /// MS-110: a room that never answers, a connection lost during the room walk, or a room page that cannot be
    /// processed, once the own archive committed. The direct message is posted at once and the run ends as a success,
    /// the stalled room cut short soon after the post (the app may be waiting for the lease); with nothing direct to
    /// post, what the push was about is unknown and the run fails with what cut the rooms short, so the extension shows
    /// the fallback.
    @Test(arguments: [RoomTrouble.stalls, .losesConnection, .breaks])
    func aStuckRoomNeverHidesCommittedDirectMessages(_ trouble: RoomTrouble) async throws {
        for direct in [true, false] {
            try await withStore { store in
                let run = try await CatchUpFixture(store: store, ownMessages: direct ? 1 : 0, roomMessage: false, trouble: trouble)
                let clock = ContinuousClock(), start = clock.now
                if direct {
                    try await run.run(budget: .seconds(10), roomsAfterPost: .milliseconds(300))
                    #expect(clock.now - start < .seconds(3))
                    #expect(await run.posting.added.map(\.body) == ["Direct"])
                    #expect(run.progress.isCommitted && run.progress.report.posted == 1)
                    #expect(try #require(run.progress.report.firstPostMilliseconds) < 2_000)
                } else {
                    let expected: any Error = switch trouble {
                    case .stalls: BackgroundSynchronizationError.deadlineExceeded
                    case .losesConnection: BackgroundSynchronizationError.connectionEnded
                    case .breaks: RoomTrouble.Unreadable.page
                    }
                    let error = await #expect(throws: (any Error).self) { try await run.run(budget: .seconds(2)) }
                    #expect(error.map(NotificationFallbackReason.init) == NotificationFallbackReason(expected))
                    #expect(await run.posting.added.isEmpty)
                    #expect(!run.progress.isCommitted)
                }
            }
        }
    }

    /// The early presentation claims what it posted, so the final one adds only what the rooms brought, after a second
    /// read-state pull, and the run plays one sound.
    @Test func roomMessagesFollowTheDirectOnesWithoutRepeatingThem() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 1, roomMessage: true, trouble: nil)
            try await run.run(budget: .seconds(5))
            let added = await run.posting.added
            #expect(added.map(\.body) == ["Direct", "Room"])
            #expect(added.map(\.playsSound) == [true, false])
            #expect(await run.trace.events == ["pull", "post", "room", "pull", "post"])
            #expect(run.progress.report.posted == 2 && run.progress.report.claimed == 2)
        }
    }

    /// The early presentation's last add (the one with the sound) fails: the final presentation posts both again and
    /// plays the run's one sound, and the report counts every add that completed.
    @Test func aDirectPresentationThatFailsPartWayLeavesTheSoundToTheFinalOne() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 2, roomMessage: false, trouble: nil)
            await run.posting.failOnce(at: 1)
            try await run.run(budget: .seconds(5))
            let added = await run.posting.added
            #expect(added.map(\.body) == ["Direct", "Direct", "Direct 2"])
            #expect(added.map(\.playsSound) == [false, false, true])
            #expect(run.progress.isCommitted && run.progress.report.posted == added.count)
        }
    }

    /// The deadline cancels the early presentation while the system is still adding its sound-carrying request: that add
    /// may still land, so the final presentation posts the message again without a sound. The run plays one sound.
    @Test func aDeadlineDuringTheDirectPresentationNeverPlaysASecondSound() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 1, roomMessage: false, trouble: nil)
            await run.posting.delayFirstAdd(by: .milliseconds(1_500))
            try await run.run(budget: .seconds(1))
            while await run.posting.added.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
            let added = await run.posting.added
            #expect(added.map(\.body) == ["Direct", "Direct"])
            #expect(added.filter(\.playsSound).count == 1)
            #expect(run.progress.isCommitted)
        }
    }

    /// A push that arrives while the rooms are walked, after the direct message was posted, joins the run (its message
    /// comes in over the same connection) instead of queueing a second full run that would hold the lease again. Until
    /// the final presentation commits, an expiring request is not settled: its message may not be posted yet.
    @Test func aPushDuringTheRoomWalkJoinsTheRunThatPostedEarly() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 1, roomMessage: false, trouble: .stalls)
            let coordinator = NotificationRunCoordinator { progress in
                do {
                    try await run.run(budget: .seconds(2), roomsAfterPost: .seconds(1), progress: progress)
                    return .settled(progress.report)
                } catch {
                    return progress.isCommitted ? .settled(progress.report) : .fallback(NotificationFallbackReason(error))
                }
            }
            let first = Task { await coordinator.deliver(ticket: UUID()) }
            while await run.posting.added.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            let second = Task { await coordinator.deliver(ticket: UUID()) }
            let expiring = UUID()
            let third = Task { await coordinator.deliver(ticket: expiring) }
            try await Task.sleep(for: .milliseconds(50))
            #expect(coordinator.activeRuns == 1)
            #expect(coordinator.expire(ticket: expiring) == .fallback(.expired))
            for delivery in [first, second] { #expect(await delivery.value.suppressesRemoteAlert) }
            _ = await third.value
            #expect(await run.posting.added.map(\.body) == ["Direct"])
        }
    }

    @Test func readSyncPullNeverOutlastsTheBudget() {
        let now = ContinuousClock.now
        #expect(readSyncTimeout(until: now + .seconds(20), now: now) == .seconds(5))
        #expect(readSyncTimeout(until: now + .seconds(3), now: now) == .seconds(2))
        #expect(readSyncTimeout(until: now + .milliseconds(1_200), now: now) == nil)
        #expect(readSyncTimeout(until: now - .seconds(1), now: now) == nil)
    }

    @Test func backgroundSessionsLookAwaySinceTheAppWasLastInFront() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(BackgroundSession.availability(sharesLastSeen: true, leftForeground: now - 600, now: now) == .away(since: now - 600))
        // A clock that moved backwards: away since now, never since the future.
        #expect(BackgroundSession.availability(sharesLastSeen: true, leftForeground: now + 60, now: now) == .away(since: now))
        // Never recorded: no timestamp rather than the time of this run, which would change (and be announced) every run.
        #expect(BackgroundSession.availability(sharesLastSeen: true, leftForeground: nil, now: now) == .away(since: nil))
        // An account that does not share last seen is still away, without the time.
        #expect(BackgroundSession.availability(sharesLastSeen: false, leftForeground: now - 600, now: now) == .away(since: nil))
    }

    @Test func refusesBusyStoreAndNeverCreatesMissingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "background-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: url)
        let account = BackgroundAccount(route: .fixed(XMPPEndpoint(host: "localhost", port: 5223, security: .directTLS)), domain: "localhost", username: "alice", password: "private")
        try await store.acquireTransportOwnership()
        await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
            try await BackgroundSynchronizer().synchronize(databaseURL: url, wrappingKey: Data(repeating: 1, count: 32), account: account)
        }
        try await store.releaseTransportOwnership()
        await #expect(throws: BackgroundSynchronizationError.identityUnavailable) {
            try await BackgroundSynchronizer().synchronize(databaseURL: url, wrappingKey: Data(repeating: 1, count: 32), account: account)
        }
        #expect(try await store.encryptionState(accountID: account.accountID) == nil)
        // Failure cleanup released the extension instance's lease.
        try await store.acquireTransportOwnership()
        #expect(!String(reflecting: account).contains("private"))
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    /// The notification extension's entry point finds a store the previous build wrote: it neither migrates nor
    /// connects, leaves the file byte for byte as it was, and the run falls back to the generic notification.
    @Test func neverMigratesAStoreAnOlderBuildWrote() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "background-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: url)
        try await store.acquireTransportOwnership()
        try await store.saveEncryptionState(accountID: "alice@localhost", expectedRevision: nil, data: Data([0]))
        try await store.close()
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=21", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        let account = BackgroundAccount(route: .fixed(XMPPEndpoint(host: "localhost", port: 5223, security: .directTLS)), domain: "localhost", username: "alice", password: "private")
        do {
            try await BackgroundSynchronizer().synchronize(databaseURL: url, wrappingKey: Data(repeating: 1, count: 32), account: account)
            Issue.record("an older store was synchronized")
        } catch {
            #expect(error as? MessageStoreError == .upgradeRequired(21))
            #expect(NotificationFallbackReason(error) == .upgradePending)
        }
        #expect(try Data(contentsOf: url) == before)
        let wal = (try? Data(contentsOf: URL(filePath: url.path + "-wal"))) ?? Data()
        #expect(wal.isEmpty)
    }
}

enum RoomTrouble: Sendable, CustomStringConvertible {
    /// The room never answers its membership read, as an unreachable MUC component holds an IQ.
    case stalls
    /// The connection is lost during the room walk.
    case losesConnection
    /// The room's page cannot be processed.
    case breaks
    enum Unreadable: Error { case page }
    var description: String {
        switch self { case .stalls: "stalls"; case .losesConnection: "losesConnection"; case .breaks: "breaks" }
    }
}

/// One run through `BackgroundCatchUp` with the real archive walk, store and presenter: only the server is fake. The
/// own archive holds `ownMessages` new direct messages (from two contacts at most); one room follows, which holds one
/// new message when `roomMessage` or `trouble` is `.breaks`, or misbehaves as `trouble` says.
private struct CatchUpFixture {
    let store: MessageStore
    let ownMessages: Int, roomMessage: Bool, trouble: RoomTrouble?
    let posting: TracingPosting
    let progress = NotificationRunProgress()
    let trace = BackgroundProbe()
    private let account = "alice@example.org", room = "room@rooms.example.org"

    init(store: MessageStore, ownMessages: Int, roomMessage: Bool, trouble: RoomTrouble?) async throws {
        self.store = store; self.ownMessages = ownMessages; self.roomMessage = roomMessage; self.trouble = trouble
        posting = TracingPosting(trace: trace)
        // Both archives were walked before, so this run's entries are new rather than history.
        _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "own-0")
        _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: room, expectedRevision: nil, cursor: "room-0")
    }

    private static func page(_ ids: [String]) -> XMPPArchivePage {
        XMPPArchivePage(messages: ids.map { .init(archiveID: $0, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil) },
                        complete: true, firstID: ids.first, lastID: ids.last, handledTokens: [])
    }

    /// `progress` replaces the fixture's own (a coordinator's run).
    func run(budget: Duration, roomsAfterPost: Duration = .seconds(5), progress: NotificationRunProgress? = nil) async throws {
        let (store, account, room, trace, trouble) = (store, account, room, trace, trouble)
        let (ownMessages, roomMessage, progress, posting) = (ownMessages, roomMessage, progress ?? self.progress, posting)
        let operationsFor: @Sendable (@escaping @Sendable (ArchiveSyncProgress) async -> Void,
                                      @escaping @Sendable (Bool, Int) async throws -> Void) -> ArchiveSyncOperations = { walkProgress, walked in
            ArchiveSyncOperations(
                knownRooms: { [room] },
                refreshRoom: { _ in
                    switch trouble {
                    case .stalls: try await Task.sleep(for: .seconds(60))
                    case .losesConnection: throw XMPPClientError.connectionClosed
                    case .breaks, nil: break
                    }
                },
                fetchPage: { _, selected in
                    selected == nil ? Self.page((0..<ownMessages).map { "own-\($0 + 1)" })
                        : Self.page(roomMessage || trouble == .breaks ? ["room-1"] : [])
                },
                process: { archived in
                    // What decrypting the entry commits: the message and its notification candidate.
                    switch archived.archiveID {
                    case "room-1":
                        if trouble == .breaks { throw RoomTrouble.Unreadable.page }
                        await trace.record("room")
                        try await receive(store, chat: room, body: "Room", at: 2_000)
                    case "own-1": try await receive(store, chat: "bob@example.org", body: "Direct", at: 1_000)
                    default: try await receive(store, chat: "carol@example.org", body: "Direct 2", at: 1_001)
                    }
                },
                acknowledge: { _ in }, disconnect: {}, progress: walkProgress, ownArchiveWalked: walked)
        }
        var catchUp = BackgroundCatchUp(
            connect: {}, sessionDuties: { _ in },
            walk: { walkProgress, walked in
                try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operationsFor(walkProgress, walked))
            },
            pull: { _ in await trace.record("pull") },
            consume: { try await Task.sleep(for: .seconds(60)) },
            stop: {}
        )
        catchUp.roomsAfterPost = roomsAfterPost
        try await catchUp.run(store: store, timeBudget: budget, deadline: .now + budget, progress: progress, presentation: { store, stage in
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: progress, stage: stage)
        })
    }
}

/// `FakePosting` that also notes each add in the run's trace, and can reject one add once.
private actor TracingPosting: NotificationPosting {
    enum Failure: Error { case rejected }
    let trace: BackgroundProbe
    private(set) var added: [PlannedNotification] = []
    private var failingAt: Int?, firstDelay: Duration?
    init(trace: BackgroundProbe) { self.trace = trace }
    func failOnce(at index: Int) { failingAt = index }
    /// The first add takes `delay` and, like the system's, is not stopped by cancellation.
    func delayFirstAdd(by delay: Duration) { firstDelay = delay }
    func add(_ request: PlannedNotification) async throws {
        if failingAt == added.count { failingAt = nil; throw Failure.rejected }
        if let delay = firstDelay {
            firstDelay = nil
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() } }
        }
        added.append(request); await trace.record("post")
    }
    func deliveredNotifications() async -> [DeliveredNotification] { [] }
    func removeDelivered(identifiers: [String]) async {}
}
