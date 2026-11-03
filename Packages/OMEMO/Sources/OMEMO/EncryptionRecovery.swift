import Foundation
import MessageStore
import OMEMOCrypto
import XMPPProtocol

/// One account's encryption state that the current wrapping key cannot open.
public struct UnreadableEncryptionState: Sendable, Equatable {
    public let accountID: String
    /// The row's revision when it was assessed; `startOver` discards it only at this revision.
    public let revision: Int
    /// The device ID the lost identity is published under; nil means it cannot be retired automatically.
    public let deviceID: UInt32?
    public let loss: EncryptionLossCounts

    public init(accountID: String, revision: Int, deviceID: UInt32?, loss: EncryptionLossCounts) {
        self.accountID = accountID; self.revision = revision; self.deviceID = deviceID; self.loss = loss
    }
}

/// Plain-text counts of one account's data that depends on the lost key.
public struct EncryptionLossCounts: Sendable, Equatable {
    /// Retained ciphertext that would have been a message bubble; each becomes an unreadable placeholder. Key
    /// transports and other non-bubble rows are consumed and not counted.
    public let waitingMessages: Int
    /// Queued messages with a file and no prepared ciphertext: their key material was sealed, so they cannot be sent.
    public let unsendableFiles: Int
    public init(waitingMessages: Int, unsendableFiles: Int) { self.waitingMessages = waitingMessages; self.unsendableFiles = unsendableFiles }
}

extension OMEMOService {
    /// Every state row `protection` cannot open; every row when there is no key. Only a failed AES-GCM open counts:
    /// a row that opens but does not decode is not key loss.
    public static func unreadableStates(store: MessageStore, protection: StateProtection?) async throws -> [UnreadableEncryptionState] {
        var result: [UnreadableEncryptionState] = []
        for accountID in try await store.encryptionStateAccountIDs().sorted() {
            guard let row = try await store.encryptionState(accountID: accountID) else { continue }
            if let protection, (try? protection.open(row.data, account: accountID, sealedAs: row.sealedAccount)) != nil { continue }
            let bubbles = try await store.pendingEncryptedIncoming(accountID: accountID).filter { retainedWouldBeBubble($0.wire) }.count
            result.append(UnreadableEncryptionState(accountID: accountID, revision: row.revision, deviceID: row.deviceID,
                                                    loss: EncryptionLossCounts(waitingMessages: bubbles,
                                                                               unsendableFiles: try await store.unsendableFileCount(accountID: accountID))))
        }
        return result
    }

    /// Records the plain-text device ID of every row without one, so a later key loss can still retire it. Best
    /// effort per row: a row that does not decode is skipped rather than keeping storage closed for every account.
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

    /// User-confirmed reset after the wrapping key was lost. Discards exactly `states`, each only while unchanged and
    /// still unopenable, decides their retained ciphertext, and for `account` creates one identity shared by both
    /// profiles under a device ID no old or retired device used. Publishes nothing: the next `initialize` publishes
    /// bundles and drops retired IDs from the device lists. Requires the store's lease. Returns the new device ID, or
    /// nil when `account` had nothing to replace.
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
            // Never discard an identity this key can read: that would silently replace it.
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

    // Keys are gone, so nothing is decrypted: a would-be bubble becomes an `encryptionReset` placeholder; anything
    // else, including an undecodable row, only consumes its replay identity.
    private func retainedOutcomes(account: String) async throws -> (placeholders: [UnreadableMessage], consumed: [CiphertextIdentity]) {
        var placeholders: [UnreadableMessage] = []
        var consumed: [CiphertextIdentity] = []
        for item in try await store.pendingEncryptedIncoming(accountID: account) {
            let key = UnreadableMessage.Key.ciphertext(sender: item.sender, digest: item.digest)
            guard Self.retainedWouldBeBubble(item.wire) else {
                consumed.append(CiphertextIdentity(sender: item.sender, digest: item.digest))
                continue
            }
            if let group = try? JSONDecoder().decode(RetainedGroupEnvelope.self, from: item.wire) {
                placeholders.append(UnreadableMessage(accountID: account, chatID: group.message.room, senderID: group.message.sender,
                                                      isOutgoing: group.message.sender == account, sentAt: group.sentAt, reason: .encryptionReset, key: key))
            } else if let value = try? JSONDecoder().decode(RetainedEnvelope.self, from: item.wire) {
                placeholders.append(placeholder(for: Self.retainedMessage(value, digest: item.digest), account: account,
                                                reason: .encryptionReset, sentAt: value.sentAt, key: key))
            } else {
                consumed.append(CiphertextIdentity(sender: item.sender, digest: item.digest))
            }
        }
        return (placeholders, consumed)
    }

    // Decides as the retry pass does, so the recovery screen's count matches `retainedOutcomes`.
    static func retainedWouldBeBubble(_ wire: Data) -> Bool {
        if let group = try? JSONDecoder().decode(RetainedGroupEnvelope.self, from: wire) {
            return !group.recordsBubbleHint || expectsBubble(group.message)
        }
        guard let value = try? JSONDecoder().decode(RetainedEnvelope.self, from: wire) else { return false }
        return expectsBubble(retainedMessage(value, digest: ""))
    }

    private static func retainedMessage(_ value: RetainedEnvelope, digest: String) -> XMPPEncryptedMessage {
        XMPPEncryptedMessage(id: digest, from: value.from, to: value.to, originID: nil, envelope: value.envelope,
                             provenance: value.provenance, hasFallbackBody: value.expectsBubble ?? true, replaces: value.replaces)
    }

    static func newDeviceID(avoiding used: Set<UInt32>, random: () throws -> UInt32 = OMEMOEngine.randomDeviceID) throws -> UInt32 {
        while true {
            let id = try random()
            if !used.contains(id) { return id }
        }
    }
}
