import MessagingCore
import XCTest
@testable import HausXMPP

@MainActor final class AttachmentQueueTests: XCTestCase {
    // A queue whose items run on gates and record each result they report.
    @MainActor private final class Run {
        let queue = AttachmentQueue()
        let gates = WorkGates()
        var finished: [String] = []

        @discardableResult func enqueue(_ name: String, id: UUID = UUID()) -> UUID {
            let gates = gates
            queue.enqueue(id, { try await gates.run(name) }, done: { [weak self] result in
                self?.finished.append((try? result.get())?.name ?? "\(name) failed")
            })
            return id
        }
    }

    func testItemsPrepareOneAtATimeInTheOrderTheyCame() async {
        let run = Run(), queue = run.queue, gates = run.gates
        run.enqueue("a"); run.enqueue("b"); run.enqueue("c")
        await gates.waitForStarted(1)
        var started = await gates.started
        XCTAssertEqual(started, ["a"])
        await gates.finish("a")
        await gates.waitForStarted(2)
        started = await gates.started
        XCTAssertEqual(started, ["a", "b"], "b starts only after a is done")
        await gates.finish("b")
        await gates.waitForStarted(3)
        await gates.finish("c")
        await queue.drained()
        started = await gates.started
        XCTAssertEqual(started, ["a", "b", "c"])
        XCTAssertEqual(run.finished, ["a", "b", "c"])
    }

    func testCancellingAnItemStopsItsWorkOrSkipsItAndTheRestStillRun() async {
        let run = Run(), queue = run.queue, gates = run.gates
        let a = run.enqueue("a"), b = run.enqueue("b")
        run.enqueue("c")
        await gates.waitForStarted(1)
        queue.cancel(b)
        queue.cancel(a)
        await gates.waitForStarted(2)
        await gates.finish("c")
        await queue.drained()
        let started = await gates.started, stopped = await gates.stopped
        XCTAssertEqual(started, ["a", "c"], "a cancelled item that had not started never starts")
        XCTAssertEqual(stopped, ["a"], "the running item's work sees the cancellation")
        XCTAssertEqual(run.finished, ["c"], "no result for a cancelled item")
    }

    func testCancellingEverythingStopsTheRunningItemAndAnyLater() async {
        let run = Run(), queue = run.queue, gates = run.gates
        run.enqueue("a"); run.enqueue("b")
        await gates.waitForStarted(1)
        queue.cancelAll()
        run.enqueue("c")
        await queue.drained()
        let started = await gates.started, stopped = await gates.stopped
        XCTAssertEqual(started, ["a"])
        XCTAssertEqual(stopped, ["a"])
        XCTAssertEqual(run.finished, [], "the stopped item's cancellation is not reported as a failure")
    }

    // An offer to shorten prepares the same tray item again under its id.
    func testACancelThatLandsAsTheWorkReturnsDropsTheResultAndTheIdCanBeQueuedAgain() async {
        let run = Run(), queue = run.queue, gates = run.gates, id = UUID()
        queue.enqueue(id, {
            await MainActor.run { queue.cancel(id) }
            return PreparedAttachment(data: Data(), name: "late", mediaType: "application/octet-stream", width: nil, height: nil)
        }, done: { _ in run.finished.append("late") })
        await queue.drained()
        XCTAssertEqual(run.finished, [])

        run.enqueue("again", id: id)
        await gates.waitForStarted(1)
        await gates.finish("again")
        await queue.drained()
        XCTAssertEqual(run.finished, ["again"])
        queue.cancel(id)
        await queue.drained()
        XCTAssertEqual(run.finished, ["again"], "a cancel after the result changes nothing")
    }
}

@MainActor final class ComposerIntakeTests: XCTestCase {
    private final class Host: ComposerIntakeHost {
        var accountID = "alice@example.org"
        var attachmentLimit = 10 << 20
        var error: String?
    }

    private static func file(_ name: String) -> PreparedAttachment {
        PreparedAttachment(data: Data(), name: name, mediaType: "application/octet-stream", width: nil, height: nil)
    }

    private static func video(_ name: String, fitting seconds: Int) -> ComposerIntake.Job {
        { first in
            guard let first else { throw AttachmentPreparer.Failure.tooLong(seconds: seconds) }
            return file("\(name)-\(first)")
        }
    }

    func testTwoTooLongVideosInOneBatchAreOfferedOneAfterTheOther() async throws {
        let host = Host(), state = ComposerState(), intake = state.intake
        intake.add([Self.video("beach", fitting: 30), { _ in Self.file("photo") }, Self.video("party", fitting: 45)], to: state, model: host)
        await intake.settled()
        XCTAssertEqual(state.tray.map(\.prepared.name), ["photo"])
        let first = try XCTUnwrap(intake.offer)
        XCTAssertEqual(first.seconds, 30)
        XCTAssertNil(host.error)

        intake.answer(first, accepted: true, state: state, model: host)
        await intake.settled()
        XCTAssertEqual(state.tray.map(\.prepared.name), ["photo", "beach-30"])
        let second = try XCTUnwrap(intake.offer)
        XCTAssertEqual(second.seconds, 45)

        intake.answer(first, accepted: true, state: state, model: host)
        intake.answer(second, accepted: false, state: state, model: host)
        await intake.settled()
        XCTAssertNil(intake.offer)
        XCTAssertEqual(state.tray.map(\.prepared.name), ["photo", "beach-30"], "each offer is answered once")
    }

    func testAFileReadyAfterTheAccountChangedOrSendTookTheTrayStaysOut() async {
        let host = Host(), state = ComposerState(), intake = state.intake
        intake.add([{ _ in host.accountID = "bob@example.org"; return Self.file("switched") }], to: state, model: host)
        await intake.settled()
        host.accountID = "alice@example.org"
        intake.add([{ _ in state.sends += 1; return Self.file("sent") }], to: state, model: host)
        await intake.settled()
        XCTAssertTrue(state.tray.isEmpty)
        XCTAssertNil(host.error)
    }

    func testResetStopsWhatIsStillPreparing() async {
        let host = Host(), state = ComposerState(), intake = state.intake, gates = WorkGates()
        intake.add([{ _ in try await gates.run("video") }, { _ in Self.file("photo") }], to: state, model: host)
        await gates.waitForStarted(1)
        intake.reset()
        await intake.settled()
        let stopped = await gates.stopped
        XCTAssertEqual(stopped, ["video"])
        XCTAssertTrue(state.tray.isEmpty, "the rest of the batch is dropped too")
        XCTAssertNil(host.error, "a stop is not a failure")
        XCTAssertFalse(intake.attaching)
    }
}

// Work that runs until finished or cancelled, so no test waits on real time.
private actor WorkGates {
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []
    private var waiting: [String: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<String> = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated func run(_ name: String) async throws -> PreparedAttachment {
        try await withTaskCancellationHandler {
            try await park(name)
        } onCancel: {
            Task { await self.cancel(name) }
        }
        return PreparedAttachment(data: Data(), name: name, mediaType: "application/octet-stream", width: nil, height: nil)
    }

    func finish(_ name: String) { waiting.removeValue(forKey: name)?.resume() }

    func waitForStarted(_ count: Int) async { await withCheckedContinuation { watchers.append((count, $0)); notify() } }

    private func park(_ name: String) async throws {
        started.append(name)
        notify()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled.contains(name) { continuation.resume(throwing: CancellationError()) } else { waiting[name] = continuation }
            }
        } catch {
            stopped.append(name)
            throw error
        }
    }

    private func cancel(_ name: String) {
        cancelled.insert(name)
        waiting.removeValue(forKey: name)?.resume(throwing: CancellationError())
    }

    private func notify() {
        watchers.removeAll { watcher in
            guard started.count >= watcher.count else { return false }
            watcher.continuation.resume()
            return true
        }
    }
}
