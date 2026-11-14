import Foundation
import MessagingCore

// Prepares one file at a time in the order they came, so a slow video never lets a later photo jump ahead and two
// transcodes never share an extension's memory. Cancelling an item stops its work, which deletes what it wrote.
@MainActor final class AttachmentQueue {
    typealias Work = () async throws -> PreparedAttachment
    typealias Done = @MainActor (Result<PreparedAttachment, any Error>) async -> Void

    private var tail: Task<Void, Never>?
    private var running: (id: UUID, task: Task<PreparedAttachment, any Error>)?
    private var cancelled: Set<UUID> = []
    private var stopped = false

    // `done` is not called for an item cancelled, alone or by `cancelAll`, before its work finished.
    func enqueue(_ id: UUID, _ work: @escaping Work, done: @escaping Done) {
        cancelled.remove(id)
        let previous = tail
        tail = Task {
            await previous?.value
            guard !stopped, !cancelled.contains(id) else { return }
            let task = Task { try await work() }
            running = (id, task)
            let result = await task.result
            running = nil
            guard !stopped, !cancelled.contains(id) else { return }
            await done(result)
        }
    }

    func cancel(_ id: UUID) {
        cancelled.insert(id)
        if running?.id == id { running?.task.cancel() }
    }

    func cancelAll() {
        stopped = true
        running?.task.cancel()
    }

    // Returns once every item enqueued so far has finished, its `done` included, or was dropped.
    func drained() async { await tail?.value }
}
