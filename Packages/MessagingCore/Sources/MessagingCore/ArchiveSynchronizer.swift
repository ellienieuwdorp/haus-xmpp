import Foundation
import MessageStore
import OMEMO
import os
import XMPPProtocol

public struct ArchiveSyncProgress: Sendable, Equatable {
    /// Nil for the account's own archive.
    public let archive: String?
    public let pages: Int
    public let messages: Int
    init(archive: String?, pages: Int, messages: Int) { self.archive = archive; self.pages = pages; self.messages = messages }
}

/// Archives not brought up to their newest entry keep their checkpoints, so the next connection walks them again.
public struct ArchiveSyncOutcome: Sendable, Equatable {
    public let ownArchiveComplete: Bool
    /// Removed or unreadable membership, a refused query, or no answer.
    public let unfinishedRooms: [String]
    public var isComplete: Bool { ownArchiveComplete && unfinishedRooms.isEmpty }
}

public enum BackfillOutcome: Sendable, Equatable {
    /// No forward checkpoint yet, or the cursor is already complete.
    case nothingToDo
    /// The start of the archive, or the server no longer holds the cursor (expired history).
    case complete
    case budgetExhausted
    /// Cancelled between pages, or refused before anything was fetched; the connection is intact.
    case stopped
}

/// One bounded page at a time. Ratchet, message or pending-ciphertext commits precede the archive cursor, which
/// precedes the SM handled acknowledgement. Repeating a partial page is safe: OMEMO replay identity is independent
/// of the archive and outer stanza identifiers. Without a forward checkpoint a walk starts at the newest page
/// (`<before/>`) and records a backward cursor that `backfill` pages through on demand.
public struct ArchiveSynchronizer: Sendable {
    private let store: MessageStore
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "sync")
    public init(store: MessageStore) { self.store = store }

    /// `ownArchiveWalked` runs before the first room; a throw from it ends the walk and closes the stream.
    @discardableResult
    public func synchronize(account: String, client: XMPPClient, encryption: OMEMOService,
                            progress: (@Sendable (ArchiveSyncProgress) async -> Void)? = nil,
                            ownArchiveWalked: (@Sendable (_ complete: Bool, _ rooms: Int) async throws -> Void)? = nil) async throws -> ArchiveSyncOutcome {
        var operations = productionOperations(account: account, client: client, encryption: encryption, progress: progress)
        if let ownArchiveWalked { operations.ownArchiveWalked = ownArchiveWalked }
        return try await synchronize(account: account, operations: operations)
    }

    /// Pages backwards from the archive's backfill cursor, committing each page (messages, cursor, acknowledgement)
    /// before the next fetch. Cancellation between pages returns `.stopped`; a failure or cancellation inside a page
    /// disconnects, because a fetched page may own unhandled stream tokens. App only: the notification extension walks
    /// forward and never backfills.
    public func backfill(account: String, archive: String?, pageBudget: Int, client: XMPPClient, encryption: OMEMOService,
                         progress: (@Sendable (ArchiveSyncProgress) async -> Void)? = nil) async throws -> BackfillOutcome {
        try await backfill(account: account, archive: archive, pageBudget: pageBudget,
                           operations: productionOperations(account: account, client: client, encryption: encryption, progress: progress))
    }

    /// Ask just before joining, so the first walk can tell existing history from what arrived after the join, in
    /// the archive's own clock. `.distantPast` for an empty archive. Needs the connection's archive query to be free.
    /// The entry is not processed; the first walk fetches it.
    public func roomJoinBoundary(room: String, client: XMPPClient) async throws -> Date {
        try await roomJoinBoundary(
            fetchNewest: { try await client.fetchArchivePage(.before(nil), limit: 1, room: room) },
            acknowledge: { tokens in
                try await client.acknowledgeInbound(tokens)
                try? await client.requestAcknowledgement()
            },
            disconnect: { await client.disconnect() })
    }

    func roomJoinBoundary(fetchNewest: () async throws -> XMPPArchivePage, acknowledge: ([XMPPInboundToken]) async throws -> Void,
                          disconnect: () async -> Void) async throws -> Date {
        // The client closes the stream itself when a query fails after part of a page.
        let page = try await fetchNewest()
        do {
            if !page.handledTokens.isEmpty { try await acknowledge(page.handledTokens) }
        } catch {
            // Unacknowledged tokens would leave a permanent gap on a live connection.
            await disconnect()
            throw error
        }
        return page.messages.map(\.timestamp).max() ?? .distantPast
    }

    // Shared by both walks, so their processing and acknowledgement cannot drift.
    private func productionOperations(account: String, client: XMPPClient, encryption: OMEMOService,
                                      progress: (@Sendable (ArchiveSyncProgress) async -> Void)?) -> ArchiveSyncOperations {
        ArchiveSyncOperations(
            knownRooms: { Array(try await encryption.knownGroupRooms(account: account).keys).sorted() },
            refreshRoom: { room in _ = try await client.refreshGroupRoom(room) },
            fetchPage: { bound, room in try await client.fetchArchivePage(bound, limit: 100, room: room) },
            process: { archived in try await self.process(account: account, archived: archived, encryption: encryption, transport: client) },
            acknowledge: { tokens in
                try await client.acknowledgeInbound(tokens)
                // Lets the server count our journal so it trims the page, room and bundle IQs. A server without SM
                // throws notConnected, and a dead socket fails the next fetch on its own.
                try? await client.requestAcknowledgement()
            },
            disconnect: { await client.disconnect() },
            progress: { await progress?($0) },
            isOnline: { await client.isOnline }
        )
    }

    // Every path is durable before it returns; a throw means nothing durable exists for the entry and the page must
    // not advance.
    func process(account: String, archived: XMPPArchiveMessage, encryption: OMEMOService, transport: XMPPClient) async throws {
        if let error = archived.messageError {
            // The live copy may have been applied already, and a retry since must stand.
            if let chat = error.bouncedAddress {
                _ = try await encryption.rejectOutgoing(account: account, chatID: chat, wireID: error.id, rejection: error.rejection, firstOnly: true)
            }
            return
        }
        if try await persistRejectedContent(account: account, archived: archived) { return }
        if let group = archived.encryptedGroupMessage {
            do {
                _ = try await encryption.receiveGroup(account: account, message: group, transport: transport, sentAt: archived.timestamp)
            } catch OMEMOError.notForThisDevice, OMEMOError.undecryptable {
                return // Durable by contract: thrown only once the placeholder (when one is owed) exists.
            } catch {
                guard try await encryption.hasDurableGroupDisposition(account: account, message: group) else { throw error }
            }
        } else if let encrypted = archived.encryptedMessage {
            if try await encryption.reconcileArchivedOutgoing(account: account, message: encrypted) { return }
            do {
                _ = try await encryption.receive(account: account, message: encrypted, transport: transport, sentAt: archived.timestamp)
            } catch OMEMOError.notForThisDevice, OMEMOError.undecryptable {
                return // Durable by contract: thrown only once the placeholder (when one is owed) exists.
            } catch {
                guard try await encryption.hasDurableIncomingDisposition(account: account, message: encrypted) else { throw error }
            }
        } else if let reaction = archived.reaction {
            try await encryption.receivePlaintextReaction(account: account, reaction: reaction, sentAt: archived.timestamp)
        } else if let retraction = archived.retraction {
            try await encryption.receivePlaintextRetraction(account: account, retraction: retraction, sentAt: archived.timestamp)
        } else if let receipt = archived.receipt {
            try await encryption.receivePlaintextReceipt(account: account, receipt: receipt, sentAt: archived.timestamp)
        }
        // Plaintext and unsupported content are excluded and must never render as authenticated messages.
    }

    // Commits before the cursor advances.
    func persistRejectedContent(account: String, archived: XMPPArchiveMessage) async throws -> Bool {
        guard let reason = archived.rejectedContent else { return false }
        guard let archive = archived.rejectionArchive else { throw XMPPIQError.malformedResponse }
        let placeholder: UnreadableMessage? = archived.rejectedPeer.flatMap { peer in
            Self.unreadableReason(for: reason).map { unreadable in
                UnreadableMessage(accountID: account, chatID: peer, senderID: archived.rejectedOutgoing ? account : peer,
                                  isOutgoing: archived.rejectedOutgoing, sentAt: archived.timestamp, reason: unreadable,
                                  key: .archive(archive: archive, id: archived.archiveID))
            }
        }
        try await store.recordArchiveRejection(accountID: account, archiveID: archive, messageID: archived.archiveID,
                                               reason: reason.rawValue, placeholder: placeholder)
        return true
    }

    // Nil: a foreign sender has no conversation and a group rejection has no verified author.
    static func unreadableReason(for rejection: XMPPArchiveRejection) -> UnreadableReason? {
        switch rejection {
        case .unsupportedDirectContent: .unsupportedEncryption
        case .malformedEncryptedContent: .malformedContent
        case .foreignSender, .unverifiableEncryptedGroup: nil
        }
    }

    // A query that failed without a page leaves nothing outstanding (after part of a page the client closes the stream
    // itself), so these errors keep the connection. A lost connection also fails queries with `timedOut`.
    private static func endsOnlyThisArchive(_ error: any Error, room: String?, operations: ArchiveSyncOperations) async -> Bool {
        switch error {
        case XMPPIQError.stanza: true
        case XMPPClientError.timedOut: await operations.isOnline()
        // A removed or unsupported room must not disable unrelated direct messages.
        case is XMPPGroupError: room != nil
        default: false
        }
    }

    // Servers compare archive times at whole-second or coarser precision; repeated entries are harmless.
    static let reanchorMargin: TimeInterval = 2

    @discardableResult
    func synchronize(account: String, operations: ArchiveSyncOperations) async throws -> ArchiveSyncOutcome {
        do {
            let rooms = try await operations.knownRooms()
            guard Set(rooms).count == rooms.count, !rooms.contains(account) else { throw XMPPIQError.malformedResponse }
            // Own-archive group entries are validated by OMEMO against persisted room membership, so no refresh is
            // needed. An archived occupant nickname alone never recovers a real sender JID.
            let ownArchiveComplete = try await synchronizePages(account: account, room: nil, operations: operations)
            try await operations.ownArchiveWalked(ownArchiveComplete, rooms.count)
            var unfinishedRooms: [String] = []
            for room in rooms {
                try Task.checkCancellation()
                do {
                    try await operations.refreshRoom(room)
                } catch {
                    guard await Self.endsOnlyThisArchive(error, room: room, operations: operations) else { throw error }
                    Self.log.notice("room skipped before its archive walk: \(Self.describe(error), privacy: .public)")
                    unfinishedRooms.append(room)
                    continue
                }
                if try await !synchronizePages(account: account, room: room, operations: operations) { unfinishedRooms.append(room) }
            }
            return ArchiveSyncOutcome(ownArchiveComplete: ownArchiveComplete, unfinishedRooms: unfinishedRooms)
        } catch {
            // A returned page may own unhandled stream tokens: never leave a live stream with a hole.
            await operations.disconnect()
            throw error
        }
    }

    // A first `<before/>` page sets the backfill cursor (its oldest ID) and checkpoint (its newest); a backward
    // `complete` means only "nothing older". An `item-not-found` cursor re-anchors once, by the checkpoint's stamp or
    // at the newest page, and is recorded as a possible gap once the archive answers. False keeps the checkpoint.
    private func synchronizePages(account: String, room: String?, operations: ArchiveSyncOperations) async throws -> Bool {
        let walk = ArchiveWalkTimings(), operations = operations.timed(by: walk)
        defer { Self.log.notice("archive walk \(room == nil ? "own" : "room", privacy: .public) \(walk.summary(), privacy: .public)") }
        let archive = room ?? account
        var checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: archive)
        var bound: XMPPArchiveBound = checkpoint.map { .after($0.cursor) } ?? .before(nil)
        var pages = 0, messages = 0, reanchored = false
        var lostCursor: (cursor: String, since: Date?)?
        while true {
            try Task.checkCancellation()
            // Room fetches revalidate complete membership without joining the room.
            let page: XMPPArchivePage
            do { page = try await operations.fetchPage(bound, room) }
            catch {
                if !reanchored, (error as? XMPPIQError) == .stanza(condition: "item-not-found"),
                   case .after(let lost?) = bound, let lostCheckpoint = checkpoint {
                    reanchored = true
                    lostCursor = (lost, lostCheckpoint.stamp)
                    bound = lostCheckpoint.stamp.map { .since($0.addingTimeInterval(-Self.reanchorMargin)) } ?? .before(nil)
                    Self.log.notice("archive cursor unknown to the server; re-anchoring \(lostCheckpoint.stamp == nil ? "at the newest page" : "by time", privacy: .public)")
                    continue
                }
                guard await Self.endsOnlyThisArchive(error, room: room, operations: operations) else { throw error }
                Self.log.error("archive walk incomplete\(room == nil ? "" : " (room)", privacy: .public): \(Self.describe(error), privacy: .public)")
                return false
            }
            // An archive that refuses the re-anchored query too has lost nothing we could still fetch.
            if let lost = lostCursor {
                try await store.recordArchiveGap(accountID: account, archiveID: archive, cursor: lost.cursor, since: lost.since)
                lostCursor = nil
            }
            for archived in page.messages {
                try Task.checkCancellation()
                try await operations.process(archived)
            }
            try Task.checkCancellation()
            let newestFirst = if case .before = bound { true } else { false }
            if let cursor = page.lastID {
                guard cursor != checkpoint?.cursor else { throw XMPPIQError.malformedResponse }
                // `finish` checked that `lastID` names the page's newest entry.
                let stamp = page.messages.last?.timestamp
                if newestFirst {
                    guard let oldest = page.firstID else { throw XMPPIQError.malformedResponse }
                    // One transaction: a checkpoint without a backfill row means walked from the start, and a backfill
                    // row without its checkpoint would sit behind a gap. A first page counts as read history; one
                    // replacing a lost cursor does not, since it holds what this device missed.
                    _ = try await store.saveNewestArchivePage(accountID: account, archiveID: archive, cursor: cursor, stamp: stamp,
                                                              oldestID: oldest, complete: page.complete,
                                                              historyThrough: checkpoint == nil ? page.messages.map(\.timestamp).max() : nil,
                                                              replacing: checkpoint?.revision)
                } else {
                    _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: archive,
                                                             expectedRevision: checkpoint?.revision, cursor: cursor, stamp: stamp)
                }
                checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: archive)
                bound = .after(cursor)
            } else if !page.complete {
                throw XMPPIQError.malformedResponse
            }
            if !page.handledTokens.isEmpty { try await operations.acknowledge(page.handledTokens) }
            pages += 1; messages += page.messages.count
            await operations.progress(ArchiveSyncProgress(archive: room, pages: pages, messages: messages))
            // Recorded so the next connection's first page, which arrived meanwhile, is not taken for history.
            if page.lastID == nil, newestFirst {
                if checkpoint == nil { try await store.recordEmptyArchive(accountID: account, archiveID: archive) }
                return true
            }
            if page.complete, !newestFirst { return true }
        }
    }

    // No addresses or content.
    private static func describe(_ error: any Error) -> String {
        if case .stanza(let condition)? = error as? XMPPIQError { return condition }
        return String(describing: error)
    }

    /// A checkpoint without a backfill row was walked from the start of the archive and has nothing older.
    public func hasPendingBackfill(account: String, archive: String?) async throws -> Bool {
        try await pendingBackfillCursor(account: account, archiveID: archive ?? account) != nil
    }

    private func pendingBackfillCursor(account: String, archiveID: String) async throws -> ArchiveBackfillCursor? {
        guard try await store.archiveCheckpoint(accountID: account, archiveID: archiveID) != nil,
              let cursor = try await store.archiveBackfillCursor(accountID: account, archiveID: archiveID),
              !cursor.complete else { return nil }
        return cursor
    }

    func backfill(account: String, archive: String?, pageBudget: Int, operations: ArchiveSyncOperations) async throws -> BackfillOutcome {
        let archiveID = archive ?? account
        guard var cursor = try await pendingBackfillCursor(account: account, archiveID: archiveID) else { return .nothingToDo }
        if let archive {
            // A backfill can start long after the walk validated the room's membership.
            do { try await operations.refreshRoom(archive) }
            catch is XMPPGroupError { return .stopped }
            catch XMPPIQError.stanza { return .stopped }
        }
        var pages = 0, messages = 0
        while pages < pageBudget {
            // Nothing is outstanding between pages.
            if Task.isCancelled { return .stopped }
            let page: XMPPArchivePage
            do { page = try await operations.fetchPage(.before(cursor.oldestID), archive) }
            catch is XMPPGroupError where archive != nil { return .stopped }
            catch XMPPIQError.stanza(let condition) {
                // An IQ error carries no page, so no tokens are outstanding.
                guard condition == "item-not-found" else {
                    Self.log.error("backfill refused: \(condition, privacy: .public)")
                    return .stopped
                }
                // Archive expiry (Prosody `archive_expires_after`, one week by default) removes the oldest entries
                // first, so everything older than the cursor is gone too.
                Self.log.notice("backfill cursor expired on the server; history ends here")
                _ = try await store.saveArchiveBackfillCursor(accountID: account, archiveID: archiveID, expectedRevision: cursor.revision,
                                                              oldestID: cursor.oldestID, complete: true)
                return .complete
            } catch XMPPClientError.invalidConfiguration {
                // Another archive query is active (a caller bug). Nothing was sent.
                Self.log.error("backfill refused: archive query already active")
                return .stopped
            } catch {
                if case XMPPClientError.timedOut = error, await operations.isOnline() {
                    Self.log.error("backfill query unanswered")
                    return .stopped
                }
                await operations.disconnect(); throw error
            }
            do {
                for archived in page.messages {
                    try Task.checkCancellation()
                    try await operations.process(archived)
                }
                try Task.checkCancellation()
                let oldest = page.firstID ?? cursor.oldestID
                guard page.firstID == nil || oldest != cursor.oldestID else { throw XMPPIQError.malformedResponse }
                _ = try await store.saveArchiveBackfillCursor(accountID: account, archiveID: archiveID, expectedRevision: cursor.revision,
                                                              oldestID: oldest, complete: page.complete)
                guard let saved = try await store.archiveBackfillCursor(accountID: account, archiveID: archiveID) else { throw MessageStoreError.invalidTransition }
                cursor = saved
                if !page.handledTokens.isEmpty { try await operations.acknowledge(page.handledTokens) }
                pages += 1; messages += page.messages.count
                await operations.progress(ArchiveSyncProgress(archive: archive, pages: pages, messages: messages))
                if page.complete { return .complete }
            } catch {
                // A fetched page may own unhandled stream tokens.
                await operations.disconnect(); throw error
            }
        }
        return .budgetExhausted
    }
}

// Test seam for durable-before-cursor and interruption ordering; production adapters delegate provenance and
// cryptography to their packages.
struct ArchiveSyncOperations: Sendable {
    let knownRooms: @Sendable () async throws -> [String]
    let refreshRoom: @Sendable (String) async throws -> Void
    let fetchPage: @Sendable (XMPPArchiveBound, String?) async throws -> XMPPArchivePage
    let process: @Sendable (XMPPArchiveMessage) async throws -> Void
    let acknowledge: @Sendable ([XMPPInboundToken]) async throws -> Void
    let disconnect: @Sendable () async -> Void
    let progress: @Sendable (ArchiveSyncProgress) async -> Void
    var isOnline: @Sendable () async -> Bool = { true }
    var ownArchiveWalked: @Sendable (_ complete: Bool, _ rooms: Int) async throws -> Void = { _, _ in }
}

// Counts and milliseconds only, no addresses or content. `fetch` runs from query to `<fin/>`; `other` is mostly cursor
// commits.
final class ArchiveWalkTimings: Sendable {
    enum Phase: Int { case fetch, process, acknowledge, progress }
    static let signposter = OSSignposter(subsystem: "haus.xmpp.ios", category: "SyncPhases")
    private let started = ContinuousClock.now
    private let totals = OSAllocatedUnfairLock(initialState: (phases: [Duration](repeating: .zero, count: 4), pages: 0, entries: 0))

    func measure<T>(_ phase: Phase, _ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let interval = Self.signposter.beginInterval(name), start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            totals.withLock { $0.phases[phase.rawValue] += elapsed }
            Self.signposter.endInterval(name, interval)
        }
        return try await body()
    }

    func fetched(entries: Int) { totals.withLock { $0.pages += 1; $0.entries += entries } }

    func summary() -> String {
        let wall = ContinuousClock.now - started, t = totals.withLock { $0 }
        let phase = { (p: Phase) in t.phases[p.rawValue] }
        let other = wall - t.phases.reduce(.zero, +)
        let seconds = Double(wall / .microseconds(1)) / 1_000_000
        let rate = seconds > 0 ? Int((Double(t.entries) / seconds).rounded()) : 0
        return "+\(Self.ms(wall)) ms pages=\(t.pages) entries=\(t.entries) fetch_ms=\(Self.ms(phase(.fetch))) "
            + "process_ms=\(Self.ms(phase(.process))) ack_ms=\(Self.ms(phase(.acknowledge))) "
            + "progress_ms=\(Self.ms(phase(.progress))) other_ms=\(Self.ms(other)) entries_per_s=\(rate)"
    }

    static func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }
}

extension ArchiveSyncOperations {
    func timed(by walk: ArchiveWalkTimings) -> ArchiveSyncOperations {
        let base = self
        return ArchiveSyncOperations(
            knownRooms: base.knownRooms, refreshRoom: base.refreshRoom,
            fetchPage: { bound, room in
                let page = try await walk.measure(.fetch, "fetch page") { try await base.fetchPage(bound, room) }
                walk.fetched(entries: page.messages.count)
                return page
            },
            process: { archived in try await walk.measure(.process, "process entry") { try await base.process(archived) } },
            acknowledge: { tokens in try await walk.measure(.acknowledge, "acknowledge") { try await base.acknowledge(tokens) } },
            disconnect: base.disconnect,
            progress: { progress in await walk.measure(.progress, "progress") { await base.progress(progress) } },
            isOnline: base.isOnline)
    }
}
