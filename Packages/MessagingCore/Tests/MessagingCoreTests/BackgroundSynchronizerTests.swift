import Foundation
import Testing
import MessageStore
@testable import XMPPProtocol
import Darwin
import SQLite3
@testable import MessagingCore

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
        let probe = BackgroundProbe(), clock = TestClock()
        let work = Task {
            try await runBackgroundWork(timeBudget: .milliseconds(25), clock: clock, operation: {
                await untilCancelled()
                throw CancellationError()
            }, consume: {
                await probe.begin()
                await untilCancelled()
                // A SQLite commit may already have started when cancellation arrives.
                await probe.record("commit finished")
            }, stop: { await probe.record("transport stopped") })
        }
        try await clock.sleepers(1)
        clock.advance(by: .milliseconds(25))
        await #expect(throws: BackgroundSynchronizationError.deadlineExceeded) { try await bounded { try await work.value } }
        await probe.record("lease released")
        let events = await probe.events
        #expect(events.contains("commit finished"))
        #expect(events.contains("transport stopped"))
        #expect(events.last == "lease released")
    }

    @Test func callerCancellationJoinsConsumerBeforeReturning() async throws {
        let probe = BackgroundProbe()
        let task = Task {
            try await runBackgroundWork(timeBudget: .seconds(20), clock: TestClock(), operation: {
                await untilCancelled()
                throw CancellationError()
            }, consume: {
                await probe.begin()
                await untilCancelled()
                await probe.record("consumer joined")
                try Task.checkCancellation()
            }, stop: { await probe.record("transport stopped") })
        }
        try await bounded { await probe.waitForStart() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await bounded { try await task.value } }
        #expect(await probe.events.contains("consumer joined"))
        #expect(await probe.events.contains("transport stopped"))
    }

    @Test func successfulArchiveStopsAndJoinsLiveConsumer() async throws {
        let probe = BackgroundProbe()
        try await bounded {
            try await runBackgroundWork(timeBudget: .seconds(20), clock: TestClock(), operation: {
                await probe.waitForStart()
            }, consume: {
                await probe.begin()
                await untilCancelled()
                await probe.record("consumer joined")
            }, stop: { await probe.record("transport stopped") })
        }
        #expect(await probe.events.contains("consumer joined"))
        #expect(await probe.events.contains("transport stopped"))
    }

    // The XEP-0490 pull after catch-up is best effort: a connection lost during it (the consumer sees the disconnect
    // first) still ends the run successfully once the walk committed; before the walk it fails the run.
    @Test func connectionLostAfterCatchUpStillSucceeds() async throws {
        let caughtUp = CatchUpMark()
        try await bounded {
            try await runBackgroundWork(timeBudget: .seconds(20), clock: TestClock(), operation: {
                await caughtUp.reach()
                // A slow pull, cut short by the ended connection.
                await untilCancelled()
                throw CancellationError()
            }, consume: {
                try await consumeUntilDisconnect(after: caughtUp) {
                    while await !caughtUp.reached { await Task.yield() }
                    throw BackgroundSynchronizationError.connectionEnded
                }
            }, stop: {})
        }
        let early = CatchUpMark()
        await #expect(throws: BackgroundSynchronizationError.connectionEnded) {
            try await bounded {
                try await runBackgroundWork(timeBudget: .seconds(20), clock: TestClock(), operation: {
                    await untilCancelled()
                    throw CancellationError()
                }, consume: {
                    try await consumeUntilDisconnect(after: early) { throw BackgroundSynchronizationError.connectionEnded }
                }, stop: {})
            }
        }
    }

    // A room that never answers, a connection lost during the room walk, or a room page that cannot be
    // processed, once the own archive committed. The direct message is posted at once and the run ends as a success,
    // the stalled room cut short soon after the post (the app may be waiting for the lease); with nothing direct to
    // post, what the push was about is unknown and the run fails with what cut the rooms short, so the extension shows
    // the fallback.
    @Test(arguments: [RoomTrouble.stalls, .losesConnection, .breaks])
    func aStuckRoomNeverHidesCommittedDirectMessages(_ trouble: RoomTrouble) async throws {
        for direct in [true, false] {
            try await withStore { store in
                let run = try await CatchUpFixture(store: store, ownMessages: direct ? 1 : 0, roomMessage: false, trouble: trouble)
                if direct {
                    let work = Task { try await run.run(budget: .seconds(10), roomsAfterPost: .milliseconds(300)) }
                    if trouble == .stalls {
                        try await clock(of: run, stallsThenPasses: .milliseconds(300))
                    }
                    try await bounded { try await work.value }
                    // The stalled room got the 300 ms after the post, not the 10 s budget.
                    #expect(run.clock.elapsed == (trouble == .stalls ? .milliseconds(300) : .zero))
                    #expect(await run.posting.added.map(\.body) == ["Direct"])
                    #expect(await run.posting.addedAt == [.zero])
                    #expect(run.progress.isCommitted && run.progress.report.posted == 1)
                    #expect(run.progress.report.firstPostMilliseconds != nil)
                } else {
                    let expected: any Error = switch trouble {
                    case .stalls: BackgroundSynchronizationError.deadlineExceeded
                    case .losesConnection: BackgroundSynchronizationError.connectionEnded
                    case .breaks: RoomTrouble.Unreadable.page
                    }
                    let work = Task { try await run.run(budget: .seconds(2)) }
                    if trouble == .stalls {
                        try await clock(of: run, stallsThenPasses: .seconds(2))
                    }
                    let error = await #expect(throws: (any Error).self) { try await bounded { try await work.value } }
                    #expect(error.map(NotificationFallbackReason.init) == NotificationFallbackReason(expected))
                    #expect(await run.posting.added.isEmpty)
                    #expect(!run.progress.isCommitted)
                }
            }
        }
    }

    // Once the room stalls and something sleeps until `offset`, moves the fixture's clock there.
    private func clock(of run: CatchUpFixture, stallsThenPasses offset: Duration) async throws {
        try await eventually("the room to stall") { await run.trace.hasStarted() }
        try await run.clock.sleeper(until: offset)
        run.clock.advance(by: offset)
    }

    // The early presentation claims what it posted, so the final one adds only what the rooms brought, after a second
    // read-state pull, and the run plays one sound.
    @Test func roomMessagesFollowTheDirectOnesWithoutRepeatingThem() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 1, roomMessage: true, trouble: nil)
            try await bounded { try await run.run(budget: .seconds(5)) }
            let added = await run.posting.added
            #expect(added.map(\.body) == ["Direct", "Room"])
            #expect(added.map(\.playsSound) == [true, false])
            #expect(await run.trace.events == ["pull", "post", "room", "pull", "post"])
            #expect(run.progress.report.posted == 2 && run.progress.report.claimed == 2)
        }
    }

    // The early presentation's last add (the one with the sound) fails: the final presentation posts both again and
    // plays the run's one sound, and the report counts every add that completed.
    @Test func aDirectPresentationThatFailsPartWayLeavesTheSoundToTheFinalOne() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 2, roomMessage: false, trouble: nil)
            await run.posting.failOnce(at: 1)
            try await bounded { try await run.run(budget: .seconds(5)) }
            let added = await run.posting.added
            #expect(added.map(\.body) == ["Direct", "Direct", "Direct 2"])
            #expect(added.map(\.playsSound) == [false, false, true])
            #expect(run.progress.isCommitted && run.progress.report.posted == added.count)
        }
    }

    // The deadline cancels the early presentation while the system is still adding its sound-carrying request: that add
    // may still land, so the final presentation posts the message again without a sound. The run plays one sound.
    @Test func aDeadlineDuringTheDirectPresentationNeverPlaysASecondSound() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 1, roomMessage: false, trouble: nil)
            await run.posting.delayFirstAdd(by: .milliseconds(1_500))
            let work = Task { try await run.run(budget: .seconds(1)) }
            // The budget runs out while the first add is still in the system.
            try await run.clock.sleeper(until: .seconds(1))
            try await run.clock.sleeper(until: .milliseconds(1_500))
            run.clock.advance(by: .seconds(1))
            try await bounded { try await work.value }
            run.clock.advance(by: .milliseconds(500))
            try await eventually("the late add to land") { await run.posting.added.count == 2 }
            let added = await run.posting.added
            #expect(added.map(\.body) == ["Direct", "Direct"])
            #expect(added.filter(\.playsSound).count == 1)
            #expect(run.progress.isCommitted)
        }
    }

    // A push that arrives while the rooms are walked, after the direct message was posted, joins the run (its message
    // comes in over the same connection) instead of queueing a second full run that would hold the lease again. Until
    // the final presentation commits, an expiring request is not settled: its message may not be posted yet.
    @Test func aPushDuringTheRoomWalkJoinsTheRunThatPostedEarly() async throws {
        try await withStore { store in
            let run = try await CatchUpFixture(store: store, ownMessages: 1, roomMessage: false, trouble: .stalls)
            let joined = LastRun()
            let coordinator = NotificationRunCoordinator { progress in
                joined.started(progress)
                do {
                    try await run.run(budget: .seconds(2), roomsAfterPost: .seconds(1), progress: progress)
                    return .settled(progress.report)
                } catch {
                    return progress.isCommitted ? .settled(progress.report) : .fallback(NotificationFallbackReason(error))
                }
            }
            let first = Task { await coordinator.deliver(ticket: UUID()) }
            try await eventually("the direct post") { await !run.posting.added.isEmpty }
            let second = Task { await coordinator.deliver(ticket: UUID()) }
            let expiring = UUID()
            let third = Task { await coordinator.deliver(ticket: expiring) }
            try await eventually("both pushes to join") { joined.progress?.joined == 3 }
            #expect(coordinator.activeRuns == 1)
            #expect(coordinator.expire(ticket: expiring) == .fallback(.expired))
            // The stalled room is cut a second after the post.
            try await run.clock.sleeper(until: .seconds(1))
            run.clock.advance(by: .seconds(1))
            for delivery in [first, second] { #expect(try await bounded { await delivery.value }.suppressesRemoteAlert) }
            _ = try await bounded { await third.value }
            #expect(await run.posting.added.map(\.body) == ["Direct"])
        }
    }

    @Test func readSyncPullNeverOutlastsTheBudget() {
        let now = TestClock().now
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
        // One attempt is enough to see the refusal; NotificationDeliveryTests owns the bounded wait.
        await #expect(throws: MessageStoreError.transportOwnedElsewhere) {
            try await BackgroundSynchronizer().synchronize(databaseURL: url, wrappingKey: Data(repeating: 1, count: 32), account: account, leaseWait: .zero)
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

    // The notification extension's entry point finds a store the previous build wrote: it neither migrates nor
    // connects, leaves the file byte for byte as it was, and the run falls back to the generic notification.
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
