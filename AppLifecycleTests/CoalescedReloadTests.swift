import XCTest
@testable import HausXMPP

@MainActor
final class CoalescedReloadTests: XCTestCase {
    /// A load that parks until the test releases it, so requests can be made "during" a load.
    @MainActor private final class Gate {
        var scopes: [CoalescedReload.Scope] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func load(_ scope: CoalescedReload.Scope) async {
            scopes.append(scope)
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() { waiting.removeFirst().resume() }
        /// Yields until `count` loads have started.
        func started(_ count: Int) async { while scopes.count < count { await Task.yield() } }
    }

    func testLoneRequestLoadsOnce() async {
        let gate = Gate()
        let reload = CoalescedReload { await gate.load($0) }
        let request = Task { await reload.request(.chats) }
        await gate.started(1)
        gate.release()
        await request.value
        XCTAssertEqual(gate.scopes, [.chats])
    }

    func testBurstDuringLoadCostsTwoLoadsAndUnionsScopes() async {
        let gate = Gate()
        let reload = CoalescedReload { await gate.load($0) }
        let first = Task { await reload.request(.chats) }
        await gate.started(1)
        var finished = 0
        let burst = (0..<200).map { index in
            Task { await reload.request(index.isMultiple(of: 2) ? .chats : .openChat); finished += 1 }
        }
        for _ in 0..<50 { await Task.yield() }
        gate.release()
        // The first caller is done after its own load, not after the follow-up the burst caused.
        await first.value
        await gate.started(2)
        // The load these callers joined predates their request, so none may have returned yet.
        XCTAssertEqual(finished, 0)
        gate.release()
        for task in burst { await task.value }
        XCTAssertEqual(finished, 200)
        XCTAssertEqual(gate.scopes, [.chats, .all])
    }

    func testRequestAfterIdleStartsAgain() async {
        let gate = Gate()
        let reload = CoalescedReload { await gate.load($0) }
        for expected in 1...2 {
            let request = Task { await reload.request(.openChat) }
            await gate.started(expected)
            gate.release()
            await request.value
        }
        XCTAssertEqual(gate.scopes, [.openChat, .openChat])
    }
}
