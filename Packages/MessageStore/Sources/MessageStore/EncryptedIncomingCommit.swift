import Foundation

/// One decrypted direct message's durable outcome, committed with the ratchet state that produced it.
public struct EncryptedIncomingCommit: Sendable {
    public let sender: String
    public let digest: String
    public var message: StoredMessage?
    public var reaction: AuthenticatedReaction?
    public var event: MessageEvent?
    public var archiveStanzaID: String?
    public var readMarker: OwnReadMarker?
    /// Queue `message`'s delivery receipt in the same transaction.
    public var queuesReceipt: Bool
    public init(sender: String, digest: String, message: StoredMessage? = nil, reaction: AuthenticatedReaction? = nil, event: MessageEvent? = nil,
                archiveStanzaID: String? = nil, readMarker: OwnReadMarker? = nil, queuesReceipt: Bool = false) {
        self.sender = sender; self.digest = digest; self.message = message; self.reaction = reaction; self.event = event
        self.archiveStanzaID = archiveStanzaID; self.readMarker = readMarker; self.queuesReceipt = queuesReceipt
    }
}

extension EncryptedIncomingCommit {
    func validate(accountID: String, groupRoom: String?) throws {
        guard !sender.isEmpty, !digest.isEmpty,
              // Another device of this account said it displayed a peer message: nothing else rides with it.
              readMarker.map({ _ in message == nil && reaction == nil && event == nil && groupRoom == nil && sender == accountID }) ?? true,
              // A room's ids travel as `roomStanzaID`; this one is the account's own archive's.
              archiveStanzaID == nil || groupRoom == nil,
              !queuesReceipt || (message != nil && groupRoom == nil),
              message.map({ $0.accountID == accountID && $0.senderID == sender && $0.encryptionProfile != nil }) ?? true
        else { throw MessageStoreError.invalidValue }
        if let groupRoom {
            guard message.map({ $0.chatID == groupRoom }) ?? reaction.map({ $0.chatID == groupRoom }) ?? false else { throw MessageStoreError.invalidValue }
        }
    }
}
