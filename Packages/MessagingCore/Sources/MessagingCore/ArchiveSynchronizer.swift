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
    public init(archive: String?, pages: Int, messages: Int) { self.archive = archive; self.pages = pages; self.messages = messages }
}

/// How one `backfill` run ended.
public enum BackfillOutcome: Sendable, Equatable {
    /// No forward checkpoint for this archive yet, or the cursor is already complete.
    case nothingToDo
    /// The cursor reached the start of the archive.
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

    public func synchronize(account: String, client: XMPPClient, encryption: OMEMOService,
                            progress: (@Sendable (ArchiveSyncProgress) async -> Void)? = nil) async throws {
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
            progress: { await progress?($0) }
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

    func synchronize(account: String, operations: ArchiveSyncOperations) async throws {
        do {
            let rooms = try await operations.knownRooms()
            guard Set(rooms).count == rooms.count, !rooms.contains(account) else { throw XMPPIQError.malformedResponse }
            // The own archive walks first and needs no room refresh: the transport's trusted room set
            // (`ArchiveQuery.knownRooms`) is consulted only for room archives, and own-archive group
            // entries are validated by OMEMO against the room membership persisted in its state,
            // refreshing through the transport only for a room unknown there. An archived occupant
            // nickname alone is never enough to recover a real sender JID.
            try await synchronizePages(account: account, room: nil, operations: operations)
            for room in rooms {
                try Task.checkCancellation()
                do {
                    try await operations.refreshRoom(room)
                } catch is XMPPGroupError {
                    // A removed or unsupported room must not disable unrelated direct messages.
                    // Its room checkpoint stays untouched.
                    continue
                } catch XMPPIQError.stanza {
                    continue
                }
                try await synchronizePages(account: account, room: room, operations: operations)
            }
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
    private func synchronizePages(account: String, room: String?, operations: ArchiveSyncOperations) async throws {
        let archive = room ?? account
        var checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: archive)
        var bound: XMPPArchiveBound = checkpoint.map { .after($0.cursor) } ?? .before(nil)
        var pages = 0, messages = 0
        while true {
            try Task.checkCancellation()
            // Room fetches revalidate complete membership internally, without joining the room.
            let page: XMPPArchivePage
            do { page = try await operations.fetchPage(bound, room) }
            catch is XMPPGroupError where room != nil { return }
            catch XMPPIQError.stanza where room != nil { return }
            for archived in page.messages {
                try Task.checkCancellation()
                try await operations.process(archived)
            }
            try Task.checkCancellation()
            let newestFirst = if case .before = bound { true } else { false }
            if let cursor = page.lastID {
                guard cursor != checkpoint?.cursor else { throw XMPPIQError.malformedResponse }
                if newestFirst {
                    guard let oldest = page.firstID else { throw XMPPIQError.malformedResponse }
                    // Saved before the checkpoint: an archive with a checkpoint and no backfill row counts as
                    // walked from its start (pre-v16), so the reverse order would lose older history on a crash.
                    if try await store.archiveBackfillCursor(accountID: account, archiveID: archive) == nil {
                        _ = try await store.saveArchiveBackfillCursor(accountID: account, archiveID: archive, expectedRevision: nil,
                                                                      oldestID: oldest, complete: page.complete)
                    }
                }
                _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: archive,
                                                         expectedRevision: checkpoint?.revision, cursor: cursor)
                checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: archive)
                bound = .after(cursor)
            } else if !page.complete {
                throw XMPPIQError.malformedResponse
            }
            if !page.handledTokens.isEmpty { try await operations.acknowledge(page.handledTokens) }
            pages += 1; messages += page.messages.count
            await operations.progress(ArchiveSyncProgress(archive: room, pages: pages, messages: messages))
            // An empty archive: nothing to check-point and nothing older to backfill.
            if page.lastID == nil, newestFirst { return }
            if page.complete, !newestFirst { return }
        }
    }

    func backfill(account: String, archive: String?, pageBudget: Int, operations: ArchiveSyncOperations) async throws -> BackfillOutcome {
        let archiveID = archive ?? account
        // Forward sync first, always. A checkpoint without a backfill row was walked forward from the start
        // of the archive before newest-first sync existed, so it has nothing older to fetch.
        guard try await store.archiveCheckpoint(accountID: account, archiveID: archiveID) != nil,
              var cursor = try await store.archiveBackfillCursor(accountID: account, archiveID: archiveID),
              !cursor.complete else { return .nothingToDo }
        var pages = 0, messages = 0
        while pages < pageBudget {
            // Between pages nothing is outstanding: stop without touching the connection.
            if Task.isCancelled { return .stopped }
            let page: XMPPArchivePage
            do { page = try await operations.fetchPage(.before(cursor.oldestID), archive) }
            // Same skip rule as the forward walk; the client turns a room error after a partial page into connectionClosed.
            catch is XMPPGroupError where archive != nil { return .stopped }
            catch XMPPIQError.stanza where archive != nil { return .stopped }
            catch XMPPClientError.invalidConfiguration {
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
}
