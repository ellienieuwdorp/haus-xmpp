import Foundation
import Testing
import MessageStore
import Darwin
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
            let present: @Sendable (MessageNotification) throws -> Void = { batch in
                #expect(batch.messageCount == 0)
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
                    try await finishBackgroundPresentation(store: store, accountID: "alice", presentation: present)
                }
            } else {
                _ = try await finishBackgroundPresentation(store: store, accountID: "alice", presentation: present)
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

    @Test func readSyncPullNeverOutlastsTheBudget() {
        let now = ContinuousClock.now
        #expect(readSyncTimeout(until: now + .seconds(20), now: now) == .seconds(5))
        #expect(readSyncTimeout(until: now + .seconds(3), now: now) == .seconds(2))
        #expect(readSyncTimeout(until: now + .milliseconds(1_200), now: now) == nil)
        #expect(readSyncTimeout(until: now - .seconds(1), now: now) == nil)
    }

    @Test func refusesBusyStoreAndNeverCreatesMissingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "background-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: url)
        let account = BackgroundAccount(host: "localhost", domain: "localhost", username: "alice", password: "private")
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
}
