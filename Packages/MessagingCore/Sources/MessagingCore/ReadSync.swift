import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// XEP-0490 Message Displayed Synchronization. Pull after bind and archive catch-up, so the ids resolve. Pointers
/// only move forward; unknown ids are ignored. Only the app pushes, because only the app reads.
public struct ReadSync: Sendable {
    private let store: MessageStore
    public init(store: MessageStore) { self.store = store }

    /// Best effort: only a storage failure or cancellation propagates. Returns true when any chat's pointer moved.
    @discardableResult
    public func pull(account: String, client: XMPPClient, encryption: OMEMOService, timeout: Duration = XMPPClient.iqTimeout) async throws -> Bool {
        try await pull(account: account, encryption: encryption, fetch: { try await client.fetchDisplayedSync(timeout: timeout) })
    }

    func pull(account: String, encryption: OMEMOService, fetch: @Sendable () async throws -> [XMPPDisplayedItem]) async throws -> Bool {
        try await fetched(account: account, encryption: encryption, fetch: fetch)()
    }

    // The fetch alone, which may run beside an archive walk; what it returns applies the pointers once the walk
    // committed, so the ids resolve. A failed fetch applies nothing.
    func fetched(account: String, encryption: OMEMOService,
                 fetch: @Sendable () async throws -> [XMPPDisplayedItem]) async throws -> @Sendable () async throws -> Bool {
        let items: [XMPPDisplayedItem]
        do { items = try await fetch() }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return { false } }
        return { try await encryption.receiveDisplayedSync(account: account, items: items) }
    }

    /// Stops at the first failure; the rest stays pending. Returns the number published.
    @discardableResult
    public func push(account: String, client: XMPPClient) async throws -> Int {
        try await push(account: account, publish: { try await client.publishDisplayedSync($0) })
    }

    func push(account: String, publish: @Sendable (XMPPDisplayedItem) async throws -> Void) async throws -> Int {
        var published = 0
        for publication in try await store.pendingDisplayedSyncPublications(accountID: account) {
            try Task.checkCancellation()
            try await publish(XMPPDisplayedItem(chat: publication.chatID, stanzaID: publication.stanzaID, by: publication.by))
            try await store.finishDisplayedSyncPublication(accountID: account, publication)
            published += 1
        }
        return published
    }
}

// The run's first read-state fetch, started as the stream comes online so it costs the direct messages no round trip
// of their own. Applying it still waits for the own archive's commit. Taken once; a take while it is in flight waits.
actor ReadStatePrefetch {
    typealias Apply = @Sendable () async throws -> Void
    private enum State { case idle, fetching, fetched(Result<Apply?, any Error>), taken }
    private var state = State.idle
    private var waiters: [UUID: CheckedContinuation<Apply?, any Error>] = [:]

    func start() { if case .idle = state { state = .fetching } }

    func fetch(_ operation: @Sendable () async throws -> Apply?) async {
        let result: Result<Apply?, any Error>
        do { result = .success(try await operation()) } catch { result = .failure(error) }
        guard case .fetching = state else { return }
        guard let (id, waiter) = waiters.first else { state = .fetched(result); return }
        waiters.removeValue(forKey: id)
        state = .taken
        waiter.resume(with: result)
        for other in waiters.values { other.resume(returning: nil) }
        waiters = [:]
    }

    // Nil when nothing was fetched ahead or it was already taken. Throws CancellationError when cancelled first.
    func take() async throws -> Apply? {
        switch state {
        case .idle, .taken: return nil
        case .fetched(let result):
            state = .taken
            return try result.get()
        case .fetching:
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Apply?, any Error>) in
                    if Task.isCancelled { waiter.resume(throwing: CancellationError()) } else { waiters[id] = waiter }
                }
            } onCancel: { Task { await self.stopWaiting(id) } }
        }
    }

    private func stopWaiting(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
