import Foundation
import Testing
@testable import MessagingCore

// The quiesce every lease holder runs before release: each user of the transport and of crypto (the event consumer,
// setup, the outbox drain, a UI mutation counted by the gate) ends, and the disconnect is joined, before the lease
// goes; nothing new starts once it began; and at its deadline it hard-closes without unlocking under live work.
@MainActor struct TransportQuiesceTests {
    @MainActor private final class Latch {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        // Deliberately deaf to cancellation, like a user stuck in a store or crypto call.
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let due = waiters
            waiters = []
            due.forEach { $0.resume() }
        }
    }

    @MainActor private final class Fixture {
        let gate = TransportGate()
        var timeline: [String] = []
        var leaseHeld = true
        var latches: [String: Latch] = [:]

        func latch(_ name: String) -> Latch {
            if let latch = latches[name] { return latch }
            let latch = Latch()
            latches[name] = latch
            return latch
        }

        // A user of the transport blocked until its latch opens.
        func user(_ name: String) -> TransportQuiesce.Work {
            let latch = latch(name)
            return TransportQuiesce.Work(name, Task { await latch.wait(); self.timeline.append("\(name) ended") })
        }

        // A UI crypto mutation counted by the gate, begun before the quiesce.
        func mutation(_ name: String) -> Bool {
            guard gate.beginOperation() else { return false }
            let latch = latch(name)
            Task {
                await latch.wait()
                self.timeline.append("\(name) ended")
                self.gate.endOperation()
            }
            return true
        }

        func release() -> Bool {
            if leaseHeld { timeline.append("release") }
            leaseHeld = false
            return true
        }

        func quiesce(_ work: [TransportQuiesce.Work], clock: TestClock = TestClock(), deadline: Duration? = nil,
                     abort: @escaping @MainActor () -> Void = {}, release: (@MainActor () -> Bool)? = nil) -> TransportQuiesce {
            TransportQuiesce(gate: gate, work: work, abort: abort, release: { release?() ?? self.release() },
                             clock: EngineClock(clock), deadline: deadline)
        }
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func theLeaseGoesOnlyAfterEveryUserEndedAndTheDisconnectJoined() async {
        let fixture = Fixture()
        #expect(fixture.mutation("trust change"))
        let work = [fixture.user("disconnect"), fixture.user("event consumer"), fixture.user("setup"), fixture.user("outbox")]
        let run = Task { await fixture.quiesce(work).run() }
        await settle()
        for name in ["setup", "disconnect", "outbox", "event consumer"] {
            fixture.latch(name).open()
            await settle()
            #expect(!fixture.timeline.contains("release"), "released while a user still ran")
        }
        fixture.latch("trust change").open()
        let outcome = await run.value
        #expect(outcome == TransportQuiesce.Outcome(released: true))
        #expect(fixture.timeline.last == "release")
        #expect(Set(fixture.timeline.dropLast()) == ["disconnect ended", "event consumer ended", "setup ended", "outbox ended", "trust change ended"])
        #expect(!fixture.leaseHeld)
    }

    @Test func nothingNewBeginsOnceTheQuiesceStartedNorJustBeforeTheRelease() async {
        let fixture = Fixture()
        var refusedAtRelease = false
        let run = Task {
            await fixture.quiesce([fixture.user("setup")], release: {
                refusedAtRelease = !fixture.gate.beginOperation()
                return fixture.release()
            }).run()
        }
        await settle()
        #expect(!fixture.mutation("late trust change"), "begun right after the quiesce started")
        fixture.latch("setup").open()
        #expect(await run.value.released)
        #expect(refusedAtRelease)
        #expect(fixture.gate.closed && fixture.gate.operations == 0, "the gate stays closed for its owner to open")
    }

    @Test func anAcquisitionInFlightIsJoinedThenReleased() async {
        let fixture = Fixture()
        fixture.leaseHeld = false
        fixture.gate.acquiring = true
        let acquired = fixture.latch("acquire")
        Task {
            await acquired.wait()
            fixture.leaseHeld = true
            fixture.timeline.append("acquired")
            fixture.gate.acquiring = false
        }
        let run = Task { await fixture.quiesce([fixture.user("disconnect")]).run() }
        fixture.latch("disconnect").open()
        await settle()
        #expect(fixture.timeline == ["disconnect ended"], "nothing released before the acquisition returned")
        acquired.open()
        #expect(await run.value.released)
        #expect(fixture.timeline == ["disconnect ended", "acquired", "release"])
        #expect(!fixture.leaseHeld)
    }

    @Test func atTheDeadlineItHardClosesAndNeverReleasesUnderLiveWork() async throws {
        let fixture = Fixture()
        let clock = TestClock()
        // The hard close cancels the socket, which ends the farewell's wait; the setup is stuck in a call that never
        // returns.
        let disconnect = fixture.latch("disconnect")
        let quiesce = fixture.quiesce([fixture.user("disconnect"), fixture.user("setup")], clock: clock, deadline: .seconds(5),
                                      abort: { fixture.timeline.append("abort"); disconnect.open() })
        let run = Task { await quiesce.run() }
        try await clock.sleeper(until: .seconds(5))
        clock.advance(by: .seconds(5))
        try await clock.sleeper(until: .seconds(6))
        #expect(fixture.timeline == ["abort", "disconnect ended"])
        clock.advance(by: .seconds(1))
        let outcome = await run.value
        #expect(outcome == TransportQuiesce.Outcome(hardClosed: true, stuck: ["setup"], released: false))
        #expect(!fixture.timeline.contains("release") && fixture.leaseHeld)
    }

    @Test func stuckOutsideWorkIsNamedFromTheGate() async throws {
        let fixture = Fixture()
        let clock = TestClock()
        #expect(fixture.mutation("trust change"))
        let run = Task { await fixture.quiesce([], clock: clock, deadline: .seconds(2)).run() }
        try await clock.sleeper(until: .seconds(2))
        clock.advance(by: .seconds(2))
        try await clock.sleeper(until: .seconds(3))
        clock.advance(by: .seconds(1))
        let outcome = await run.value
        #expect(outcome.stuck == ["1 crypto operation(s)"] && !outcome.released && fixture.leaseHeld)
        fixture.latch("trust change").open()
    }
}
