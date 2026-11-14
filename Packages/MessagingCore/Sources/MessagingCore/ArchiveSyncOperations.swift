import Foundation
import XMPPProtocol

// Test seam for durable-before-cursor and interruption ordering; production adapters delegate provenance and
// cryptography to their packages.
struct ArchiveSyncOperations: Sendable {
    let knownRooms: @Sendable () async throws -> [String]
    let refreshRoom: @Sendable (String) async throws -> Void
    let fetchPage: @Sendable (XMPPArchiveBound, String?) async throws -> XMPPArchivePage
    // A room's newest entry without its content; nil walks every room.
    var newestEntry: (@Sendable (String) async throws -> XMPPArchiveNewest)? = nil
    var prefetchesPages = false
    // A forward walk also pages back from the newest entry until it meets itself; needs `prefetchesPages`.
    var pagesFromNewest = false
    let process: @Sendable (XMPPArchiveMessage) async throws -> Void
    // A page's entries in order, durable when it returns; nil processes them one by one.
    var processPage: (@Sendable ([XMPPArchiveMessage]) async throws -> Void)? = nil
    let acknowledge: @Sendable ([XMPPInboundToken]) async throws -> Void
    let disconnect: @Sendable () async -> Void
    let progress: @Sendable (ArchiveSyncProgress) async -> Void
    var isOnline: @Sendable () async -> Bool = { true }
    var ownArchiveWalked: @Sendable (_ complete: Bool, _ rooms: Int) async throws -> Void = { _, _ in }
}

extension ArchiveSyncOperations {
    func processEntries(_ entries: [XMPPArchiveMessage]) async throws {
        if let processPage { return try await processPage(entries) }
        for archived in entries {
            try Task.checkCancellation()
            try await process(archived)
        }
    }

    func timed(by walk: ArchiveWalkTimings) -> ArchiveSyncOperations {
        let base = self
        var processPage: (@Sendable ([XMPPArchiveMessage]) async throws -> Void)?
        if let page = base.processPage {
            processPage = { @Sendable entries in try await walk.measure(.process, "process page") { try await page(entries) } }
        }
        return ArchiveSyncOperations(
            knownRooms: base.knownRooms, refreshRoom: base.refreshRoom,
            fetchPage: { bound, room in
                let page = try await walk.measure(.fetch, "fetch page") { try await base.fetchPage(bound, room) }
                walk.fetched(entries: page.messages.count)
                return page
            },
            prefetchesPages: base.prefetchesPages,
            pagesFromNewest: base.pagesFromNewest,
            process: { archived in try await walk.measure(.process, "process entry") { try await base.process(archived) } },
            processPage: processPage,
            acknowledge: { tokens in try await walk.measure(.acknowledge, "acknowledge") { try await base.acknowledge(tokens) } },
            disconnect: base.disconnect,
            progress: { progress in await walk.measure(.progress, "progress") { await base.progress(progress) } },
            isOnline: base.isOnline)
    }
}
