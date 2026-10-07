import Foundation
import MessageStore
import XMPPProtocol
import OMEMO

/// Connects protocol-owned counters/journal to the store's process lease and atomic acknowledgement.
/// The account is immutable for the lifetime of a connection; switching accounts creates an adapter.
public struct StreamPersistence: XMPPStreamManagementPersistence {
    private let store: MessageStore
    private let accountID: String
    private let encryption: OMEMOService

    public init(store: MessageStore, accountID: String, encryption: OMEMOService) {
        self.store = store
        self.accountID = accountID
        self.encryption = encryption
    }

    /// Every journaled message must be exactly one durable outgoing row of ours (message or update);
    /// otherwise the stream starts fresh and the archive reconciles what the server kept.
    public func permitsResumption(_ snapshot: XMPPStreamManagementSnapshot) async throws -> Bool {
        guard owns(snapshot) else { return false }
        // IQ entries carry no bytes and never a message ID; they are never replayed.
        for entry in snapshot.journal where entry.messageID != nil {
            guard let xml = entry.xml, try await encryption.canReplay(account: accountID, xml: xml) else { return false }
        }
        return true
    }

    /// A row that does not decode to this account's session at the row's revision is unreadable: the connect binds
    /// fresh and replaces it rather than failing until the resume window ends.
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

    /// In normal form: a session saved by a build that kept the typed capitals is still this account's.
    private func owns(_ snapshot: XMPPStreamManagementSnapshot) -> Bool {
        (JID.normalizedBare(snapshot.accountID) ?? snapshot.accountID) == (JID.normalizedBare(accountID) ?? accountID)
    }
}
