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
        messageIDs: Set<String>? = nil,
        send: @Sendable (StoredMessage) async throws -> Void,
        didChange: @Sendable () async -> Void = {}
    ) async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            guard let attempt = try await store.claimNextOutgoing(accountID: accountID, messageIDs: messageIDs) else { return }
            await didChange()
            if Task.isCancelled {
                try await store.releaseUnsentSubmission(attempt)
                await didChange()
                return
            }
            do {
                try await send(attempt.message)
            } catch OutboxSendFailure.notAttempted {
                // Only an explicit pre-transport rejection can safely return this claim to queue.
                try await store.releaseUnsentSubmission(attempt)
                await didChange()
                throw OutboxSendFailure.notAttempted
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

/// A caller may use this only if it has not invoked the transport at all (for example, a final
/// device-trust check failed). Socket failures must never be translated into this error.
public enum OutboxSendFailure: Error, Sendable { case notAttempted }
