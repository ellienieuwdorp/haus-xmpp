import XCTest
@testable import HausXMPP

@MainActor final class AttachmentDispatchTests: XCTestCase {
    func testFilesGoOneByOneThenTheCaptionLast() async {
        var sent: [String] = []
        let result = await ComposerState.dispatch(["a.jpg", "b.jpg"], caption: "Look",
                                                  sendFile: { sent.append($0); return true },
                                                  sendCaption: { sent.append("caption: " + $0); return true })
        XCTAssertEqual(sent, ["a.jpg", "b.jpg", "caption: Look"])
        XCTAssertEqual(result.files, 2)
        XCTAssertTrue(result.caption)
    }

    func testTheFirstRefusalStopsEverythingAfterIt() async {
        var sent: [String] = []
        let result = await ComposerState.dispatch(["a.jpg", "b.jpg", "c.jpg"], caption: "Look",
                                                  sendFile: { file in guard file != "b.jpg" else { return false }; sent.append(file); return true },
                                                  sendCaption: { sent.append($0); return true })
        XCTAssertEqual(sent, ["a.jpg"])
        XCTAssertEqual(result.files, 1)
        XCTAssertFalse(result.caption)
    }

    func testAnUploadGivesUpAfterItsBudgetAndARetryStartsOver() {
        var budget = UploadFailureBudget()
        for _ in 1..<UploadFailureBudget.limit { XCTAssertFalse(budget.recordFailure("photo")) }
        XCTAssertFalse(budget.recordFailure("other"), "Each file has its own budget")
        XCTAssertTrue(budget.recordFailure("photo"))
        XCTAssertFalse(budget.recordFailure("photo"), "A retried file gets fresh tries")
        budget.reset("other")
        for _ in 1..<UploadFailureBudget.limit { XCTAssertFalse(budget.recordFailure("other")) }
    }

    /// A pass started by another file of the same send must not spend a refused file's next try before its back-off.
    func testARefusedFileWaitsOutItsBackOff() {
        var budget = UploadFailureBudget()
        let refused = ContinuousClock.now
        XCTAssertFalse(budget.recordFailure("photo", at: refused))
        XCTAssertTrue(budget.isWaiting("photo", at: refused + .seconds(1)))
        XCTAssertFalse(budget.isWaiting("other", at: refused + .seconds(1)), "Only the refused file waits")
        XCTAssertFalse(budget.isWaiting("photo", at: refused + UploadFailureBudget.backOff))
        XCTAssertFalse(budget.recordFailure("photo", at: refused))
        budget.reset("photo")
        XCTAssertFalse(budget.isWaiting("photo", at: refused), "Retry tries again at once")
        for _ in 1..<UploadFailureBudget.limit { XCTAssertFalse(budget.recordFailure("photo", at: refused)) }
        XCTAssertTrue(budget.recordFailure("photo", at: refused))
        XCTAssertFalse(budget.isWaiting("photo", at: refused), "A file that used its tries is failed, not waiting")
    }

    /// A pass that parks until the test releases it and takes the files queued when it starts, as an upload pass
    /// reads the files awaiting a slot once.
    @MainActor private final class UploadPassGate {
        var queued: [String] = []
        var taken: [[String]] = []
        private(set) var overlapped = false
        private var running = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func pass() async {
            running += 1
            overlapped = overlapped || running > 1
            taken.append(queued)
            queued = []
            await withCheckedContinuation { waiting.append($0) }
            running -= 1
        }
        func release() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
        /// Yields until `count` passes have started, or gives up so a lost request fails instead of hanging.
        func settle(_ count: Int) async { for _ in 0..<1_000 where taken.count < count { await Task.yield() } }
    }

    /// Photos 3 and 4 of a four-photo send are queued while the pass for photos 1 and 2 waits on its slots. Their
    /// requests must start another pass when that one ends, not wait for the next connection.
    func testFilesQueuedDuringAPassGetTheNextPass() async {
        let gate = UploadPassGate()
        let passes = RerunningPass { { await gate.pass() } }
        gate.queued = ["photo 1", "photo 2"]
        passes.request()
        await gate.settle(1)
        for photo in ["photo 3", "photo 4"] { gate.queued.append(photo); passes.request() }
        await gate.settle(2)
        XCTAssertEqual(gate.taken.count, 1, "Passes never overlap")
        gate.release()
        await gate.settle(2)
        XCTAssertEqual(gate.taken, [["photo 1", "photo 2"], ["photo 3", "photo 4"]])
        gate.release()
        await gate.settle(3)
        XCTAssertEqual(gate.taken.count, 2, "Requests made during one pass cost one more pass")
        XCTAssertFalse(gate.overlapped)
    }
}
