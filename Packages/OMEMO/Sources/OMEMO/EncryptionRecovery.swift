import Foundation
import MessageStore
import OMEMOCrypto
import XMPPProtocol

/// One account's encryption state that the current wrapping key cannot open (docs/development/key-recovery.md).
public struct UnreadableEncryptionState: Sendable, Equatable {
    public let accountID: String
    /// The row's revision when it was assessed; `startOver` discards it only at this revision.
    public let revision: Int
    /// The device ID the lost identity is published under, when a build recorded it; nil means it cannot be retired
    /// automatically.
    public let deviceID: UInt32?
    /// Plain-text counts of what depends on the lost key.
    public let loss: EncryptionLossCounts

    public init(accountID: String, revision: Int, deviceID: UInt32?, loss: EncryptionLossCounts) {
        self.accountID = accountID; self.revision = revision; self.deviceID = deviceID; self.loss = loss
    }
}

extension OMEMOService {
    /// Every state row `protection` cannot open; every row when there is no key at all. Only a failed AES-GCM open
    /// counts: a row that opens but does not decode is not key loss and is left to the ordinary errors.
    public static func unreadableStates(store: MessageStore, protection: StateProtection?) async throws -> [UnreadableEncryptionState] {
        var result: [UnreadableEncryptionState] = []
        for accountID in try await store.encryptionStateAccountIDs().sorted() {
            guard let row = try await store.encryptionState(accountID: accountID) else { continue }
            if let protection, (try? protection.open(row.data, account: accountID, sealedAs: row.sealedAccount)) != nil { continue }
            result.append(UnreadableEncryptionState(accountID: accountID, revision: row.revision, deviceID: row.deviceID,
                                                    loss: try await store.encryptionLossCounts(accountID: accountID)))
        }
        return result
    }

    /// Records the plain-text device ID of every row that has none yet, so a later key loss can still retire it.
    /// Opens each such row once; rows already recorded are not read. Best effort per row: this runs at every launch for
    /// every account, so a row that opens but does not decode is skipped and left to that account's own encryption
    /// errors instead of keeping storage closed for all of them.
    public func recordLocalDeviceIDs() async throws {
        try await gate.run {
            for accountID in try await self.store.encryptionStateAccountIDs() {
                guard let row = try await self.store.encryptionState(accountID: accountID), row.deviceID == nil else { continue }
                do {
                    let (_, state) = try await self.load(accountID)
                    try await self.store.recordEncryptionDeviceID(accountID: accountID, deviceID: try self.localDeviceID(state, .legacy))
                } catch is CancellationError { throw CancellationError() } catch { continue }
            }
        }
    }

    /// The explicit, user-confirmed start over after the wrapping key was lost. Discards exactly `states` (each only if
    /// it is unchanged and still cannot be opened with this service's key), decides every retained ciphertext of those
    /// accounts, and, when `account` is among them, creates its new identity under a device ID none of its old or
    /// retired devices used. Both profiles share the new identity, as `initialize` creates it. Nothing is published
    /// here: the next `initialize` publishes the bundles and takes the retired IDs out of the device lists. Requires the
    /// store's lease. Returns the new device ID, or nil when `account` had nothing to replace (it gets an identity from
    /// `initialize`, like any account without state).
    @discardableResult
    public func startOver(account: String?, discarding states: [UnreadableEncryptionState]) async throws -> UInt32? {
        try await gate.run { try await self.startOverLocked(account: account, discarding: states) }
    }

    private func startOverLocked(account: String?, discarding states: [UnreadableEncryptionState]) async throws -> UInt32? {
        guard !states.isEmpty else { throw OMEMOError.invalidContent }
        var discarded: [EncryptionReset.Discarded] = []
        var oldIDs: Set<UInt32> = []
        for item in states {
            guard let row = try await store.encryptionState(accountID: item.accountID), row.revision == item.revision else { throw OMEMOError.concurrentChange }
            // Never discard an identity this key can read: that would be the silent identity replacement the project forbids.
            guard (try? protection.open(row.data, account: item.accountID, sealedAs: row.sealedAccount)) == nil else { throw OMEMOError.stateReadable }
            if let id = row.deviceID { oldIDs.insert(id) }
            let outcomes = try await retainedOutcomes(account: item.accountID)
            discarded.append(EncryptionReset.Discarded(accountID: item.accountID, revision: row.revision,
                                                       placeholders: outcomes.placeholders, consumed: outcomes.consumed))
        }
        var replacement: EncryptionReset.Replacement?
        if let account, states.contains(where: { bare($0.accountID) == bare(account) }) {
            oldIDs.formUnion(try await store.retiredOwnDevices(accountID: account))
            let deviceID = try Self.newDeviceID(avoiding: oldIDs)
            let legacy = try OMEMOEngine(profile: .legacy, deviceID: deviceID)
            let modern = try OMEMOEngine(profile: .modern, sharingIdentityWith: legacy)
            let state = AccountEncryptionState(engines: ["legacy": try legacy.snapshot(), "modern": try modern.snapshot()])
            replacement = EncryptionReset.Replacement(accountID: account, deviceID: deviceID, data: try encode(state, account: account))
        }
        for item in states { forgetState(item.accountID) }
        if let account { forgetState(account) }
        try await store.resetEncryption(EncryptionReset(discarded: discarded, replacement: replacement))
        return replacement?.deviceID
    }

    /// The final outcome of each retained ciphertext of `account`, all encrypted for a device whose keys are gone: a
    /// would-be bubble becomes an `encryptionReset` placeholder (decided as the retry pass decides a bubble), anything
    /// else, including a row that does not decode, only consumes its replay identity. Nothing is decrypted.
    private func retainedOutcomes(account: String) async throws -> (placeholders: [UnreadableMessage], consumed: [CiphertextIdentity]) {
        var placeholders: [UnreadableMessage] = []
        var consumed: [CiphertextIdentity] = []
        for item in try await store.pendingEncryptedIncoming(accountID: account) {
            let key = UnreadableMessage.Key.ciphertext(sender: item.sender, digest: item.digest)
            if let group = try? JSONDecoder().decode(RetainedGroupEnvelope.self, from: item.wire) {
                if !group.recordsBubbleHint || Self.expectsBubble(group.message) {
                    placeholders.append(UnreadableMessage(accountID: account, chatID: group.message.room, senderID: group.message.sender,
                                                          isOutgoing: group.message.sender == account, sentAt: group.sentAt, reason: .encryptionReset, key: key))
                } else { consumed.append(CiphertextIdentity(sender: item.sender, digest: item.digest)) }
            } else if let value = try? JSONDecoder().decode(RetainedEnvelope.self, from: item.wire) {
                let message = XMPPEncryptedMessage(id: item.digest, from: value.from, to: value.to, originID: nil, envelope: value.envelope,
                                                   provenance: value.provenance, hasFallbackBody: value.expectsBubble ?? true, replaces: value.replaces)
                if Self.expectsBubble(message) {
                    placeholders.append(placeholder(for: message, account: account, reason: .encryptionReset, sentAt: value.sentAt, key: key))
                } else { consumed.append(CiphertextIdentity(sender: item.sender, digest: item.digest)) }
            } else {
                consumed.append(CiphertextIdentity(sender: item.sender, digest: item.digest))
            }
        }
        return (placeholders, consumed)
    }

    /// A device ID from `random` outside `avoiding`.
    static func newDeviceID(avoiding used: Set<UInt32>, random: () throws -> UInt32 = OMEMOEngine.randomDeviceID) throws -> UInt32 {
        while true {
            let id = try random()
            if !used.contains(id) { return id }
        }
    }
}
