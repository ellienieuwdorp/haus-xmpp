import Foundation
import MessageStore
import XMPPProtocol
import OMEMO

/// Binds protocol-owned counters and journal to the store's lease and atomic acknowledgement. The account is fixed
/// for a connection's lifetime; switching accounts creates a new adapter.
public struct StreamPersistence: XMPPStreamManagementPersistence {
    private let store: MessageStore
    private let accountID: String
    private let encryption: OMEMOService

    public init(store: MessageStore, accountID: String, encryption: OMEMOService) {
        self.store = store
        self.accountID = accountID
        self.encryption = encryption
    }

    /// Every journaled message must be exactly one durable outgoing row of ours; otherwise the stream starts fresh and
    /// the archive reconciles what the server kept.
    public func permitsResumption(_ snapshot: XMPPStreamManagementSnapshot) async throws -> Bool {
        guard owns(snapshot) else { return false }
        // IQ entries carry no bytes and never a message ID; they are never replayed.
        for entry in snapshot.journal where entry.messageID != nil {
            guard let xml = entry.xml, try await encryption.canReplay(account: accountID, xml: xml) else { return false }
        }
        return true
    }

    /// An undecodable row, or one for another account or revision, makes the connect bind fresh and replace it rather
    /// than fail until the resume window ends.
    public func load() async throws -> XMPPStreamManagementSnapshot? {
        guard let saved = try await store.streamManagementState(accountID: accountID) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(XMPPStreamManagementSnapshot.self, from: saved.data),
              owns(snapshot), snapshot.revision == saved.revision else {
            throw XMPPStreamManagementUnreadable(revision: saved.revision)
        }
        return snapshot
    }

    public func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) async throws {
        guard owns(snapshot), snapshot.revision == (expectedRevision ?? 0) + 1 else {
            throw XMPPStreamManagementError.invalidState
        }
        _ = try await store.saveStreamManagement(accountID: accountID, expectedRevision: expectedRevision,
                                                data: JSONEncoder().encode(snapshot), acknowledgedMessageIDs: acknowledgedMessageIDs)
    }

    // Compared in normal form, so a session saved with the typed capitals is still this account's.
    private func owns(_ snapshot: XMPPStreamManagementSnapshot) -> Bool {
        (JID.normalizedBare(snapshot.accountID) ?? snapshot.accountID) == (JID.normalizedBare(accountID) ?? accountID)
    }
}
