import Foundation
import MessageStore
import XCTest
@testable import HausXMPP

// Background PUTs matched to their rows by tag: what the session still runs or finished while the app was away is
// adopted, and only a slot with neither is uploaded again.
final class BackgroundUploadTests: XCTestCase {
    private let account = "alice@example.org"
    private let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func tag(_ message: String, _ url: String, account: String? = nil) -> UploadTag {
        UploadTag(account: account ?? self.account, messageID: message, url: url)
    }

    private func row(_ message: String, url: String?, taskID: Int? = nil, queued: Bool = true) -> UploadRow {
        UploadRow(messageID: message, url: url, taskID: taskID, queued: queued)
    }

    private func outcome(_ tag: UploadTag, succeeded: Bool) -> UploadOutcome {
        UploadOutcome(tag: tag, succeeded: succeeded, finishedAt: finishedAt)
    }

    func testTheTagRoundTripsThroughTheTaskDescription() throws {
        let original = tag("m1", "https://upload.example.org/a/photo.jpg")
        XCTAssertEqual(UploadTag(taskDescription: try XCTUnwrap(original.taskDescription)), original)
        XCTAssertNil(UploadTag(taskDescription: nil))
        XCTAssertNil(UploadTag(taskDescription: "17"))
    }

    // The lab failure: reconcile runs while the PUT is still in the session, and its completion lands afterwards.
    func testACompletionArrivingAfterReconcileIsAdoptedNotUploadedAgain() {
        let attempt = tag("m1", "https://u/1")
        let rows = [row("m1", url: attempt.url, taskID: 4)]
        let atReconcile = UploadPlan.make(account: account, rows: rows, tasks: [UploadTaskState(taskID: 4, tag: attempt, phase: .live)],
                                          outcomes: [], detectsStranded: true)
        XCTAssertEqual(atReconcile, UploadPlan.Result(resume: [4]), "the running PUT is left to finish")

        let afterwards = UploadPlan.make(account: account, rows: rows, tasks: [], outcomes: [outcome(attempt, succeeded: true)], detectsStranded: false)
        XCTAssertEqual(afterwards, UploadPlan.Result(uploaded: ["m1": attempt.url], settled: [attempt]))
    }

    // A relaunch whose session has not yet listed the old PUT gives the row a new slot; the old PUT's success still
    // wins, at its own URL, and the new attempt stops.
    func testALateSuccessOfAnEarlierAttemptWinsAndStopsTheNewOne() {
        let old = tag("m1", "https://u/1"), new = tag("m1", "https://u/2")
        let stranded = UploadPlan.make(account: account, rows: [row("m1", url: old.url, taskID: 4)], tasks: [], outcomes: [], detectsStranded: true)
        XCTAssertEqual(stranded, UploadPlan.Result(stranded: ["m1"]))

        let late = UploadPlan.make(account: account, rows: [row("m1", url: new.url, taskID: 1)],
                                   tasks: [UploadTaskState(taskID: 1, tag: new, phase: .live)],
                                   outcomes: [outcome(old, succeeded: true)], detectsStranded: false)
        XCTAssertEqual(late, UploadPlan.Result(uploaded: ["m1": old.url], cancel: [1], settled: [old]))
    }

    func testOnlyTheRowsOwnAttemptCountsAFailure() {
        let old = tag("m1", "https://u/1"), new = tag("m1", "https://u/2")
        let stale = UploadPlan.make(account: account, rows: [row("m1", url: new.url, taskID: 1)],
                                    tasks: [UploadTaskState(taskID: 1, tag: new, phase: .live)],
                                    outcomes: [outcome(old, succeeded: false)], detectsStranded: true)
        XCTAssertEqual(stale, UploadPlan.Result(resume: [1], settled: [old]))

        let own = UploadPlan.make(account: account, rows: [row("m1", url: new.url, taskID: 1)], tasks: [],
                                  outcomes: [outcome(new, succeeded: false)], detectsStranded: false)
        XCTAssertEqual(own, UploadPlan.Result(failed: ["m1"], settled: [new]))

        // A file already shown as Not sent only gives its slot back.
        let shownFailed = UploadPlan.make(account: account, rows: [row("m1", url: new.url, taskID: 1, queued: false)], tasks: [],
                                          outcomes: [outcome(new, succeeded: false)], detectsStranded: false)
        XCTAssertEqual(shownFailed, UploadPlan.Result(stranded: ["m1"], settled: [new]))
    }

    // An HTTP 413 refuses the same bytes on every attempt, so the row's own refused attempt fails it at once; an earlier
    // attempt's refusal, or one for a file already shown as Not sent, does not.
    func testATooLargeAnswerToTheRowsOwnAttemptIsMarked() {
        let old = tag("m1", "https://u/1"), new = tag("m1", "https://u/2")
        let refused = UploadOutcome(tag: new, succeeded: false, tooLarge: true, finishedAt: finishedAt)
        let own = UploadPlan.make(account: account, rows: [row("m1", url: new.url, taskID: 1)], tasks: [], outcomes: [refused], detectsStranded: false)
        XCTAssertEqual(own, UploadPlan.Result(failed: ["m1"], tooLarge: ["m1"], settled: [new]))

        let listed = UploadPlan.make(account: account, rows: [row("m1", url: new.url, taskID: 1)],
                                     tasks: [UploadTaskState(taskID: 1, tag: new, phase: .finished(succeeded: false, tooLarge: true))],
                                     outcomes: [], detectsStranded: false)
        XCTAssertEqual(listed, UploadPlan.Result(failed: ["m1"], tooLarge: ["m1"]))

        let stale = UploadPlan.make(account: account, rows: [row("m1", url: new.url, taskID: 1)], tasks: [],
                                    outcomes: [UploadOutcome(tag: old, succeeded: false, tooLarge: true, finishedAt: finishedAt),
                                               outcome(new, succeeded: false)], detectsStranded: false)
        XCTAssertEqual(stale, UploadPlan.Result(failed: ["m1"], settled: [old, new]))

        let shownFailed = UploadPlan.make(account: account, rows: [row("m1", url: new.url, taskID: 1, queued: false)], tasks: [],
                                          outcomes: [refused], detectsStranded: false)
        XCTAssertEqual(shownFailed, UploadPlan.Result(stranded: ["m1"], settled: [new]))
    }

    func testAJournalEntryWithoutTheTooLargeFlagStillDecodes() throws {
        let entry = #"[{"tag":{"account":"alice@example.org","messageID":"m1","url":"https://u/1"},"succeeded":false,"finishedAt":0}]"#
        let decoded = try JSONDecoder().decode([UploadOutcome].self, from: Data(entry.utf8))
        XCTAssertEqual(decoded.first?.tooLarge, nil)
        XCTAssertEqual(decoded.first?.succeeded, false)
    }

    // Finished in the session but not yet delivered to the delegate: the task's own result settles the row.
    func testAFinishedTaskTheSessionStillListsSettlesTheRow() {
        let attempt = tag("m1", "https://u/1")
        let plan = UploadPlan.make(account: account, rows: [row("m1", url: attempt.url, taskID: 4)],
                                   tasks: [UploadTaskState(taskID: 4, tag: attempt, phase: .finished(succeeded: true))],
                                   outcomes: [], detectsStranded: true)
        XCTAssertEqual(plan, UploadPlan.Result(uploaded: ["m1": attempt.url]))
    }

    // The app stopped between making the task and writing its row, or a stranded pass cleared a slot whose PUT
    // still runs: the row takes that task's attempt and the task runs.
    func testALiveTaskTheRowDoesNotNameIsAdoptedAndResumed() {
        let attempt = tag("m1", "https://u/1"), other = tag("m1", "https://u/3")
        let unnamed = UploadPlan.make(account: account, rows: [row("m1", url: nil)],
                                      tasks: [UploadTaskState(taskID: 8, tag: attempt, phase: .live)], outcomes: [], detectsStranded: true)
        XCTAssertEqual(unnamed, UploadPlan.Result(adopted: ["m1": .init(taskID: 8, url: attempt.url)], resume: [8]))

        // Of two live attempts the row's own runs on.
        let duplicate = UploadPlan.make(account: account, rows: [row("m1", url: attempt.url, taskID: 8)],
                                        tasks: [UploadTaskState(taskID: 8, tag: attempt, phase: .live), UploadTaskState(taskID: 9, tag: other, phase: .live)],
                                        outcomes: [], detectsStranded: true)
        XCTAssertEqual(duplicate, UploadPlan.Result(resume: [8], cancel: [9]))
    }

    func testOtherAccountsAndUntaggedTasksAreNotMatched() {
        let theirs = tag("m9", "https://u/9", account: "bob@example.org"), gone = tag("m5", "https://u/5")
        let plan = UploadPlan.make(account: account, rows: [row("m1", url: "https://u/1", taskID: 3)],
                                   tasks: [UploadTaskState(taskID: 3, tag: nil, phase: .live),
                                           UploadTaskState(taskID: 6, tag: theirs, phase: .live),
                                           UploadTaskState(taskID: 7, tag: gone, phase: .live)],
                                   outcomes: [outcome(theirs, succeeded: true), outcome(gone, succeeded: true)], detectsStranded: true)
        // The untagged task shares the row's identifier, which names a task only within one session object.
        XCTAssertEqual(plan, UploadPlan.Result(stranded: ["m1"], cancel: [3, 7], settled: [gone]))
    }

    func testOfTwoSuccessesTheRowsOwnURLIsKept() {
        let first = tag("m1", "https://u/1"), second = tag("m1", "https://u/2")
        let plan = UploadPlan.make(account: account, rows: [row("m1", url: second.url, taskID: 2)], tasks: [],
                                   outcomes: [outcome(first, succeeded: true), outcome(second, succeeded: true)], detectsStranded: false)
        XCTAssertEqual(plan.uploaded, ["m1": second.url])
    }

    // A relaunch for session events can end before storage opens: the outcome survives on disk until settled, and
    // outcomes nobody settles are dropped after the retention.
    func testTheJournalKeepsOutcomesAcrossRelaunchUntilSettledOrExpired() throws {
        let file = try scratch().appending(path: "Uploads/primary.json")
        let kept = tag("m1", "https://u/1"), settled = tag("m2", "https://u/2"), theirs = tag("m3", "https://u/3", account: "bob@example.org")
        let journal = UploadJournal(file: file)
        for (attempt, offset) in [(kept, 0.0), (settled, 0), (theirs, -UploadJournal.retention)] {
            journal.record(UploadOutcome(tag: attempt, succeeded: true, finishedAt: finishedAt.addingTimeInterval(offset)))
        }
        journal.record(UploadOutcome(tag: kept, succeeded: false, finishedAt: finishedAt))

        let relaunched = UploadJournal(file: file)
        XCTAssertEqual(relaunched.outcomes(account: account).map(\.tag), [settled, kept])
        XCTAssertEqual(relaunched.outcomes(account: account).last?.succeeded, false, "a repeated report replaces the earlier one")
        relaunched.remove([settled], now: finishedAt.addingTimeInterval(1))
        XCTAssertEqual(UploadJournal(file: file).outcomes(account: account).map(\.tag), [kept])
        XCTAssertEqual(UploadJournal(file: file).outcomes(account: "bob@example.org"), [], "older than the retention")
    }

    // Before the first unlock the file opens neither way; what arrived meanwhile merges with it, not over it.
    func testAJournalThatCannotOpenItsFileMergesWithItLater() throws {
        let file = try scratch().appending(path: "primary.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let early = tag("m1", "https://u/1"), stored = tag("m2", "https://u/2")
        let journal = UploadJournal(file: file)
        journal.record(outcome(early, succeeded: true))
        XCTAssertEqual(journal.outcomes(account: account).map(\.tag), [early])

        try FileManager.default.removeItem(at: file)
        UploadJournal(file: file).record(outcome(stored, succeeded: true))
        XCTAssertEqual(journal.outcomes(account: account).map(\.tag), [stored, early])
        journal.remove([], now: finishedAt)
        journal.record(outcome(early, succeeded: true))
        XCTAssertEqual(UploadJournal(file: file).outcomes(account: account).map(\.tag), [stored, early])
    }

    // The same lab sequence against a real store: reconcile, then the completion; one slot, never a second.
    func testTheSettlerAdoptsALateCompletionInTheStore() async throws {
        let (store, journal) = try await fixture(messages: ["m1"])
        let attempt = tag("m1", "https://u/1")
        try await store.setAttachmentUploadTask(accountID: account, messageID: "m1", taskID: 4, url: attempt.url)
        let tasks = FakeTasks([UploadTaskState(taskID: 4, tag: attempt, phase: .live)])
        let settler = UploadSettler(store: store, tasks: tasks, journal: journal)

        let atReconcile = await settler.settle(account: account, detectsStranded: true, now: finishedAt)
        XCTAssertEqual(atReconcile, UploadSettler.Settlement())
        let waiting = try await store.attachmentsAwaitingUpload(accountID: account)
        XCTAssertEqual(waiting.map(\.attachment?.uploadTaskID), [4], "the row keeps its running attempt, so the upload pass skips it")

        await tasks.set([])
        journal.record(outcome(attempt, succeeded: true))
        let afterwards = await settler.settle(account: account, detectsStranded: false, now: finishedAt)
        XCTAssertEqual(afterwards.uploaded, ["m1"])
        let awaiting = try await store.attachmentsAwaitingUpload(accountID: account)
        XCTAssertTrue(awaiting.isEmpty)
        let sent = try await store.message(accountID: account, messageID: "m1")
        XCTAssertEqual(sent?.attachment?.uploadState, .uploaded)
        XCTAssertEqual(sent?.attachment?.url, attempt.url)
        XCTAssertEqual(journal.outcomes(account: account), [])
        let applied = await tasks.applied
        XCTAssertEqual(applied.cancel, [])
    }

    func testTheSettlerRecordsALateSuccessAtItsOwnURLAndCancelsTheNewAttempt() async throws {
        let (store, journal) = try await fixture(messages: ["m1"])
        let old = tag("m1", "https://u/1"), new = tag("m1", "https://u/2")
        try await store.setAttachmentUploadTask(accountID: account, messageID: "m1", taskID: 4, url: old.url)
        let tasks = FakeTasks([])
        let settler = UploadSettler(store: store, tasks: tasks, journal: journal)
        _ = await settler.settle(account: account, detectsStranded: true, now: finishedAt)
        let cleared = try await store.message(accountID: account, messageID: "m1")
        XCTAssertNil(cleared?.attachment?.uploadTaskID, "nothing in the session or journal: a new slot")

        try await store.setAttachmentUploadTask(accountID: account, messageID: "m1", taskID: 1, url: new.url)
        await tasks.set([UploadTaskState(taskID: 1, tag: new, phase: .live)])
        journal.record(outcome(old, succeeded: true))
        let late = await settler.settle(account: account, detectsStranded: false, now: finishedAt)
        XCTAssertEqual(late.uploaded, ["m1"])
        let message = try await store.message(accountID: account, messageID: "m1")
        XCTAssertEqual(message?.attachment?.url, old.url)
        let applied = await tasks.applied
        XCTAssertEqual(applied.cancel, [1])
    }

    func testConcurrentSettlesCountAFailureOnce() async throws {
        let (store, journal) = try await fixture(messages: ["m1"])
        let attempt = tag("m1", "https://u/1")
        try await store.setAttachmentUploadTask(accountID: account, messageID: "m1", taskID: 4, url: attempt.url)
        journal.record(outcome(attempt, succeeded: false))
        let settler = UploadSettler(store: store, tasks: FakeTasks([]), journal: journal)
        let account = account, now = finishedAt
        async let first = settler.settle(account: account, detectsStranded: false, now: now)
        async let second = settler.settle(account: account, detectsStranded: false, now: now)
        let failures = await first.failed.count + second.failed.count
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(journal.outcomes(account: account), [])
    }

    // A file shown as Not sent is outside the awaiting list; its PUT finishing still records where the bytes are.
    func testTheSettlerReadsRowsTheAwaitingListLeavesOut() async throws {
        let (store, journal) = try await fixture(messages: ["m1"])
        let attempt = tag("m1", "https://u/1")
        try await store.setAttachmentUploadTask(accountID: account, messageID: "m1", taskID: 4, url: attempt.url)
        try await store.failQueuedOutgoing(accountID: account, messageID: "m1")
        journal.record(outcome(attempt, succeeded: true))
        let settlement = await UploadSettler(store: store, tasks: FakeTasks([]), journal: journal)
            .settle(account: account, detectsStranded: true, now: finishedAt)
        XCTAssertEqual(settlement.uploaded, ["m1"])
        let message = try await store.message(accountID: account, messageID: "m1")
        XCTAssertEqual(message?.attachment?.uploadState, .uploaded)
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BackgroundUploadTests-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func fixture(messages: [String]) async throws -> (MessageStore, UploadJournal) {
        let directory = try scratch()
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        try await store.upsertChat(accountID: account, chatID: "bob@example.org", title: "Bob")
        for id in messages {
            let attachment = StoredAttachment(name: "photo.jpg", mediaType: "image/jpeg", size: 10, hash: String(repeating: "0", count: 64),
                                              secret: Data([1]), uploadState: .pending)
            _ = try await store.enqueueOutgoing(StoredMessage(id: id, accountID: account, chatID: "bob@example.org", senderID: account, body: "",
                                                              sentAt: finishedAt, isOutgoing: true, attachment: attachment))
        }
        return (store, UploadJournal(file: directory.appending(path: "journal.json")))
    }
}

private actor FakeTasks: UploadTasks {
    private var current: [UploadTaskState]
    private(set) var applied: (resume: Set<Int>, cancel: Set<Int>) = ([], [])

    init(_ states: [UploadTaskState]) { current = states }

    func set(_ states: [UploadTaskState]) { current = states }
    func states() -> [UploadTaskState] { current }
    func apply(resume: Set<Int>, cancel: Set<Int>) {
        applied.resume.formUnion(resume)
        applied.cancel.formUnion(cancel)
    }
}
