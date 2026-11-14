import Foundation
import MessageStore
import OMEMOCrypto
import XMPPProtocol

extension OMEMOService {
    struct IncomingContext {
        let sender: String, peer: String, digest: String
        let sentAt: Date?, replaces: String?
    }

    struct DecryptedIncoming {
        var stored: StoredMessage?
        var reaction: AuthenticatedReaction?
        var event: MessageEvent?
        var readMarker: OwnReadMarker?
        var hasOutcome: Bool { stored != nil || reaction != nil || event != nil || readMarker != nil }
    }

    // What a decrypted direct envelope means. Throws `invalidContent` (or the payload's own error) for content this
    // device will never read; the caller records that outcome.
    func interpret(_ material: Data, message: XMPPEncryptedMessage, account: String, context: IncomingContext) async throws -> DecryptedIncoming {
        let profile = message.envelope.profile, sender = context.sender, peer = context.peer, digest = context.digest
        let sentAt = context.sentAt, replaces = context.replaces
        var stored: StoredMessage?
        var reaction: AuthenticatedReaction?
        var event: MessageEvent?
        var readMarker: OwnReadMarker?
        if let payload = message.envelope.payload {
            let plaintext = try PayloadCrypto.open(SealedPayload(payload: payload, keyMaterial: material, iv: message.envelope.iv),
                                                   profile: profile.crypto)
            let content = try EncryptedContent.decode(plaintext, sender: sender, recipient: sender == account ? peer : account,
                                                       modern: profile == .modern, sendingTime: sentAt)
            let date = min(content.timestamp ?? sentAt ?? Date(), Date())
            // A legacy correction reference sits outside the ciphertext, bound like a legacy reaction.
            let correction = content.correction ?? (profile == .legacy ? replaces : nil)
            if let target = content.retraction {
                guard profile == .modern, sender == account || sender == peer else { throw OMEMOError.invalidContent }
                event = MessageEvent(id: content.originID ?? digest, chatID: peer, actorID: sender, targetWireID: target, kind: .retraction,
                                     payload: "{}", updatedAt: date)
            } else if let target = correction, !content.body.isEmpty {
                // An edit projects onto the original bubble, never a second bubble.
                guard sender == account || sender == peer else { throw OMEMOError.invalidContent }
                event = MessageEvent(id: content.originID ?? message.originID ?? message.id, chatID: peer, actorID: sender, targetWireID: target,
                                     kind: .correction, payload: try MessageEvent.correctionPayload(
                                        content.body, linkPreview: content.linkMetadata.map { StoredLinkPreview($0, source: .sender) }),
                                     updatedAt: date)
            } else if !content.body.isEmpty || content.fileSharing != nil {
                stored = StoredMessage(id: UUID().uuidString, accountID: account, chatID: peer, senderID: sender,
                                       body: content.body, sentAt: sentAt ?? Date(), isOutgoing: sender == account,
                                       reply: content.reply, encryptionProfile: profile.rawValue,
                                       // XEP-0444 targets the stanza id in 1:1 chats; peers without origin-id (Conversations) still get one.
                                       wireID: content.originID ?? message.originID ?? message.id, wireIDAuthenticated: content.originID != nil,
                                       attachment: try content.fileSharing.map { try storedAttachment($0, account: account) },
                                       linkPreview: content.linkMetadata.map { StoredLinkPreview($0, source: .sender) })
            }
            if let update = content.reaction, event == nil {
                guard profile == .modern, sender == account || sender == peer else { throw OMEMOError.invalidContent }
                reaction = AuthenticatedReaction(id: content.originID ?? digest, chatID: peer, actorID: sender,
                                                 targetWireID: update.targetWireID, reactions: update.reactions, updatedAt: date)
            }
            // A receipt only confirms one of our messages, and only from the peer; our other device's copy is ignored.
            if let receipt = content.receipt, profile == .modern, sender == peer, stored == nil, reaction == nil, event == nil,
               try await store.reactionTarget(accountID: account, chatID: peer, wireID: receipt.targetID)?.isOutgoing != false {
                event = MessageEvent(id: content.originID ?? digest, chatID: peer, actorID: sender, targetWireID: receipt.targetID,
                                     kind: receipt.kind == .displayed ? .displayed : .delivered, payload: "{}",
                                     updatedAt: min(content.timestamp ?? sentAt ?? Date(), Date()))
            }
            // Another device of ours displayed a peer message: authenticated as our account, it moves the read pointer.
            if let receipt = content.receipt, receipt.kind == .displayed, profile == .modern, sender == account, peer != account,
               stored == nil, reaction == nil, event == nil {
                readMarker = OwnReadMarker(chatID: peer, targetWireID: receipt.targetID)
            }
        } else if profile == .modern {
            guard material == Data(repeating: 0, count: 32) else { throw OMEMOError.invalidContent }
        }
        return DecryptedIncoming(stored: stored, reaction: reaction, event: event, readMarker: readMarker)
    }

    func queuesReceipt(_ decrypted: DecryptedIncoming, message: XMPPEncryptedMessage, sender: String, peer: String, state: AccountEncryptionState) -> Bool {
        decrypted.stored != nil && sender == peer && message.requestsReceipt && state.groupRooms[peer] == nil && state.profiles[peer] != nil
    }

    // The empty message that answers a prekey message, so the sender's session stops sending prekeys.
    func keyTransport(from local: OMEMOEngine, to address: DeviceAddress, profile: XMPPOMEMOProfile) throws -> EncryptionControl {
        let response = try local.encrypt(Data(repeating: 0, count: 32), to: address)
        let header = XMPPOMEMOKey(recipientJID: profile == .modern ? address.jid : nil, deviceID: address.deviceID, keyExchange: response.isPreKey,
                                  data: response.data)
        let envelope = XMPPOMEMOEnvelope(profile: profile, senderDeviceID: local.deviceID, keys: [header],
                                         iv: profile == .legacy ? Data(repeating: 0, count: 12) : nil, payload: nil)
        return EncryptionControl(id: UUID().uuidString, recipient: address.jid, wire: try encodeWire(envelope))
    }

    // The kept engine if it holds exactly the loaded snapshot, else a fresh import; the caller owns it until it parks it.
    func liveEngine(_ state: AccountEncryptionState, _ profile: XMPPOMEMOProfile, account: String) throws -> OMEMOEngine {
        if let live = liveEngines[account]?[profile] {
            liveEngines[account]?[profile] = nil
            if live.snapshot == state.engines[profile.rawValue] { return live.engine }
        }
        return try engine(state, profile)
    }
    // `snapshot` must be exactly what `engine` would export now.
    func park(_ engine: OMEMOEngine, snapshot: Data?, profile: XMPPOMEMOProfile, account: String) {
        guard let snapshot else { return }
        liveEngines[account, default: [:]][profile] = (snapshot, engine)
    }
}
