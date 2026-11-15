import MessageStore
import OSLog

// iOS ends an app suspended holding a file lock in the App Group (0xdead10cc), and an idle WAL connection locks the
// database and its -shm. So the last background time away from the front ends only once every store has closed SQLite;
// a refused or late park is retried or awaited while background time lasts, and keeps the time. The Mac never parks.
@MainActor final class StorageParking {
    static let shared = StorageParking()
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "lifecycle")
    let deadline: Duration = .seconds(2)
    let retryInterval: Duration = .milliseconds(500)
    let maximumAttempts = 10
    var clock: any Clock<Duration> = ContinuousClock()
    var remaining: @MainActor () -> Duration = { PlatformApplication.backgroundTimeRemaining ?? .zero }
    private(set) var holders = 0
    var kept: Int { waiting.count }
    private var inFront = true
    var parkStores: @MainActor () async -> Bool = { await MessageStore.parkAll() }
    private var waiting: [@MainActor () -> Void] = []
    private var parking: Task<Void, Never>?
    private var reopenings = 0

    func sceneChanged(active: Bool) {
        inFront = active
        if active { resume() }
    }

    // Refused time still counts, so its release balances, but cannot replace time a failed park is keeping.
    func hold(granted: Bool) {
        holders += 1
        allowReopening()
        if granted { endWaiting() }
    }

    // For a move to the background that ended no background time: parks unless something still holds time.
    func parkIfIdle() {
        guard holders == 0, !inFront, parking == nil else { return }
        parking = Task { await park() }
    }

    // `finish` ends the background time, at once unless it is the last held away from the front.
    func release(_ finish: @escaping @MainActor () -> Void) {
        holders -= 1
        guard holders == 0, !inFront else { return finish() }
        waiting.append(finish)
        if parking == nil { parking = Task { await park() } }
    }

    func settled() async {
        while let parking { await parking.value }
    }

    // Storage may reopen, and background time a park was holding back ends: the front or newer time covers the work.
    private func resume() {
        allowReopening()
        endWaiting()
    }

    private func allowReopening() {
        reopenings += 1
        MessageStore.reopeningAllowed = true
    }

    private func endWaiting() {
        let finished = waiting
        waiting = []
        for finish in finished { finish() }
    }

    private func park() async {
        defer { parking = nil }
        var failures = 0
        while true {
            // Background time still held, or the front, keeps storage open; its own end parks again.
            guard holders == 0, !inFront else { return resume() }
            let started = reopenings
            MessageStore.reopeningAllowed = false
            let parked = await parkWithinDeadline()
            guard holders == 0, !inFront else { return resume() }
            // Background time begun meanwhile may have reopened a store and ended again: then parking starts over.
            guard started == reopenings else { continue }
            if parked, !MessageStore.processHasOpenConnection {
                Self.log.notice("storage parked")
                return endWaiting()
            }
            failures += 1
            guard failures < maximumAttempts, remaining() > retryInterval + deadline else {
                return Self.log.fault("storage not parked or a SQLite connection still open: background time kept")
            }
            Self.log.error("storage not parked yet: trying again")
            guard (try? await clock.sleep(for: retryInterval)) != nil else { return }
        }
    }

    // A park still running at the deadline is awaited while background time remains, so the caller checks again once it
    // completes instead of keeping the time until iOS ends the process.
    private func parkWithinDeadline() async -> Bool {
        let parkStores = self.parkStores
        let work = Task { @MainActor in await parkStores() }
        if let parked = await outcome(of: work, within: deadline) { return parked }
        Self.log.fault("storage not parked within its deadline: background time kept until it is")
        return await outcome(of: work, within: remaining()) ?? false
    }

    private func outcome(of work: Task<Bool, Never>, within limit: Duration) async -> Bool? {
        let race = ParkingRace(), clock = self.clock
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            let timer = Task { @MainActor in
                guard (try? await clock.sleep(for: limit)) != nil else { return }
                race.finish(nil)
            }
            Task { @MainActor in
                let parked = await work.value
                timer.cancel()
                race.finish(parked)
            }
        }
    }
}

@MainActor private final class ParkingRace {
    var continuation: CheckedContinuation<Bool?, Never>?
    func finish(_ parked: Bool?) {
        continuation?.resume(returning: parked)
        continuation = nil
    }
}
