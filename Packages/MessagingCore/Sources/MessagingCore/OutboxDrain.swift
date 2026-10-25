import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// One pass of the outbox on one connection: the composer's path, shared by the foreground session, a notification
/// Reply and the share extension. Seals what can be sealed, sends the sealed messages in queue order, then every update
/// (reactions, receipts and markers, retractions, corrections, key transports). A chat that needs a fingerprint
/// decision or keys is held: its messages stay queued, exactly as saved. Nothing here changes trust or sends
/// plaintext content.
public struct OutboxDrain: Sendable {
    let account: String
    let client: XMPPClient
    let encryption: OMEMOService
    let store: MessageStore
    let sender: OutboxSender
    /// Rooms joined on this connection; a group message waits for its room.
    let joinedGroups: Set<String>

    public init(account: String, client: XMPPClient, encryption: OMEMOService, store: MessageStore, sender: OutboxSender,
                joinedGroups: Set<String>) {
        self.account = account; self.client = client; self.encryption = encryption; self.store = store
        self.sender = sender; self.joinedGroups = joinedGroups
    }

    /// How the caller reflects the pass. `hold` and `groupFailed` return the chats they marked as held for trust.
    public struct Hooks: Sendable {
        public var hold: @MainActor @Sendable (_ blocked: [String: String]) -> Set<String> = { Set($0.keys) }
        public var groupPrepared: @MainActor @Sendable (_ room: String) -> Void = { _ in }
        public var groupFailed: @MainActor @Sendable (_ room: String, _ error: any Error) -> Set<String> = { room, _ in [room] }
        /// Files queued as a reply that went without it (their chat fell back to legacy OMEMO before sealing).
        public var repliesDropped: @MainActor @Sendable (_ messageIDs: Set<String>) -> Void = { _ in }
        public var didChange: @Sendable () async -> Void = {}

        public init(hold: @escaping @MainActor @Sendable (_ blocked: [String: String]) -> Set<String> = { Set($0.keys) },
                    groupPrepared: @escaping @MainActor @Sendable (_ room: String) -> Void = { _ in },
                    groupFailed: @escaping @MainActor @Sendable (_ room: String, _ error: any Error) -> Set<String> = { room, _ in [room] },
                    repliesDropped: @escaping @MainActor @Sendable (_ messageIDs: Set<String>) -> Void = { _ in },
                    didChange: @escaping @Sendable () async -> Void = {}) {
            self.hold = hold; self.groupPrepared = groupPrepared; self.groupFailed = groupFailed
            self.repliesDropped = repliesDropped; self.didChange = didChange
        }
    }

    /// Returns the chats held for a fingerprint decision (or a group problem) on this pass.
    public func run(_ hooks: Hooks = Hooks()) async throws -> Set<String> {
        let account = account, client = client, encryption = encryption, joinedGroups = joinedGroups
        let preparation = try await encryption.prepareAvailableMessages(account: account, transport: client)
        // Sends held for a fingerprint decision mark their chat for review; any other reason is a footnote.
        var heldForTrust = await hooks.hold(preparation.blockedChats)
        if !preparation.droppedReplies.isEmpty { await hooks.repliesDropped(preparation.droppedReplies) }
        var preparedIDs = preparation.messageIDs
        for message in try await store.queuedOutgoing(accountID: account) where joinedGroups.contains(message.chatID) {
            do {
                try await encryption.prepareGroupMessage(account: account, messageID: message.id, room: message.chatID, transport: client)
                preparedIDs.insert(message.id)
                await hooks.groupPrepared(message.chatID)
            } catch {
                if error is CancellationError { throw error }
                heldForTrust.formUnion(await hooks.groupFailed(message.chatID, error))
            }
        }
        try await sender.drain(accountID: account, messageIDs: preparedIDs, send: { message in
            if joinedGroups.contains(message.chatID) {
                let prepared: PreparedGroupMessage
                do { prepared = try await encryption.outgoingGroupEnvelope(account: account, messageID: message.id, room: message.chatID, transport: client) }
                catch { throw OutboxSendFailure.notAttempted }
                _ = try await client.sendEncryptedGroupMessage(room: message.chatID, envelope: prepared.envelope, id: message.id, expectedMembers: prepared.members)
            } else {
                let envelope: XMPPOMEMOEnvelope
                do { envelope = try await encryption.outgoingEnvelope(account: account, messageID: message.id) }
                catch { throw OutboxSendFailure.notAttempted }
                // Requesting is unconditional; the receipt switches only gate what we send back.
                _ = try await client.sendEncryptedMessage(to: message.chatID, envelope: envelope, id: message.id,
                                                          requestReceipt: true, markable: true)
            }
            try? await client.requestAcknowledgement()
        }, didChange: hooks.didChange)
        // Everything that is not a chat message rides one queue: reactions (plain, encrypted,
        // group) and key transports. Preparation seals; the flush re-validates and sends.
        let updates = try await encryption.prepareAvailableUpdates(account: account, transport: client)
        heldForTrust.formUnion(await hooks.hold(updates.blockedChats))
        var updateIDs = updates.messageIDs
        for update in try await store.queuedReactions(accountID: account) where joinedGroups.contains(update.chatID) {
            do {
                try await encryption.prepareGroupReaction(account: account, updateID: update.id, room: update.chatID, transport: client)
                updateIDs.insert(update.id)
            } catch {
                if error is CancellationError { throw error }
                heldForTrust.formUnion(await hooks.groupFailed(update.chatID, error))
            }
        }
        try await encryption.flushUpdates(account: account, updateIDs: updateIDs, groupTransport: client) { update, prepared in
            switch prepared {
            case .encrypted(let to, let envelope):
                // A legacy correction carries its reference outside the ciphertext; the sealed target is the reference.
                let replaces = update.kind == .correction && envelope.profile == .legacy ? update.targetWireID : nil
                _ = try await client.sendEncryptedMessage(to: to, envelope: envelope, id: update.id, replaces: replaces)
            case .group(let room, let envelope, let members):
                _ = try await client.sendEncryptedGroupMessage(room: room, envelope: envelope, id: update.id, expectedMembers: members)
            case .plainReaction(let to, let targetID, let reactions):
                _ = try await client.sendReaction(to: to, targetID: targetID, reactions: reactions, id: update.id)
            case .plainRetraction(let to, let targetID):
                _ = try await client.sendRetraction(to: to, targetID: targetID, id: update.id)
            case .plainReceipt(let to, let targetID, let kind):
                _ = try await client.sendReceipt(to: to, targetID: targetID, kind: kind, id: update.id)
            }
            try? await client.requestAcknowledgement()
        }
        return heldForTrust
    }
}
