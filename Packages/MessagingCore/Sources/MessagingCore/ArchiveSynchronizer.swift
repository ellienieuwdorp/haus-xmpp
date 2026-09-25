import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// Fetches one bounded page at a time. Ratchet/message or pending-ciphertext commits precede
/// the archive cursor, which precedes the SM handled acknowledgement. Repeating a partial page
/// is safe because OMEMO replay identity is independent of the archive/outer stanza identifier.
public struct ArchiveSynchronizer: Sendable {
    private let store: MessageStore
    public init(store: MessageStore) { self.store = store }

    public func synchronize(account: String, client: XMPPClient, encryption: OMEMOService) async throws {
        try await synchronize(account: account, operations: ArchiveSyncOperations(
            knownRooms: { Array(try await encryption.knownGroupRooms(account: account).keys).sorted() },
            refreshRoom: { room in _ = try await client.refreshGroupRoom(room) },
            fetchPage: { cursor, room in try await client.fetchArchivePage(after: cursor, limit: 100, room: room) },
            process: { archived in try await self.process(account: account, archived: archived, encryption: encryption, transport: client) },
            acknowledge: { token in try await client.acknowledgeInbound(token) },
            disconnect: { await client.disconnect() }
        ))
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
            // Populate the fresh transport's trusted room set before its own-account MAM query.
            // An archived occupant nickname alone is never enough to recover a real sender JID.
            let rooms = try await operations.knownRooms()
            guard Set(rooms).count == rooms.count, !rooms.contains(account) else { throw XMPPIQError.malformedResponse }
            var accessibleRooms: [String] = []
            for room in rooms {
                try Task.checkCancellation()
                do {
                    try await operations.refreshRoom(room)
                    accessibleRooms.append(room)
                } catch is XMPPGroupError {
                    // A removed or unsupported room must not disable unrelated direct messages.
                    // Its room checkpoint stays untouched; own-archive ciphertext is still handled
                    // under independently validated historical sender provenance.
                    continue
                } catch XMPPIQError.stanza {
                    continue
                }
            }
            try await synchronizePages(account: account, room: nil, operations: operations)
            for room in accessibleRooms {
                try await synchronizePages(account: account, room: room, operations: operations)
            }
        } catch {
            // A returned page may own unhandled stream tokens. Never leave a live stream
            // with an abandoned hole after cancellation, a storage failure, or stale CAS.
            await operations.disconnect()
            throw error
        }
    }

    private func synchronizePages(account: String, room: String?, operations: ArchiveSyncOperations) async throws {
        let archive = room ?? account
        var checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: archive)
        while true {
            try Task.checkCancellation()
            // Room fetches revalidate complete membership internally, without joining the room.
            let page: XMPPArchivePage
            do { page = try await operations.fetchPage(checkpoint?.cursor, room) }
            catch is XMPPGroupError where room != nil { return }
            catch XMPPIQError.stanza where room != nil { return }
            for archived in page.messages {
                try Task.checkCancellation()
                try await operations.process(archived)
            }
            try Task.checkCancellation()
            if let cursor = page.lastID {
                guard cursor != checkpoint?.cursor else { throw XMPPIQError.malformedResponse }
                _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: archive,
                                                         expectedRevision: checkpoint?.revision, cursor: cursor)
                checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: archive)
            } else if !page.complete {
                throw XMPPIQError.malformedResponse
            }
            for token in page.handledTokens { try await operations.acknowledge(token) }
            if page.complete { return }
        }
    }
}

/// Internal seam for deterministic durable-before-cursor/ack and interruption tests.
/// Production adapters still delegate provenance and cryptography to their owning packages.
struct ArchiveSyncOperations: Sendable {
    let knownRooms: @Sendable () async throws -> [String]
    let refreshRoom: @Sendable (String) async throws -> Void
    let fetchPage: @Sendable (String?, String?) async throws -> XMPPArchivePage
    let process: @Sendable (XMPPArchiveMessage) async throws -> Void
    let acknowledge: @Sendable (XMPPInboundToken) async throws -> Void
    let disconnect: @Sendable () async -> Void
}
