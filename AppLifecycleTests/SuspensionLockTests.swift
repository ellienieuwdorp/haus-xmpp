import XCTest
import Darwin
import SQLite3
import MessageStore
import MessagingCore
@testable import HausXMPP

// iOS kills an app suspended holding a file lock (0xdead10cc); an idle WAL connection locks the database and its -shm.
// Each test moves a scene away from the front, waits for the last background time to end, and finds no descriptor on
// the store's SQLite files and no transport lock. The host app's model shares the store, so it must park too.
@MainActor final class SuspensionLockTests: XCTestCase {
    private let parkingClock = StorageParking.shared.clock
    private let parkStores = StorageParking.shared.parkStores

    // A fresh model and its scene in front; at the end of the test it returns to the front and the defaults come back.
    private func start() async throws -> AppScene {
        let scene = try await AppScene()
        addTeardownBlock { @MainActor [parkingClock, parkStores] in
            await scene.returnToFront()
            StorageParking.shared.clock = parkingClock
            StorageParking.shared.parkStores = parkStores
        }
        return scene
    }

    // This process's descriptors on the database and its sidecars. POSIX record locks belong to the process, so a file
    // it has no descriptor on holds none of its locks. The transport lock file stays open by design and is probed apart.
    private func sqliteDescriptors(_ database: URL) -> Set<String> {
        guard let resolved = realpath(database.deletingLastPathComponent().path, nil) else { return [] }
        let prefix = String(cString: resolved) + "/"
        free(resolved)
        var found: Set<String> = []
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &path) != -1 {
            let name = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix(prefix + "messages.sqlite"), !name.hasSuffix(".transport-lock") {
                found.insert(String(name.dropFirst(prefix.count)))
            }
        }
        return found
    }

    // flock conflicts between open file descriptions of one process too, so a fresh one sees any store's lease.
    private func transportLockIsFree(_ database: URL) -> Bool {
        let descriptor = open(database.path + ".transport-lock", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }

    // What an extension does to the store meanwhile, through its own connection, closed again at once.
    private func execute(_ sql: String, on database: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return SQLITE_CANTOPEN }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func assertNothingLocked(_ scene: AppScene, _ moment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sqliteDescriptors(scene.database), [], "\(moment): descriptors left on the store", file: file, line: line)
        XCTAssertFalse(MessageStore.processHasOpenConnection, "\(moment): a SQLite connection is still open", file: file, line: line)
        XCTAssertTrue(transportLockIsFree(scene.database), "\(moment): the transport lock is held", file: file, line: line)
    }

    // The launch is applied and storage is still opening when the scene leaves, as when a link opens another app
    // seconds after launch.
    func testBackgroundSecondsAfterLaunchLeavesNoLock() async throws {
        let scene = try await start(), model = scene.model
        let launched = expectation(description: "launch applied")
        let launch = model.lifecycleAtLaunch
        model.lifecycleAtLaunch = { defer { launched.fulfill() }; return launch() }
        let preparing = Task { await model.prepare() }
        await fulfillment(of: [launched], timeout: 10)
        await scene.leave()
        await preparing.value
        await StorageParking.shared.settled()
        assertNothingLocked(scene, "backgrounded while storage opened")
    }

    // An in-app browser handing off to another app: inactive for a while, briefly active, then inactive and away. The
    // departure's background time and the transition's overlap, so storage is never parked while work may run.
    func testInactiveThenBackgroundHandoffLeavesNoLock() async throws {
        let scene = try await start()
        await scene.model.prepare()
        XCTAssertTrue(sqliteDescriptors(scene.database).contains("messages.sqlite"), "an open store is visible to the probe")
        scene.move(to: .inactive)
        await scene.model.lifecycleSettled()
        XCTAssertGreaterThan(StorageParking.shared.holders, 0, "inactive keeps background time")
        XCTAssertTrue(sqliteDescriptors(scene.database).contains("messages.sqlite"), "nothing parks while background time is held")
        scene.move(to: .active)
        await scene.model.lifecycleSettled()
        await scene.leave()
        assertNothingLocked(scene, "after the hand-off")
    }

    // Work woken in the background (a share queued by the extension, a finished upload) reopens storage under its own
    // background time and parks it again before that time ends. Without background time a store refuses.
    func testBackgroundWorkReparksBeforeItsTaskEnds() async throws {
        let scene = try await start(), model = scene.model, database = scene.database
        await model.prepare()
        await scene.leave()
        assertNothingLocked(scene, "parked")

        let queued = "queued-\(UUID().uuidString.lowercased())@example.org"
        XCTAssertEqual(execute("INSERT INTO chats(account_id,id,title) VALUES('\(model.accountID)','\(queued)','Queued')", on: database), SQLITE_OK)
        addTeardownBlock { @MainActor [self] in _ = execute("DELETE FROM chats WHERE id='\(queued)'", on: database) }

        await model.outboxRingRang()
        await StorageParking.shared.settled()
        XCTAssertTrue(model.chats.contains { $0.id == queued }, "the ring's refresh read the reopened store")
        assertNothingLocked(scene, "after the outbox ring")

        await model.uploadFinished()
        await StorageParking.shared.settled()
        assertNothingLocked(scene, "after a finished upload")

        let other = try MessageStore(url: database)
        try await other.park()
        do {
            _ = try await other.chats(accountID: model.accountID)
            XCTFail("a parked store reopened with no background time")
        } catch { XCTAssertEqual(error as? MessageStoreError, .suspended) }
        try await other.close()
    }

    // Background time that begins and ends while a park runs may reopen a store the park already closed; the park
    // then starts over instead of ending the time with that store open.
    func testWorkDuringAParkIsParkedBeforeTheTimeEnds() async throws {
        let scene = try await start(), model = scene.model
        await model.prepare()
        let parkAll = parkStores
        var overlapped = false
        StorageParking.shared.parkStores = {
            let parked = await parkAll()
            if !overlapped { overlapped = true; await model.outboxRingRang() }
            return parked
        }
        await scene.leave()
        XCTAssertTrue(overlapped)
        XCTAssertEqual(StorageParking.shared.kept, 0, "the background time ended once everything parked")
        assertNothingLocked(scene, "after a park overlapped by other work")
    }

    // A store that refuses, or a park that outlasts its deadline, keeps the background time: iOS then ends the process
    // rather than suspending it holding SQLite locks. New background time or the front ends the kept time.
    func testAParkThatFailsOrMissesItsDeadlineKeepsTheBackgroundTime() async throws {
        let scene = try await start()
        await scene.model.prepare()
        let parkAll = parkStores
        StorageParking.shared.parkStores = { _ = await parkAll(); return false }
        await scene.leave()
        XCTAssertEqual(StorageParking.shared.kept, 1, "a refused park keeps the transition's background time")
        XCTAssertFalse(MessageStore.reopeningAllowed)
        scene.move(to: .inactive)
        XCTAssertEqual(StorageParking.shared.kept, 0, "new background time ends it")
        scene.move(to: .active)
        await scene.model.lifecycleSettled()

        let clock = ManualClock()
        StorageParking.shared.clock = clock
        let asked = expectation(description: "the park is under way")
        StorageParking.shared.parkStores = { asked.fulfill(); await clock.stuck(); return await parkAll() }
        scene.move(to: .inactive)
        scene.move(to: .background)
        await scene.model.lifecycleSettled()
        await fulfillment(of: [asked, clock.sleeping], timeout: 10)
        XCTAssertEqual(StorageParking.shared.kept, 1, "nothing ends while the park runs")
        clock.advance(by: StorageParking.shared.deadline)
        await StorageParking.shared.settled()
        XCTAssertEqual(StorageParking.shared.kept, 1, "the deadline passed: the time is kept")
        clock.release()
    }
}

// A model and its scene, moved through phases as iOS moves the app's one scene.
@MainActor private final class AppScene {
    let model = AppModel()
    let database: URL
    private let lifecycle: SceneLifecycle
    private var phase = SceneLifecycleDriver.Phase.active

    init() async throws {
        lifecycle = SceneLifecycle(model: model)
        let directory = try await SharedStorage.directory(testSessionID: XCTUnwrap(model.testSessionID), migrate: false)
        database = directory.appending(path: "messages.sqlite")
    }

    func move(to next: SceneLifecycleDriver.Phase) {
        lifecycle.phaseChanged(from: phase, to: next)
        phase = next
    }

    // Away from the front for good: every lifecycle transition finished and the last background time ended.
    func leave() async {
        move(to: .inactive)
        move(to: .background)
        await model.lifecycleSettled()
        await StorageParking.shared.settled()
    }

    func returnToFront() async {
        if phase == .background { move(to: .inactive) }
        if phase == .inactive { move(to: .active) }
        await model.lifecycleSettled()
        await StorageParking.shared.settled()
    }
}

// Moves only when the test moves it; `sleeping` is fulfilled once something sleeps on it. `lock` guards all state.
private final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    let sleeping: XCTestExpectation = {
        let sleeping = XCTestExpectation(description: "a sleeper")
        sleeping.assertForOverFulfill = false
        return sleeping
    }()
    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [(deadline: Instant, continuation: CheckedContinuation<Void, Never>)] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        await withCheckedContinuation { continuation in
            let due = lock.withLock {
                if deadline <= current { return true }
                sleepers.append((deadline, continuation))
                return false
            }
            if due { continuation.resume() } else { sleeping.fulfill() }
        }
        try Task.checkCancellation()
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    // Suspends until `release`.
    func stuck() async { await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } } }

    func release() {
        let waiting = lock.withLock { defer { held = [] }; return held }
        for continuation in waiting { continuation.resume() }
    }
}
