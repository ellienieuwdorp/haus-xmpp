import Foundation
import Testing
import MessageStore
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
