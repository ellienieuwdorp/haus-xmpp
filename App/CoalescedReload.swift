import Foundation

/// One load at a time. Requests made while a load runs are unioned into a single follow-up load,
/// so a burst of N requests costs at most two loads.
@MainActor final class CoalescedReload {
    struct Scope: OptionSet, Sendable {
        let rawValue: Int
        static let chats = Scope(rawValue: 1), openChat = Scope(rawValue: 2)
        static let all: Scope = [.chats, .openChat]
    }

    private var dirty: Scope = []
    private var started = 0
    private var isRunning = false
    private var waiters: [(load: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let load: @MainActor (Scope) async -> Void

    init(load: @escaping @MainActor (Scope) async -> Void) { self.load = load }

    /// Returns once the first load that started after this request has finished, not when the whole burst has drained.
    func request(_ scope: Scope = .all) async {
        dirty.formUnion(scope)
        let next = started + 1
        if !isRunning { isRunning = true; Task { await drain() } }
        await withCheckedContinuation { waiters.append((next, $0)) }
    }

    private func drain() async {
        // No suspension between the last emptiness check and clearing `isRunning`, so a late request is never stranded.
        while !dirty.isEmpty {
            let scope = dirty
            dirty = []
            started += 1
            await load(scope)
            let done = waiters.filter { $0.load <= started }
            waiters.removeAll { $0.load <= started }
            for waiter in done { waiter.continuation.resume() }
        }
        isRunning = false
    }
}
