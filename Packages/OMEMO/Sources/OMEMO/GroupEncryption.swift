import Foundation
import CryptoKit
import MessageStore
import OMEMOCrypto
import XMPPProtocol

public protocol OMEMOGroupTransport: OMEMOTransport {
    func refreshGroupRoom(_ room: String) async throws -> XMPPGroupRoomSnapshot
}
extension XMPPClient: OMEMOGroupTransport {}

public struct PreparedGroupMessage: Sendable {
    public let envelope: XMPPOMEMOEnvelope
    public let members: [String]
}

public struct GroupEncryptionOverview: Sendable {
    public let room: XMPPGroupRoomSnapshot
    public let devices: [EncryptionDevice]
    public var needsTrust: Bool { devices.contains { !$0.trust.permitsEncryption } }
}

struct RetainedGroupEnvelope: Codable {
    let message: XMPPEncryptedGroupMessage
    let sentAt: Date
}

extension OMEMOService {
    public func localIdentity(account: String, profile: XMPPOMEMOProfile) async throws -> (deviceID: UInt32, fingerprint: String) {
        let (_, state) = try await load(account)
        let local = try engine(state, profile)
        return (local.deviceID, try OMEMOEngine.fingerprintBytes(for: local.identityKey, profile: profile.crypto).map { String(format: "%02x", $0) }.joined())
    }
    public func knownGroupRooms(account: String) async throws -> [String: [String]] {
        let (_, state) = try await load(account)
        return state.groupRooms
    }

    public func cachedGroupDevices(account: String, room: String) async throws -> [EncryptionDevice] {
        let (_, state) = try await load(account)
        var identities = Set(state.groupRooms[room] ?? [])
        for pending in try await store.pendingEncryptedIncoming(accountID: account) {
            if let retained = try? JSONDecoder().decode(RetainedGroupEnvelope.self, from: pending.wire), retained.message.room == room,
               retained.message.sender == pending.sender { identities.insert(pending.sender) }
        }
        return state.devices.filter { $0.profile == .modern && identities.contains($0.jid) }
    }

    /// Discovers every member, including offline members, without approving any fingerprint.
    public func refreshGroupDevices(account: String, room: String, transport: any OMEMOGroupTransport) async throws -> GroupEncryptionOverview {
        try await gate.run { try await self.refreshGroupLocked(account: account, room: room, transport: transport) }
    }
    func refreshGroupLocked(account: String, room: String, transport: any OMEMOGroupTransport) async throws -> GroupEncryptionOverview {
        let snapshot = try await transport.refreshGroupRoom(room)
        guard snapshot.room == room, snapshot.members.contains(account), snapshot.members.count <= 100 else { throw XMPPGroupError.incompleteMembership }
        for member in snapshot.members {
            let overview = try await refreshLocked(account: account, peer: member, profile: .modern, transport: transport, updateSelection: false)
            guard !overview.hasIncompatibleDevices else { throw OMEMOError.unsupportedProfile }
        }
        let confirmed = try await transport.refreshGroupRoom(room)
        guard confirmed.members == snapshot.members else { throw XMPPGroupError.membershipChanged }
        let (revision, old) = try await load(account)
        var state = old
        state.groupRooms[room] = snapshot.members
        try await save(state, revision: revision, account: account)
        let devices = state.devices.filter { snapshot.members.contains($0.jid) && $0.profile == .modern && $0.active }
        return GroupEncryptionOverview(room: confirmed, devices: devices)
    }

    /// Uses an already durable message intention. Group membership and recipient fingerprints
    /// are stored with the immutable ciphertext and ratchet advancement in one transaction.
    public func prepareGroupMessage(account: String, messageID: String, room: String, transport: any OMEMOGroupTransport) async throws {
        try await gate.run {
            let overview = try await self.refreshGroupLocked(account: account, room: room, transport: transport)
            guard overview.room.joined else { throw XMPPGroupError.notJoined }
            guard let message = try await self.store.message(accountID: account, messageID: messageID),
                  message.chatID == room, message.senderID == account, message.isOutgoing else { throw OMEMOError.invalidContent }
            let (revision, old) = try await self.load(account)
            var state = old
            let recipients = try await self.groupRecipients(state: state, members: overview.room.members, account: account)
            if let wire = try await self.store.encryptedOutgoing(accountID: account, messageID: messageID) {
                let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
                guard saved.groupMembers == overview.room.members, saved.envelope.profile == .modern,
                      saved.recipientIdentities.sorted() == recipients.map(\.id).sorted() else { throw OMEMOError.recipientSetChanged }
                return
            }
            let plaintext = try EncryptedContent.encode(body: message.body, reply: message.reply, sender: account,
                                                        recipient: room, modern: true, originID: message.id)
            var saved = try await self.sealForRecipients(plaintext, profile: .modern, accepted: recipients, state: &state)
            saved.groupMembers = overview.room.members
            try await self.store.sealQueuedOutgoing(accountID: account, messageID: messageID, profile: "modern",
                expectedRevision: revision, state: self.encode(state, account: account), wire: JSONEncoder().encode(saved), authenticateWireID: false)
        }
    }

    /// Refreshes complete membership and devices immediately before submitting saved ciphertext.
    /// The transport must additionally compare expectedMembers at its final room send boundary.
    public func outgoingGroupEnvelope(account: String, messageID: String, room: String,
                                       transport: any OMEMOGroupTransport) async throws -> PreparedGroupMessage {
        try await gate.run {
            let overview = try await self.refreshGroupLocked(account: account, room: room, transport: transport)
            guard overview.room.joined else { throw XMPPGroupError.notJoined }
            guard let message = try await self.store.message(accountID: account, messageID: messageID), message.chatID == room,
                  message.isOutgoing, message.senderID == account,
                  let wire = try await self.store.encryptedOutgoing(accountID: account, messageID: messageID) else { throw OMEMOError.invalidContent }
            let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
            let (_, state) = try await self.load(account)
            let recipients = try await self.groupRecipients(state: state, members: overview.room.members, account: account)
            guard saved.envelope.profile == .modern, saved.groupMembers == overview.room.members,
                  saved.recipientIdentities.sorted() == recipients.map(\.id).sorted() else { throw OMEMOError.recipientSetChanged }
            return PreparedGroupMessage(envelope: saved.envelope, members: overview.room.members)
        }
    }

    func groupRecipients(state: AccountEncryptionState, members: [String], account: String) throws -> [EncryptionDevice] {
        guard members.contains(account), Set(members).count == members.count else { throw XMPPGroupError.incompleteMembership }
        let recipients = state.devices.filter { members.contains($0.jid) && $0.profile == .modern && $0.active }
        // Rejected devices block the whole group. No undisclosed partial recipient set.
        guard recipients.allSatisfy({ $0.trust.permitsEncryption }) else { throw OMEMOError.trustRequired }
        for member in members where member != account {
            guard recipients.contains(where: { $0.jid == member }) else { throw OMEMOError.noDevices }
        }
        guard !recipients.isEmpty, recipients.count <= 1024 else { throw OMEMOError.noDevices }
        return recipients
    }

    public func receiveGroup(account: String, message: XMPPEncryptedGroupMessage, transport: any OMEMOGroupTransport,
                              sentAt: Date? = nil) async throws -> Bool {
        try await gate.run { try await self.receiveGroupLocked(account: account, message: message, transport: transport, sentAt: sentAt) }
    }
    func receiveGroupLocked(account: String, message: XMPPEncryptedGroupMessage, transport: any OMEMOGroupTransport,
                            sentAt: Date?) async throws -> Bool {
        guard message.envelope.profile == .modern, message.envelope.payload != nil,
              message.occupant.hasPrefix(message.room + "/"), bare(message.sender) == message.sender else { throw OMEMOError.invalidContent }
        let (_, first) = try await load(account)
        let initialEngine = try engine(first, .modern)
        if message.sender == account, message.envelope.senderDeviceID == initialEngine.deviceID {
            return try await reconcileGroupEcho(account: account, message: message)
        }
        let keys = message.envelope.keys.filter { $0.recipientJID == account && $0.deviceID == initialEngine.deviceID }
        guard keys.count == 1 else { throw OMEMOError.notForThisDevice }
        let digest = try groupDigest(message, key: keys[0])
        if try await store.hasEncryptedIncoming(accountID: account, sender: message.sender, digest: digest) {
            if let stanzaID = message.roomStanzaID {
                try await store.bindArchivedGroupReference(accountID: account, sender: message.sender, digest: digest, room: message.room, stanzaID: stanzaID)
            }
            return false
        }
        let pending = try await store.pendingEncryptedIncoming(accountID: account).first { $0.sender == message.sender && $0.digest == digest }
        var retained = try pending.map { try JSONDecoder().decode(RetainedGroupEnvelope.self, from: $0.wire) }
            ?? RetainedGroupEnvelope(message: message, sentAt: sentAt ?? Date())
        if let pending, let sentAt, message.provenance != .liveOccupant,
           retained.message.sender == message.sender, retained.message.room == message.room,
           retained.message.envelope == message.envelope {
            retained = RetainedGroupEnvelope(message: message, sentAt: sentAt)
            guard try await store.replacePendingEncryptedIncomingContext(accountID: account, sender: message.sender, digest: digest,
                expectedWire: pending.wire, wire: JSONEncoder().encode(retained)) else { throw OMEMOError.stateUnavailable }
        }
        try await store.retainEncryptedIncoming(accountID: account, sender: message.sender, digest: digest, wire: JSONEncoder().encode(retained))
        if first.groupRooms[message.room] == nil || !first.devices.contains(where: { $0.jid == message.sender && $0.deviceID == message.envelope.senderDeviceID && $0.profile == .modern }) {
            _ = try await refreshGroupLocked(account: account, room: message.room, transport: transport)
        }
        if message.provenance != .liveOccupant, !first.devices.contains(where: { $0.jid == message.sender && $0.deviceID == message.envelope.senderDeviceID && $0.profile == .modern }) {
            _ = try await refreshLocked(account: account, peer: message.sender, profile: .modern, transport: transport, updateSelection: false)
        }
        let (revision, old) = try await load(account)
        var state = old
        guard let members = state.groupRooms[message.room], members.contains(account), (message.provenance != .liveOccupant || members.contains(message.sender)) else { throw XMPPGroupError.incompleteMembership }
        guard let device = state.devices.last(where: { $0.jid == message.sender && $0.deviceID == message.envelope.senderDeviceID && $0.profile == .modern }),
              device.trust.permitsEncryption else { throw OMEMOError.trustRequired }
        let local = try engine(state, .modern)
        let address = DeviceAddress(jid: message.sender, deviceID: device.deviceID)
        try local.trustIdentity(device.identityKey, for: address, resetSession: device.identityChanged)
        if let index = state.devices.firstIndex(where: { $0.id == device.id }) { state.devices[index].identityChanged = false }
        let key = keys[0]
        let material = try local.decrypt(RatchetCiphertext(data: key.data, isPreKey: key.keyExchange), from: address)
        let plaintext = try PayloadCrypto.open(SealedPayload(payload: message.envelope.payload!, keyMaterial: material, iv: nil), profile: .modern)
        let content = try EncryptedContent.decode(plaintext, sender: message.sender, recipient: message.room, modern: true,
                                                  sendingTime: retained.sentAt, requireGroupAffixes: true)
        let stored: StoredMessage?
        let reaction: AuthenticatedReaction?
        if let update = content.reaction {
            stored = nil
            reaction = AuthenticatedReaction(id: content.originID ?? digest, chatID: message.room, actorID: message.sender,
                targetWireID: update.targetWireID, reactions: update.reactions,
                updatedAt: min(content.timestamp ?? retained.sentAt, Date()))
        } else if content.retraction != nil {
            // ponytail: group retract/edit is not projected yet; commit the ratchet, show nothing.
            stored = nil; reaction = nil
        } else {
            guard !content.body.isEmpty else { throw OMEMOError.invalidContent }
            stored = StoredMessage(id: UUID().uuidString, accountID: account, chatID: message.room, senderID: message.sender,
                body: content.body, sentAt: retained.sentAt, isOutgoing: message.sender == account, reply: content.reply,
                encryptionProfile: "modern", wireID: nil, wireIDAuthenticated: false)
            reaction = nil
        }
        var control: EncryptionControl?
        if key.keyExchange {
            let response = try local.encrypt(Data(repeating: 0, count: 32), to: address)
            let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: local.deviceID,
                keys: [XMPPOMEMOKey(recipientJID: message.sender, deviceID: device.deviceID, keyExchange: response.isPreKey, data: response.data)], payload: nil)
            control = EncryptionControl(id: UUID().uuidString, recipient: message.sender, wire: try encodeWire(envelope))
            state.pendingBundlePublications.insert("modern")
        }
        try local.replenishPreKeys()
        state.engines["modern"] = try local.snapshot()
        try await store.commitEncryptedIncoming(accountID: account, sender: message.sender, digest: digest, expectedRevision: revision,
            state: encode(state, account: account), message: stored, control: control, reaction: reaction, groupRoom: message.room,
            roomStanzaID: stored == nil ? nil : message.roomStanzaID)
        if key.keyExchange { try? await flushBundlePublicationsLocked(account: account, transport: transport) }
        return true
    }
    public func hasDurableGroupDisposition(account: String, message: XMPPEncryptedGroupMessage) async throws -> Bool {
        let (_, state) = try await load(account)
        let local = try engine(state, .modern)
        if message.sender == account, message.envelope.senderDeviceID == local.deviceID { return true }
        let keys = message.envelope.keys.filter { $0.recipientJID == account && $0.deviceID == local.deviceID }
        if keys.isEmpty { return true }
        guard keys.count == 1 else { return false }
        let digest = try groupDigest(message, key: keys[0])
        if try await store.hasEncryptedIncoming(accountID: account, sender: message.sender, digest: digest) { return true }
        return try await store.pendingEncryptedIncoming(accountID: account).contains { $0.sender == message.sender && $0.digest == digest }
    }
    private func groupDigest(_ message: XMPPEncryptedGroupMessage, key: XMPPOMEMOKey) throws -> String {
        let direct = XMPPEncryptedMessage(id: message.id, from: message.sender, to: message.room, originID: nil, envelope: message.envelope)
        let inner = try ciphertextDigest(direct, key: key)
        return SHA256.hash(data: Data((message.room + "\u{0}" + inner).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func queueGroupReactionsLocked(account: String, room: String, messageID: String, reactions: [String]) async throws -> String {
        guard let target = try await store.message(accountID: account, messageID: messageID), target.chatID == room,
              target.encryptionProfile == "modern", !target.wireIDAuthenticated,
              let reference = try await store.reactionReference(accountID: account, messageID: messageID),
              try await store.reactionTarget(accountID: account, chatID: room, wireID: reference)?.id == messageID else { throw OMEMOError.unsupportedEncryptedReactions }
        let update = StoredReactionUpdate(id: UUID().uuidString, accountID: account, chatID: room, targetMessageID: messageID,
            targetWireID: reference, actorID: account, reactions: try ReactionContent.normalized(reactions))
        _ = try await store.enqueueReaction(update, groupRoom: room)
        return update.id
    }

    public func prepareGroupReaction(account: String, updateID: String, room: String, transport: any OMEMOGroupTransport) async throws {
        try await gate.run { try await self.prepareGroupReactionLocked(account: account, updateID: updateID, room: room, transport: transport) }
    }
    private func prepareGroupReactionLocked(account: String, updateID: String, room: String, transport: any OMEMOGroupTransport) async throws {
        let overview = try await refreshGroupLocked(account: account, room: room, transport: transport)
        guard overview.room.joined else { throw XMPPGroupError.notJoined }
        guard let update = try await store.reactionUpdate(accountID: account, updateID: updateID), update.chatID == room, update.actorID == account,
              try await store.reactionTarget(accountID: account, chatID: room, wireID: update.targetWireID)?.id == update.targetMessageID else { throw OMEMOError.unsupportedEncryptedReactions }
        let (revision, old) = try await load(account)
        var state = old
        let recipients = try groupRecipients(state: state, members: overview.room.members, account: account)
        if let wire = try await store.updateWire(accountID: account, updateID: updateID) {
            let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
            guard saved.groupMembers == overview.room.members, saved.envelope.profile == .modern,
                  saved.recipientIdentities.sorted() == recipients.map(\.id).sorted() else { throw OMEMOError.recipientSetChanged }
            return
        }
        let plaintext = try EncryptedContent.encodeReaction(targetWireID: update.targetWireID, reactions: update.reactions,
            sender: account, recipient: room, originID: update.id, modern: true)
        var saved = try sealForRecipients(plaintext, profile: .modern, accepted: recipients, state: &state)
        saved.groupMembers = overview.room.members
        try await store.sealQueuedUpdate(accountID: account, updateID: update.id, expectedRevision: revision,
            state: encode(state, account: account), wire: JSONEncoder().encode(saved))
    }
    public func outgoingGroupReactionEnvelope(account: String, updateID: String, room: String, transport: any OMEMOGroupTransport) async throws -> PreparedGroupMessage {
        try await gate.run {
            try await self.prepareGroupReactionLocked(account: account, updateID: updateID, room: room, transport: transport)
            guard let wire = try await self.store.updateWire(accountID: account, updateID: updateID) else { throw OMEMOError.unavailable }
            let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
            guard let members = saved.groupMembers else { throw OMEMOError.invalidContent }
            return PreparedGroupMessage(envelope: saved.envelope, members: members)
        }
    }

    private func reconcileGroupEcho(account: String, message: XMPPEncryptedGroupMessage) async throws -> Bool {
        if let update = try await store.reactionUpdate(accountID: account, updateID: message.id), update.chatID == message.room,
           update.actorID == account, let wire = try await store.updateWire(accountID: account, updateID: message.id) {
            let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
            guard saved.groupMembers != nil, saved.envelope == message.envelope else { return false }
            _ = try await store.reconcileArchivedUpdate(accountID: account, updateID: message.id, expectedWire: wire)
            return false
        }
        guard let intention = try await store.message(accountID: account, messageID: message.id), intention.chatID == message.room,
              intention.senderID == account, intention.isOutgoing,
              let wire = try await store.encryptedOutgoing(accountID: account, messageID: message.id) else { return false }
        let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
        guard saved.groupMembers != nil, saved.envelope == message.envelope else { return false }
        _ = try await store.reconcileArchivedOutgoing(accountID: account, messageID: message.id, expectedEncryptedWire: wire, groupRoom: message.room, roomStanzaID: message.roomStanzaID)
        return false
    }
}
