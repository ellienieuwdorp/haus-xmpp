import Foundation
import MessageStore

/// One in-process sender. The database owns messages and attempt identity, never the socket.
/// No SM acknowledgment or recipient delivery guarantee is implied by a completed transport write.
public actor OutboxSender {
    private let store: MessageStore
    private var running = false

    public init(store: MessageStore) { self.store = store }

    /// Caller cancels on session replacement. Never automatically replays uncertain attempts.
    public func drain(
        accountID: String,
        send: @Sendable (StoredMessage) async throws -> Void,
        didChange: @Sendable () async -> Void = {}
    ) async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            guard let attempt = try await store.claimNextOutgoing(accountID: accountID) else { return }
            await didChange()
            if Task.isCancelled {
                try await store.releaseUnsentSubmission(attempt)
                await didChange()
                return
            }
            do {
                try await send(attempt.message)
            } catch {
                // The write may have reached the peer even when the completion reports failure.
                try await store.finishOutgoingSubmission(attempt)
                await didChange()
                throw error
            }
            try await store.finishOutgoingSubmission(attempt)
            await didChange()
        }
    }
}
