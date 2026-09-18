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
    private var running: Task<Void, Never>?
    private let load: @MainActor (Scope) async -> Void

    init(load: @escaping @MainActor (Scope) async -> Void) { self.load = load }

    /// Returns only after a load that started after this request has finished.
    func request(_ scope: Scope = .all) async {
        dirty.formUnion(scope)
        if let running { await running.value; return }
        let task = Task { [weak self] in
            // No suspension between the last emptiness check and clearing `running`, so a late request is never stranded.
            while let self, !self.dirty.isEmpty {
                let scope = self.dirty
                self.dirty = []
                await self.load(scope)
            }
            self?.running = nil
        }
        running = task
        await task.value
    }
}
