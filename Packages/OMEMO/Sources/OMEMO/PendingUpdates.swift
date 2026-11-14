import Foundation
import MessageStore
import XMPPProtocol

extension OMEMOService {
    // A correction has a body, so it is encrypted for legacy peers too (`plain` is nil) and its reference rides
    // outside.
    struct PendingUpdate {
        let id: String; let chatID: String; let kind: StoredUpdate.Kind
        let plain: (() throws -> String)?
        let plaintext: (_ modern: Bool) throws -> Data
        var dropsLinkPreview: (_ modern: Bool) -> Bool = { _ in false }
    }

    // Every queued direct update a pass may seal: reactions, receipts and markers (unless deferred), retractions, then
    // corrections.
    func pendingUpdates(account: String, deferringReceipts: Bool) async throws -> [PendingUpdate] {
        var queued: [PendingUpdate] = try await store.queuedReactions(accountID: account).map { update in
            PendingUpdate(id: update.id, chatID: update.chatID, kind: .reaction,
                          plain: { try XMPPClient.reactionXML(to: update.chatID, targetID: update.targetWireID, reactions: update.reactions,
                                                              id: update.id) },
                          plaintext: { _ in try EncryptedContent.encodeReaction(targetWireID: update.targetWireID, reactions: update.reactions, sender: account,
                                                                                recipient: update.chatID, originID: update.id, modern: true) })
        }
        queued += try await (deferringReceipts ? [] : store.queuedReceipts(accountID: account)).compactMap { update -> PendingUpdate? in
            guard let target = update.targetWireID else { return nil }
            let kind: MessageContent.Receipt.Kind = update.kind == .marker ? .displayed : .delivered
            return PendingUpdate(id: update.id, chatID: update.chatID, kind: update.kind,
                                 plain: { try XMPPClient.receiptXML(to: update.chatID, targetID: target, kind: kind, id: update.id) },
                                 plaintext: { _ in
                                     try EncryptedContent.encodeReceipt(targetWireID: target, kind: kind, sender: account, recipient: update.chatID,
                                                                        originID: update.id)
                                 })
        }
        queued += try await store.queuedUpdates(accountID: account, kind: .retraction).compactMap { update in
            guard let target = update.targetWireID else { return nil }
            return PendingUpdate(id: update.id, chatID: update.chatID, kind: .retraction,
                                 plain: { try XMPPClient.retractionXML(to: update.chatID, targetID: target, id: update.id) },
                                 plaintext: { _ in try EncryptedContent.encodeRetraction(targetWireID: target, sender: account, recipient: update.chatID,
                                                                                         originID: update.id, modern: true) })
        }
        for update in try await store.queuedUpdates(accountID: account, kind: .correction) {
            guard let target = update.targetWireID, let payload = update.payload,
                  let body = MessageEvent.correctionBody(payload) else { continue }
            let linkMetadata = MessageEvent.correctionLinkPreview(payload)?.metadata
            // Editing a caption re-sends the same file reference: a peer that replaces the whole message keeps the attachment.
            var attachment: StoredAttachment?
            if let id = update.targetMessageID { attachment = try await store.message(accountID: account, messageID: id)?.attachment }
            let file = try attachment.map { try fileSharing(for: $0, account: account) }
            queued.append(PendingUpdate(id: update.id, chatID: update.chatID, kind: .correction, plain: nil,
                                        plaintext: { modern in try EncryptedContent.encode(body: body, reply: nil, sender: account, recipient: update.chatID,
                                                                                           modern: modern, originID: update.id, fileSharing: file,
                                                                                           correction: target, linkMetadata: linkMetadata) },
                                        dropsLinkPreview: { modern in
                                            linkMetadata.map {
                                                !EncryptedContent.linkMetadataRides($0, body: body, modern: modern, fileSharing: file != nil)
                                            } ?? false
                                        }))
        }
        return queued
    }
}
