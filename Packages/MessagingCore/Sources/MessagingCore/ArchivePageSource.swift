import Foundation
import XMPPProtocol

// Pages in archive order. A forward walk longer than a page also pages back from the newest entry, at most `heldLimit`
// entries, and takes those pages once it reaches one of their RSM IDs. Their results are acknowledged on arrival: the
// cursor refetches them if the walk stops, and held tokens would stall the handled count (Prosody 500, ejabberd 5,000).
final class ArchivePageSource {
    private enum Event {
        case newer(after: String, Result<XMPPArchivePage, any Error>)
        case older(Result<XMPPArchivePage, any Error>)
    }

    static let heldLimit = 500

    private let operations: ArchiveSyncOperations
    private let room: String?
    private var position: [String: Int] = [:]
    private var last: String?
    private var newer: [String: XMPPArchivePage] = [:]
    private var asked: Set<String> = []
    private var failure: (after: String, error: any Error)?
    // Oldest first, each followed directly by the next.
    private var older: [XMPPArchivePage] = []
    private var olderState = OlderState.idle
    private var olderFollows: String?
    private var pageSize = 50
    private var owed: [XMPPInboundToken] = []
    private var arrived: [XMPPInboundToken] = []
    private var running: [Int: Task<Event, Never>] = [:]
    private var serial = 0
    private let signals: AsyncStream<Int>
    private let signal: AsyncStream<Int>.Continuation
    private var waiter: AsyncStream<Int>.Iterator

    private enum OlderState { case idle, asking, waiting, done }

    init(operations: ArchiveSyncOperations, room: String?) {
        self.operations = operations; self.room = room
        (signals, signal) = AsyncStream.makeStream()
        waiter = signals.makeAsyncIterator()
    }

    deinit { signal.finish() }

    func page(_ bound: XMPPArchiveBound) async throws -> XMPPArchivePage {
        guard case .after(let id?) = bound else {
            await reset()
            let page = try await operations.fetchPage(bound, room)
            return page.owing(page.handledTokens + drain())
        }
        if last != id { await reset(); position = [id: 0]; last = id }
        while true {
            try Task.checkCancellation()
            if let page = try usable() {
                guard page.complete else { return page.owing(page.handledTokens + owedNow()) }
                // The walk ends with this page, so it owes every result fetched ahead as well.
                olderState = .done
                await join(cancelling: false)
                return page.owing(page.handledTokens + drain())
            }
            extendOlder()
            if !asked.contains(id), !askedFromBehind(), roomToAsk() || running.isEmpty { ask(after: id) }
            try await awaitEvent()
            if !arrived.isEmpty {
                let tokens = arrived
                arrived = []
                try await operations.acknowledge(tokens)
            }
        }
    }

    // Before the walk processes `page`; `forward` when its next page holds newer entries.
    func handed(_ page: XMPPArchivePage, continuing: Bool, forward: Bool) {
        if last == nil, let first = page.firstID { position = [first: 0] }
        for entry in page.messages where position[entry.archiveID] == nil { position[entry.archiveID] = position.count }
        if let end = page.lastID { last = end }
        pageSize = max(pageSize, page.messages.count)
        guard operations.prefetchesPages, continuing, let end = page.lastID else { return }
        if forward, !page.complete, operations.pagesFromNewest, olderState == .idle { olderState = .waiting; extendOlder() }
        if meets() { stopOlder() }
        if olderFollows == end, !older.isEmpty { return }
        if !meets(), !asked.contains(end), newer[end] == nil, !askedFromBehind(), roomToAsk() { ask(after: end) }
    }

    // The page after the newest held one says whether anything was archived since.
    private func stopOlder() {
        guard olderState != .done else { return }
        olderState = .done
        askPastOlder()
    }

    private func askPastOlder() {
        guard let end = older.last?.lastID, !asked.contains(end), newer[end] == nil, roomToAsk() else { return }
        ask(after: end)
    }

    // Joins every query, freeing the connection's archive queries. The tokens returned are owed nothing: the cursor
    // still precedes every entry the walk did not process.
    func cancel() async -> [XMPPInboundToken] {
        olderState = .done
        await join(cancelling: true)
        return drain()
    }

    // Joined rather than cancelled: cancelling a query part of whose results arrived closes the stream.
    private func reset() async {
        olderState = .done
        await join(cancelling: false)
        owed = drain()
        position = [:]; last = nil; olderState = .idle
    }

    private func owedNow() -> [XMPPInboundToken] {
        defer { owed = [] }
        return owed
    }

    private func drain() -> [XMPPInboundToken] {
        for page in newer.values { owed += page.handledTokens }
        owed += arrived
        newer = [:]; older = []; arrived = []; failure = nil; olderFollows = nil
        return owedNow()
    }

    // What follows the walk's last entry, from a page that holds it or starts right after it.
    private func usable() throws -> XMPPArchivePage? {
        guard let last else { return nil }
        if let failure, failure.after == last { self.failure = nil; throw failure.error }
        if let page = newer.removeValue(forKey: last) { return page }
        if let page = takeOlder(after: last) { return page }
        for key in newer.keys.filter({ position[$0] != nil }).sorted(by: { position[$0, default: 0] > position[$1, default: 0] }) {
            guard let page = newer.removeValue(forKey: key) else { continue }
            if let rest = remainder(of: page, after: last, complete: page.complete), !rest.messages.isEmpty || rest.complete { return rest }
            owed += page.handledTokens
        }
        return nil
    }

    // From the held page holding the walk's last entry on; the newest says nothing about what was archived since.
    private func takeOlder(after last: String) -> XMPPArchivePage? {
        if olderFollows == last, !older.isEmpty {
            let page = older.removeFirst()
            guard page.messages.allSatisfy({ position[$0.archiveID] == nil }) else { return abandonOlder(also: page) }
            olderFollows = page.lastID
            return page.entries(after: nil, complete: false)
        }
        guard let index = older.firstIndex(where: { page in page.messages.contains { $0.archiveID == last } }) else { return nil }
        for page in older[..<index] {
            guard page.messages.allSatisfy({ position[$0.archiveID] != nil }) else { return abandonOlder() }
            owed += page.handledTokens
        }
        let page = older[index]
        older.removeFirst(index + 1)
        guard let rest = remainder(of: page, after: last, complete: false) else { return abandonOlder(also: page) }
        olderFollows = page.lastID
        guard rest.messages.isEmpty else { return rest }
        owed += rest.handledTokens
        return takeOlder(after: last)
    }

    // Entries the walk handed out, then entries it did not: anything else means the archive changed under the walk or
    // its server disagrees with itself, and only the walk's own next query counts.
    private func remainder(of page: XMPPArchivePage, after last: String, complete: Bool) -> XMPPArchivePage? {
        guard let rest = page.entries(after: last, complete: complete),
              page.messages.prefix(while: { $0.archiveID != last }).allSatisfy({ position[$0.archiveID] != nil }),
              rest.messages.allSatisfy({ position[$0.archiveID] == nil }) else { return nil }
        return rest
    }

    private func abandonOlder(also page: XMPPArchivePage? = nil) -> XMPPArchivePage? {
        if let page { owed += page.handledTokens }
        for page in older { owed += page.handledTokens }
        older = []
        olderState = .done
        return nil
    }

    private func roomToAsk() -> Bool {
        asked.count + (olderState == .asking ? 1 : 0) < XMPPClient.archiveWalkQueryLimit
    }

    // A forward query out from a handed-out entry other than the last reaches past the last: both pages hold as many
    // entries, and the last one lies within the page that handed out the other.
    private func askedFromBehind() -> Bool {
        asked.contains { $0 != last && position[$0] != nil }
    }

    private func meets() -> Bool {
        older.contains { page in page.messages.contains { position[$0.archiveID] != nil } }
    }

    private func extendOlder() {
        guard olderState == .waiting, roomToAsk() else { return }
        let held = older.reduce(0) { $0 + $1.messages.count } + newer.values.reduce(0) { $0 + $1.messages.count }
        guard !meets(), held + pageSize <= Self.heldLimit else { return stopOlder() }
        let before = older.first?.firstID
        olderState = .asking
        let operations = operations, room = room
        spawn {
            do { return .older(.success(try await operations.fetchPage(.before(before), room))) } catch { return .older(.failure(error)) }
        }
    }

    private func receive(_ event: Event) {
        switch event {
        case .newer(let key, .success(let page)):
            asked.remove(key)
            newer[key] = page
        case .newer(let key, .failure(let error)):
            asked.remove(key)
            if key == last { failure = (key, error) }
        case .older(.success(let page)):
            arrived += page.handledTokens
            guard olderState == .asking else { return }
            olderState = .waiting
            guard !page.messages.isEmpty else { olderState = .done; return }
            older.insert(page.owing([]), at: 0)
            guard !page.complete, !meets() else { return stopOlder() }
            // Two held pages that have not met the walk leave it at least a page to go, time enough for the page after
            // them; asked any earlier, a short walk would wait for it.
            if older.count == 2 { askPastOlder() }
            extendOlder()
        case .older(.failure):
            // The walk asks for these pages itself.
            if olderState == .asking { olderState = .done }
        }
    }

    private func ask(after id: String) {
        asked.insert(id)
        let operations = operations, room = room
        spawn {
            do { return .newer(after: id, .success(try await operations.fetchPage(.after(id), room))) }
            catch { return .newer(after: id, .failure(error)) }
        }
    }

    private func spawn(_ body: @escaping @Sendable () async -> Event) {
        serial += 1
        let id = serial, signal = signal
        running[id] = Task {
            let event = await body()
            signal.yield(id)
            return event
        }
    }

    private func awaitEvent() async throws {
        var waiter = waiter
        let next = await waiter.next()
        self.waiter = waiter
        guard let id = next else { throw CancellationError() }
        try Task.checkCancellation()
        guard let task = running.removeValue(forKey: id) else { return }
        receive(await task.value)
    }

    private func join(cancelling: Bool) async {
        while let (id, task) = running.first {
            if cancelling { task.cancel() }
            running[id] = nil
            receive(await task.value)
        }
    }
}
