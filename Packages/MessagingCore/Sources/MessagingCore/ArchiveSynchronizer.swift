import Foundation
import MessageStore
import OMEMO
import os
import XMPPProtocol

/// How far one archive's walk has come on this connection.
public struct ArchiveSyncProgress: Sendable, Equatable {
    /// nil for the account's own archive, the room otherwise.
    public let archive: String?
    /// Pages committed for this archive so far.
    public let pages: Int
    /// Messages processed for this archive so far.
    public let messages: Int
    init(archive: String?, pages: Int, messages: Int) { self.archive = archive; self.pages = pages; self.messages = messages }
}

/// Which archives one `synchronize` could not bring up to their newest entry on this connection. Their checkpoints
/// stand, so the next connection walks them again.
public struct ArchiveSyncOutcome: Sendable, Equatable {
    /// False when the server refused or did not answer a query on the account's own archive.
    public let ownArchiveComplete: Bool
    /// Rooms skipped on this connection: removed or unreadable membership, a refused query, or no answer.
    public let unfinishedRooms: [String]
    public var isComplete: Bool { ownArchiveComplete && unfinishedRooms.isEmpty }
}

/// How one `backfill` run ended.
public enum BackfillOutcome: Sendable, Equatable {
    /// No forward checkpoint for this archive yet, or the cursor is already complete.
    case nothingToDo
    /// The cursor reached the start of the archive, or the server no longer holds the cursor (expired history).
    case complete
    /// `pageBudget` pages committed; more remain.
    case budgetExhausted
    /// Cancelled between pages, or a room/query refusal before anything was fetched; the last committed
    /// page's cursor stands and the connection is intact.
    case stopped
}

/// Fetches one bounded page at a time. Ratchet/message or pending-ciphertext commits precede
/// the archive cursor, which precedes the SM handled acknowledgement. Repeating a partial page
/// is safe because OMEMO replay identity is independent of the archive/outer stanza identifier.
///
/// An archive without a forward checkpoint starts at its newest page (`<before/>`) and records a
/// separate backward cursor for older history, which `backfill` pages through on demand.
public struct ArchiveSynchronizer: Sendable {
    private let store: MessageStore
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "sync")
    public init(store: MessageStore) { self.store = store }

    @discardableResult
    public func synchronize(account: String, client: XMPPClient, encryption: OMEMOService,
                            progress: (@Sendable (ArchiveSyncProgress) async -> Void)? = nil) async throws -> ArchiveSyncOutcome {
        try await synchronize(account: account, operations: productionOperations(account: account, client: client, encryption: encryption, progress: progress))
    }

    /// Pages backwards from the archive's backfill cursor. Each page is committed (messages, then the
    /// cursor, then the acknowledgement) before the next fetch. Cancellation between pages returns
    /// `.stopped` without disconnecting; any failure or cancellation inside a page disconnects, exactly
    /// like `synchronize`, because a fetched page may own unhandled stream tokens. App only: the
    /// notification extension walks forward for new messages and never backfills.
    public func backfill(account: String, archive: String?, pageBudget: Int, client: XMPPClient, encryption: OMEMOService,
                         progress: (@Sendable (ArchiveSyncProgress) async -> Void)? = nil) async throws -> BackfillOutcome {
        try await backfill(account: account, archive: archive, pageBudget: pageBudget,
                           operations: productionOperations(account: account, client: client, encryption: encryption, progress: progress))
    }

    /// The one production adapter both walks use, so their processing and acknowledgement cannot drift.
    private func productionOperations(account: String, client: XMPPClient, encryption: OMEMOService,
                                      progress: (@Sendable (ArchiveSyncProgress) async -> Void)?) -> ArchiveSyncOperations {
        ArchiveSyncOperations(
            knownRooms: { Array(try await encryption.knownGroupRooms(account: account).keys).sorted() },
            // Reads at least once per room walk; the room's later pages reuse this validation.
            refreshRoom: { room in _ = try await client.refreshGroupRoom(room) },
            fetchPage: { bound, room in try await client.fetchArchivePage(bound, limit: 100, room: room) },
            process: { archived in try await self.process(account: account, archived: archived, encryption: encryption, transport: client) },
            acknowledge: { tokens in
                try await client.acknowledgeInbound(tokens)
                // Ask the server to count our journal so it trims the page, room and bundle IQs.
                // Swallowed on purpose: a server without SM throws notConnected, and a dead
                // socket makes the next page fetch fail on its own.
                try? await client.requestAcknowledgement()
            },
            disconnect: { await client.disconnect() },
            progress: { await progress?($0) },
            isOnline: { await client.isOnline }
        )
    }

    /// One archive entry: rejection/placeholder, own-send reconciliation, decrypt, or deliberate exclusion. Every path is
    /// durable before it returns; a thrown error means nothing durable exists for this entry and the page must not advance.
    func process(account: String, archived: XMPPArchiveMessage, encryption: OMEMOService, transport: XMPPClient) async throws {
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
        // Plaintext and unsupported content are deliberately excluded by this client's
        // encrypted-only policy. They must never be rendered as authenticated messages.
    }

    /// Records a rejected archive entry, with a placeholder in its conversation when the rejection names one and the
    /// content was encrypted with something this client cannot read. Both commit before the cursor advances.
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

    /// `unsupportedDirectContent` → `.unsupportedEncryption`, `malformedEncryptedContent` → `.malformedContent`, others → nil
    /// (a foreign sender has no conversation; a group rejection has no verified author).
    static func unreadableReason(for rejection: XMPPArchiveRejection) -> UnreadableReason? {
        switch rejection {
        case .unsupportedDirectContent: .unsupportedEncryption
        case .malformedEncryptedContent: .malformedContent
        case .foreignSender, .unverifiableEncryptedGroup: nil
        }
    }

    /// A query that failed without a page leaves nothing outstanding: the client closes the stream itself when a failure
    /// follows part of a page (and then throws `connectionClosed`), so these errors keep the connection and only end
    /// this archive's walk. A timeout's late results are acknowledged and dropped by the client; the next query has
    /// its own query id. A lost connection fails pending queries with `timedOut` too: that one ends the whole walk.
    private static func endsOnlyThisArchive(_ error: any Error, room: String?, operations: ArchiveSyncOperations) async -> Bool {
        switch error {
        case XMPPIQError.stanza: true
        case XMPPClientError.timedOut: await operations.isOnline()
        // A removed or unsupported room must not disable unrelated direct messages.
        case is XMPPGroupError: room != nil
        default: false
        }
    }

    /// Server-side archive times are compared at whole-second or coarser precision; a re-anchor starts this much before
    /// the checkpoint entry so that entry and its neighbours come back. Repeating them is harmless (replay identity).
    static let reanchorMargin: TimeInterval = 2

    @discardableResult
    func synchronize(account: String, operations: ArchiveSyncOperations) async throws -> ArchiveSyncOutcome {
        do {
            let rooms = try await operations.knownRooms()
            guard Set(rooms).count == rooms.count, !rooms.contains(account) else { throw XMPPIQError.malformedResponse }
            // The own archive walks first and needs no room refresh: the transport's trusted room set
            // (`ArchiveQuery.knownRooms`) is consulted only for room archives, and own-archive group
            // entries are validated by OMEMO against the room membership persisted in its state,
            // refreshing through the transport only for a room unknown there. An archived occupant
            // nickname alone is never enough to recover a real sender JID.
            let ownArchiveComplete = try await synchronizePages(account: account, room: nil, operations: operations)
            var unfinishedRooms: [String] = []
            for room in rooms {
                try Task.checkCancellation()
                do {
                    try await operations.refreshRoom(room)
                } catch {
                    guard await Self.endsOnlyThisArchive(error, room: room, operations: operations) else { throw error }
                    // Its room checkpoint stays untouched.
                    Self.log.notice("room skipped before its archive walk: \(Self.describe(error), privacy: .public)")
                    unfinishedRooms.append(room)
                    continue
                }
                if try await !synchronizePages(account: account, room: room, operations: operations) { unfinishedRooms.append(room) }
            }
            return ArchiveSyncOutcome(ownArchiveComplete: ownArchiveComplete, unfinishedRooms: unfinishedRooms)
        } catch {
            // A returned page may own unhandled stream tokens. Never leave a live stream
            // with an abandoned hole after cancellation, a storage failure, or stale CAS.
            await operations.disconnect()
            throw error
        }
    }

    /// Forward from the checkpoint. With no checkpoint the first query takes the newest page (`<before/>`): its
    /// oldest ID becomes the backfill cursor and its newest the checkpoint, and the walk continues forward from
    /// there to pick up whatever arrived between the two queries. A backward `complete` means "nothing older" and
    /// is recorded in the backfill cursor; only a forward `complete` ends the walk.
    ///
    /// When the server no longer holds the checkpoint's cursor (`item-not-found`: archive expiry removed it, or the
    /// archive was reset), the walk re-anchors once on the same connection: by time at the checkpoint entry's archive
    /// stamp, or, for a checkpoint saved before stamps existed, at the newest page with a new backfill cursor so the
    /// history in between can still be fetched. Either way the lost cursor is recorded as a possible gap.
    /// Returns false when a query failed without a page (`endsOnlyThisArchive`): the checkpoint stands for the next connection.
    private func synchronizePages(account: String, room: String?, operations: ArchiveSyncOperations) async throws -> Bool {
        let archive = room ?? account
        var checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: archive)
        var bound: XMPPArchiveBound = checkpoint.map { .after($0.cursor) } ?? .before(nil)
        var pages = 0, messages = 0, reanchored = false
        while true {
            try Task.checkCancellation()
            // Room fetches revalidate complete membership internally, without joining the room.
            let page: XMPPArchivePage
            do { page = try await operations.fetchPage(bound, room) }
            catch {
                if !reanchored, (error as? XMPPIQError) == .stanza(condition: "item-not-found"),
                   case .after(let lost?) = bound, let lostCheckpoint = checkpoint {
                    reanchored = true
                    bound = lostCheckpoint.stamp.map { .since($0.addingTimeInterval(-Self.reanchorMargin)) } ?? .before(nil)
                    Self.log.notice("archive cursor unknown to the server; re-anchoring \(lostCheckpoint.stamp == nil ? "at the newest page" : "by time", privacy: .public)")
                    try await store.recordArchiveGap(accountID: account, archiveID: archive, cursor: lost, since: lostCheckpoint.stamp)
                    continue
                }
                guard await Self.endsOnlyThisArchive(error, room: room, operations: operations) else { throw error }
                Self.log.error("archive walk incomplete\(room == nil ? "" : " (room)", privacy: .public): \(Self.describe(error), privacy: .public)")
                return false
            }
            for archived in page.messages {
                try Task.checkCancellation()
                try await operations.process(archived)
            }
            try Task.checkCancellation()
            let newestFirst = if case .before = bound { true } else { false }
            if let cursor = page.lastID {
                guard cursor != checkpoint?.cursor else { throw XMPPIQError.malformedResponse }
                // `finish` checked that `lastID` names the page's last (newest) entry.
                let stamp = page.messages.last?.timestamp
                if newestFirst {
                    guard let oldest = page.firstID else { throw XMPPIQError.malformedResponse }
                    // One transaction: an archive with a checkpoint and no backfill row counts as walked from its start
                    // (pre-v16), and a backfill row left without its checkpoint would sit behind a gap after a newer first
                    // page, so neither may exist on its own after a crash.
                    // A first page is history: it and anything backfill brings count as read (the read baseline). A page
                    // that replaces a lost cursor is not: it holds what this device missed.
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
            // An empty archive: nothing to check-point and nothing older to backfill.
            if page.lastID == nil, newestFirst { return true }
            if page.complete, !newestFirst { return true }
        }
    }

    /// The condition of a refusal, or the error's case: no addresses or content.
    private static func describe(_ error: any Error) -> String {
        if case .stanza(let condition)? = error as? XMPPIQError { return condition }
        return String(describing: error)
    }

    /// Whether `backfill` has anything to fetch for this archive: a forward checkpoint and an incomplete backfill cursor.
    /// A checkpoint without a backfill row was walked forward from the start of the archive before newest-first sync
    /// existed, so it has nothing older to fetch.
    public func hasPendingBackfill(account: String, archive: String?) async throws -> Bool {
        try await pendingBackfillCursor(account: account, archiveID: archive ?? account) != nil
    }

    private func pendingBackfillCursor(account: String, archiveID: String) async throws -> ArchiveBackfillCursor? {
        // Forward sync first, always.
        guard try await store.archiveCheckpoint(accountID: account, archiveID: archiveID) != nil,
              let cursor = try await store.archiveBackfillCursor(accountID: account, archiveID: archiveID),
              !cursor.complete else { return nil }
        return cursor
    }

    func backfill(account: String, archive: String?, pageBudget: Int, operations: ArchiveSyncOperations) async throws -> BackfillOutcome {
        let archiveID = archive ?? account
        guard var cursor = try await pendingBackfillCursor(account: account, archiveID: archiveID) else { return .nothingToDo }
        if let archive {
            // A backfill can start long after this connection's walk validated the room: read its membership again
            // before the first page (later pages reuse this validation), and skip the room as the walk does.
            do { try await operations.refreshRoom(archive) }
            catch is XMPPGroupError { return .stopped }
            catch XMPPIQError.stanza { return .stopped }
        }
        var pages = 0, messages = 0
        while pages < pageBudget {
            // Between pages nothing is outstanding: stop without touching the connection.
            if Task.isCancelled { return .stopped }
            let page: XMPPArchivePage
            do { page = try await operations.fetchPage(.before(cursor.oldestID), archive) }
            catch is XMPPGroupError where archive != nil { return .stopped }
            catch XMPPIQError.stanza(let condition) {
                // An IQ error carries no page: the client closes the stream itself when one follows a partial page, so
                // no tokens are outstanding here and the connection stays.
                guard condition == "item-not-found" else {
                    Self.log.error("backfill refused: \(condition, privacy: .public)")
                    return .stopped
                }
                // The server no longer knows the cursor. Archive expiry (Prosody `archive_expires_after`, one week by
                // default) removes the oldest entries first, so the cursor and everything older are gone: history
                // reachable from this device ends here.
                Self.log.notice("backfill cursor expired on the server; history ends here")
                _ = try await store.saveArchiveBackfillCursor(accountID: account, archiveID: archiveID, expectedRevision: cursor.revision,
                                                              oldestID: cursor.oldestID, complete: true)
                return .complete
            } catch XMPPClientError.invalidConfiguration {
                // Another archive query is active on this connection (a caller bug). Nothing was sent, so no tokens are outstanding.
                Self.log.error("backfill refused: archive query already active")
                return .stopped
            } catch {
                await operations.disconnect(); throw error
            }
            do {
                for archived in page.messages {
                    try Task.checkCancellation()
                    try await operations.process(archived)
                }
                try Task.checkCancellation()
                let oldest = page.firstID ?? cursor.oldestID
                // A page that does not move the cursor would repeat forever.
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
                // A fetched page may own unhandled stream tokens: never leave that hole on a live connection.
                await operations.disconnect(); throw error
            }
        }
        return .budgetExhausted
    }
}

/// Internal seam for deterministic durable-before-cursor/ack and interruption tests.
/// Production adapters still delegate provenance and cryptography to their owning packages.
struct ArchiveSyncOperations: Sendable {
    let knownRooms: @Sendable () async throws -> [String]
    let refreshRoom: @Sendable (String) async throws -> Void
    let fetchPage: @Sendable (XMPPArchiveBound, String?) async throws -> XMPPArchivePage
    let process: @Sendable (XMPPArchiveMessage) async throws -> Void
    let acknowledge: @Sendable ([XMPPInboundToken]) async throws -> Void
    let disconnect: @Sendable () async -> Void
    let progress: @Sendable (ArchiveSyncProgress) async -> Void
    /// Whether the connection is still up after a failed query (`endsOnlyThisArchive`).
    var isOnline: @Sendable () async -> Bool = { true }
}
