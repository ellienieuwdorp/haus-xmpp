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

    public func permitsResumption(_ snapshot: XMPPStreamManagementSnapshot) async throws -> Bool {
        guard snapshot.accountID == accountID else { return false }
        for entry in snapshot.journal where entry.messageID != nil {
            guard let message = try? XMPPClient.decodeOutgoingEncryptedMessageXML(entry.xml, from: accountID),
                  let recipient = message.to, message.id == entry.messageID,
                  try await encryption.canReplayEncryptedMessage(account: accountID, messageID: message.id,
                                                                  recipient: recipient, envelope: message.envelope) else { return false }
        }
        return true
    }

    public func load() async throws -> XMPPStreamManagementSnapshot? {
        guard let saved = try await store.streamManagementState(accountID: accountID) else { return nil }
        let snapshot = try JSONDecoder().decode(XMPPStreamManagementSnapshot.self, from: saved.data)
        guard snapshot.accountID == accountID, snapshot.revision == saved.revision else {
            throw XMPPStreamManagementError.invalidState
        }
        return snapshot
    }

    public func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) async throws {
        guard snapshot.accountID == accountID, snapshot.revision == (expectedRevision ?? 0) + 1 else {
            throw XMPPStreamManagementError.invalidState
        }
        _ = try await store.saveStreamManagement(accountID: accountID, expectedRevision: expectedRevision,
                                                data: JSONEncoder().encode(snapshot), acknowledgedMessageIDs: acknowledgedMessageIDs)
    }
}
