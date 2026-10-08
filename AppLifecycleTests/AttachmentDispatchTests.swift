import MessageStore
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

    /// Which part of a send carries the composer's reply, in a sample chat, where files alone may reply to an own
    /// message only: a received photo's reply waits for a caption, an own message's rides on the first file.
    func testTheCaptionCarriesTheReplyAndFilesAloneOnlyWhereTheChatAllows() {
        let account = "me@preview.local", chat = "alex@preview.local"
        let received = StoredMessage(id: "photo", accountID: account, chatID: chat, senderID: chat, body: "", isOutgoing: false)
        let own = StoredMessage(id: "own", accountID: account, chatID: chat, senderID: account, body: "Love this view", isOutgoing: true)
        let gate = { (source: StoredMessage) in
            AppModel.filesAloneCanReply(to: source, accountID: account, chatID: chat, isGroup: false, isDemo: true, chatProfile: nil)
        }
        let cases: [(caption: String, reply: StoredMessage?, firstFile: String?, captionReply: String?, line: UInt)] = [
            ("", received, nil, nil, #line),
            (" \n", received, nil, nil, #line),
            ("", own, "own", nil, #line),
            ("Love it", received, nil, "photo", #line),
            ("Love it", own, nil, "own", #line),
            ("", nil, nil, nil, #line),
        ]
        for row in cases {
            let plan = ComposerState.ReplyPlan(caption: row.caption, reply: row.reply, filesAloneCanReply: gate)
            XCTAssertEqual(plan.firstFile?.id, row.firstFile, "first file", line: row.line)
            XCTAssertEqual(plan.caption?.id, row.captionReply, "caption", line: row.line)
        }

        // The reply clears once the part carrying it went; otherwise it stays in the composer for a caption.
        let waits = ComposerState.ReplyPlan(caption: "", reply: received, filesAloneCanReply: gate)
        XCTAssertFalse(waits.clearsReply(after: (files: 1, caption: false)), "the file went without the reply")
        let fileCarries = ComposerState.ReplyPlan(caption: "", reply: own, filesAloneCanReply: gate)
        XCTAssertTrue(fileCarries.clearsReply(after: (files: 1, caption: false)))
        XCTAssertFalse(fileCarries.clearsReply(after: (files: 0, caption: false)), "the file carrying it was refused")
        let captionCarries = ComposerState.ReplyPlan(caption: "Love it", reply: received, filesAloneCanReply: gate)
        XCTAssertTrue(captionCarries.clearsReply(after: (files: 1, caption: true)))
        XCTAssertFalse(captionCarries.clearsReply(after: (files: 1, caption: false)), "the caption was refused")

        // The field says so before Send.
        XCTAssertEqual(ComposerState.trayPlaceholder(reply: received, filesAloneCanReply: gate), "Add a caption to reply…")
        XCTAssertEqual(ComposerState.trayPlaceholder(reply: own, filesAloneCanReply: gate), "Add a caption…")
        XCTAssertEqual(ComposerState.trayPlaceholder(reply: nil, filesAloneCanReply: gate), "Add a caption…")
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
