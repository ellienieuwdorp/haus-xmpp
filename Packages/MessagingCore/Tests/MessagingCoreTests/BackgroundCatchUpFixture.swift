import Foundation
import MessageStore
@testable import XMPPProtocol
@testable import MessagingCore

actor BackgroundProbe {
    var events: [String] = []
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func record(_ value: String) { events.append(value) }
    func begin() { started = true; waiter?.resume(); waiter = nil }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func hasStarted() -> Bool { started }
}

enum RoomTrouble: Sendable, CustomStringConvertible {
    // The room never answers its membership read, as an unreachable MUC component holds an IQ.
    case stalls
    // The connection is lost during the room walk.
    case losesConnection
    // The room's page cannot be processed.
    case breaks
    enum Unreadable: Error { case page }
    var description: String {
        switch self { case .stalls: "stalls"; case .losesConnection: "losesConnection"; case .breaks: "breaks" }
    }
}

// One run through `BackgroundCatchUp` with the real archive walk, store and presenter: only the server is fake. The
// own archive holds `ownMessages` new direct messages (from two contacts at most); one room follows, which holds one
// new message when `roomMessage` or `trouble` is `.breaks`, or misbehaves as `trouble` says.
struct CatchUpFixture {
    let store: MessageStore
    let ownMessages: Int, roomMessage: Bool, trouble: RoomTrouble?
    let posting: TracingPosting
    let progress = NotificationRunProgress()
    let trace = BackgroundProbe()
    // Times the budget, the rooms' time after a post and the presenter's limits.
    let clock = TestClock()
    private let account = "alice@example.org", room = "room@rooms.example.org"

    init(store: MessageStore, ownMessages: Int, roomMessage: Bool, trouble: RoomTrouble?) async throws {
        self.store = store; self.ownMessages = ownMessages; self.roomMessage = roomMessage; self.trouble = trouble
        posting = TracingPosting(trace: trace, clock: clock)
        // Both archives were walked before, so this run's entries are new rather than history.
        _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "own-0")
        _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: room, expectedRevision: nil, cursor: "room-0")
    }

    private static func page(_ ids: [String]) -> XMPPArchivePage {
        XMPPArchivePage(messages: ids.map { .init(archiveID: $0, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil) },
                        complete: true, firstID: ids.first, lastID: ids.last, handledTokens: [])
    }

    // `progress` replaces the fixture's own (a coordinator's run).
    func run(budget: Duration, roomsAfterPost: Duration = .seconds(5), progress: NotificationRunProgress? = nil) async throws {
        let (store, account, room, trace, trouble) = (store, account, room, trace, trouble)
        let (ownMessages, roomMessage, progress, posting, clock) = (ownMessages, roomMessage, progress ?? self.progress, posting, clock)
        let operationsFor: @Sendable (@escaping @Sendable (ArchiveSyncProgress) async -> Void,
                                      @escaping @Sendable (Bool, Int) async throws -> Void) -> ArchiveSyncOperations = { walkProgress, walked in
            ArchiveSyncOperations(
                knownRooms: { [room] },
                refreshRoom: { _ in
                    switch trouble {
                    case .stalls:
                        await trace.begin()
                        await untilCancelled()
                        throw CancellationError()
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
            consume: {
                await untilCancelled()
                throw CancellationError()
            },
            stop: {}
        )
        catchUp.roomsAfterPost = roomsAfterPost
        try await catchUp.run(store: store, deadline: clock.now + budget, clock: clock, progress: progress, presentation: { store, stage in
            try await NotificationPresenter(posting: posting, clock: clock).present(store: store, accountID: account, progress: progress, stage: stage)
        })
    }
}

// `FakePosting` that also notes each add in the run's trace, and can reject one add once.
actor TracingPosting: NotificationPosting {
    enum Failure: Error { case rejected }
    let trace: BackgroundProbe
    let clock: TestClock
    private(set) var added: [PlannedNotification] = []
    private(set) var addedAt: [Duration] = []
    private var failingAt: Int?, firstDelay: Duration?
    init(trace: BackgroundProbe, clock: TestClock) { self.trace = trace; self.clock = clock }
    func failOnce(at index: Int) { failingAt = index }
    // The first add takes `delay` and, like the system's, is not stopped by cancellation.
    func delayFirstAdd(by delay: Duration) { firstDelay = delay }
    func add(_ request: PlannedNotification) async throws {
        if failingAt == added.count { failingAt = nil; throw Failure.rejected }
        if let delay = firstDelay {
            firstDelay = nil
            await ignoringCancellation(for: delay, on: clock)
        }
        added.append(request); addedAt.append(clock.elapsed); await trace.record("post")
    }
    func deliveredNotifications() -> [DeliveredNotification] { [] }
    func removeDelivered(identifiers: [String]) {}
}
