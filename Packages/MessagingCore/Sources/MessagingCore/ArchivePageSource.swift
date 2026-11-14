import XMPPProtocol

// A walk's pages in order. With `prefetchesPages` the next page's query goes out while the walk processes the current
// one; its results stay unacknowledged until their turn, after the current page's cursor.
final class ArchivePageSource {
    private let operations: ArchiveSyncOperations
    private let room: String?
    private var ahead: (bound: XMPPArchiveBound, task: Task<Result<XMPPArchivePage, any Error>, Never>)?

    init(operations: ArchiveSyncOperations, room: String?) {
        self.operations = operations; self.room = room
    }

    func page(_ bound: XMPPArchiveBound) async throws -> XMPPArchivePage {
        guard let ahead, ahead.bound == bound else {
            await cancel()
            return try await operations.fetchPage(bound, room)
        }
        self.ahead = nil
        return try await withTaskCancellationHandler { await ahead.task.value } onCancel: { ahead.task.cancel() }.get()
    }

    func prefetch(after page: XMPPArchivePage, continuing: Bool) {
        guard operations.prefetchesPages, continuing, let cursor = page.lastID else { return }
        let operations = operations, room = room, bound = XMPPArchiveBound.after(cursor)
        ahead = (bound, Task {
            do { return .success(try await operations.fetchPage(bound, room)) } catch { return .failure(error) }
        })
    }

    // Joined, so the connection's one page query is free again before anything else asks.
    func cancel() async {
        guard let ahead else { return }
        self.ahead = nil
        ahead.task.cancel()
        _ = await ahead.task.value
    }
}
