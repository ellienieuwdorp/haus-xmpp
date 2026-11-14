import XCTest
import XMPPProtocol
@testable import HausXMPP

final class UploadRefusalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRefusalsThatCanNeverSucceedFailTheFileAtOnceWithTheirReason() {
        let stated = UploadRefusal(XMPPUploadError.fileTooLarge(maximumFileSize: 10_485_760), now: now)
        XCTAssertEqual(stated, .tooLarge(maximumFileSize: 10_485_760))
        let limit = ByteCountFormatter.string(fromByteCount: 10_485_760, countStyle: .file)
        XCTAssertEqual(stated.failure(name: "beach.mov"), "beach.mov is larger than the \(limit) this server accepts, so it was not sent.")

        let unstated = UploadRefusal(XMPPUploadError.fileTooLarge(maximumFileSize: nil), now: now)
        XCTAssertEqual(unstated.failure(name: "beach.mov"), "This server refused beach.mov as too large, so it was not sent.")

        let notAllowed = UploadRefusal(XMPPUploadError.notAllowed, now: now)
        XCTAssertEqual(notAllowed, .notAllowed)
        XCTAssertEqual(notAllowed.failure(name: "beach.mov"), "This server doesn't allow uploading beach.mov, so it was not sent.")

        for error: any Error in [XMPPIQError.stanza(condition: "internal-server-error"), XMPPIQError.stanza(condition: "resource-constraint"),
                                 XMPPClientError.timedOut] {
            XCTAssertEqual(UploadRefusal(error, now: now), .failed, "\(error) spends one of the file's tries")
            XCTAssertNil(UploadRefusal(error, now: now).failure(name: "beach.mov"))
        }
    }

    // The server's stamp sets the wait, which never outlasts the bound nor spins on a stamp already past.
    func testARetryStampWaitsUntilItWithinTheBound() {
        XCTAssertEqual(UploadRefusal(XMPPUploadError.retry(after: now.addingTimeInterval(42)), now: now), .wait(.seconds(42)))
        XCTAssertNil(UploadRefusal.wait(.seconds(42)).failure(name: "beach.mov"), "the file stays queued")
        XCTAssertEqual(UploadRefusal.wait(until: now.addingTimeInterval(90.5), now: now), .milliseconds(90_500))
        XCTAssertEqual(UploadRefusal.wait(until: now.addingTimeInterval(24 * 60 * 60), now: now), UploadRefusal.longestWait)
        XCTAssertEqual(UploadRefusal.wait(until: .distantFuture, now: now), UploadRefusal.longestWait)
        XCTAssertEqual(UploadRefusal.wait(until: now.addingTimeInterval(-60), now: now), UploadFailureBudget.backOff)
        XCTAssertEqual(UploadRefusal.wait(until: now, now: now), UploadFailureBudget.backOff)
        XCTAssertEqual(UploadRefusal.longestWait, .seconds(300))
    }

    // The composer's limit follows what the refusing service stated, in the app and in the share extension's copy.
    func testAStatedLimitReplacesTheRememberedOneForThatServiceOnly() throws {
        let suite = "upload-refusal-\(UUID())", mirrorSuite = "upload-refusal-mirror-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), mirror = try XCTUnwrap(UserDefaults(suiteName: mirrorSuite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            UserDefaults(suiteName: mirrorSuite)?.removePersistentDomain(forName: mirrorSuite)
        }
        let memory = UploadServiceMemory(defaults: defaults, mirror: mirror)
        let account = "alice@example.org", service = XMPPUploadService(jid: "upload.example.org", maximumFileSize: 20_000_000)
        XCTAssertEqual(memory.refused(account: account, current: service, service: service, maximumFileSize: 1_000), service,
                       "nothing remembered, nothing to change")

        _ = memory.settle(account: account, previous: nil, discovery: .success(service), now: now)
        let updated = memory.refused(account: account, current: service, service: service, maximumFileSize: 10_000_000)
        XCTAssertEqual(updated, XMPPUploadService(jid: "upload.example.org", maximumFileSize: 10_000_000))
        XCTAssertEqual(memory.load(account: account), updated, "a relaunch keeps the stated limit")
        XCTAssertEqual(UploadServiceMemory(defaults: mirror).load(account: account), updated, "the share extension sees it too")
        XCTAssertTrue(memory.isFresh(account: account, now: now.addingTimeInterval(60)), "the discovery's date stands")
        XCTAssertNil(memory.refused(account: "bob@example.org", current: nil, service: service, maximumFileSize: 1_000), "per account")

        let other = XMPPUploadService(jid: "files.example.org", maximumFileSize: nil)
        XCTAssertEqual(memory.refused(account: account, current: other, service: service, maximumFileSize: 1_000), other,
                       "a service discovered since stands")
        XCTAssertEqual(memory.refused(account: account, current: updated, service: other, maximumFileSize: 1_000), updated)
        XCTAssertEqual(memory.load(account: account), updated)
    }

    // A file held by a retry stamp is skipped until its wait ends; a newer wait for it replaces the older one.
    @MainActor func testAHeldFileResumesOnceItsLatestWaitEnds() async {
        let gates = SleepGates()
        let holds = UploadHolds(sleep: { await gates.park($0) })
        var resumed: [String] = []
        holds.wait("photo", for: .seconds(42)) { resumed.append("first") }
        holds.wait("photo", for: .seconds(60)) { resumed.append("second") }
        XCTAssertTrue(holds.isWaiting("photo"))
        XCTAssertFalse(holds.isWaiting("other"))
        await gates.waitForParked(2)
        let delays = await gates.delays
        XCTAssertEqual(delays.sorted(), [.seconds(42), .seconds(60)], "each wait sleeps exactly its delay")
        await gates.releaseAll()
        await gates.waitForReleased(2)
        for _ in 0..<100 where resumed.isEmpty { await Task.yield() }
        XCTAssertEqual(resumed, ["second"])
        XCTAssertFalse(holds.isWaiting("photo"))

        let first = UUID(), second = UUID()
        XCTAssertTrue(holds.rediscovers(on: first))
        XCTAssertFalse(holds.rediscovers(on: first), "once per connection")
        XCTAssertTrue(holds.rediscovers(on: second))
    }
}

// Parks every sleep until released, so no test waits on real time.
private actor SleepGates {
    private(set) var delays: [Duration] = []
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = 0
    private var watchers: [(count: Int, released: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func park(_ delay: Duration) async {
        delays.append(delay)
        await withCheckedContinuation { parked.append($0); notify() }
        released += 1
        notify()
    }

    func releaseAll() { parked.forEach { $0.resume() }; parked = [] }

    func waitForParked(_ count: Int) async { await withCheckedContinuation { watchers.append((count, false, $0)); notify() } }
    func waitForReleased(_ count: Int) async { await withCheckedContinuation { watchers.append((count, true, $0)); notify() } }

    private func notify() {
        watchers.removeAll { watcher in
            guard (watcher.released ? released : delays.count) >= watcher.count else { return false }
            watcher.continuation.resume()
            return true
        }
    }
}
