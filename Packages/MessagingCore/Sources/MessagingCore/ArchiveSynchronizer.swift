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
        do { try await synchronizePages(account: account, client: client, encryption: encryption) }
        catch {
            // A returned page may own unhandled stream tokens. Never leave a live stream
            // with an abandoned hole after cancellation, a storage failure, or stale CAS.
            await client.disconnect()
            throw error
        }
    }

    private func synchronizePages(account: String, client: XMPPClient, encryption: OMEMOService) async throws {
        var checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: account)
        while true {
            try Task.checkCancellation()
            let page = try await client.fetchArchivePage(after: checkpoint?.cursor, limit: 100)
            for archived in page.messages {
                try Task.checkCancellation()
                if let encrypted = archived.encryptedMessage {
                    if try await encryption.reconcileArchivedOutgoing(account: account, message: encrypted) { continue }
                    do {
                        _ = try await encryption.receive(account: account, message: encrypted, transport: client, sentAt: archived.timestamp)
                    } catch {
                        guard try await encryption.hasDurableIncomingDisposition(account: account, message: encrypted) else { throw error }
                    }
                }
                // Plaintext and unsupported content are deliberately excluded by this client's
                // encrypted-only policy. They must never be rendered as authenticated messages.
            }
            if let cursor = page.lastID {
                guard cursor != checkpoint?.cursor else { throw XMPPIQError.malformedResponse }
                _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account,
                                                         expectedRevision: checkpoint?.revision, cursor: cursor)
                checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: account)
            }
            for token in page.handledTokens { try await client.acknowledgeInbound(token) }
            if page.complete { return }
        }
    }
}
