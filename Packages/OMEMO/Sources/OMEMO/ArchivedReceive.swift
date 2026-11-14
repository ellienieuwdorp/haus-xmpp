import Foundation
import MessageStore
import OMEMOCrypto
import XMPPProtocol

/// One encrypted direct message from a validated archive page, with the archive's own time.
public struct ArchivedEncryptedMessage: Sendable {
    public let message: XMPPEncryptedMessage
    public let sentAt: Date?
    public init(message: XMPPEncryptedMessage, sentAt: Date?) { self.message = message; self.sentAt = sentAt }
}

extension OMEMOService {
    /// Consecutive archive entries under one hold of the gate. A message from an approved device decrypts with a kept
    /// engine and waits; the waiting ones commit with the state they leave in one transaction, at the end, every
    /// 100, and before anything else is written, so the store sees every write in archive order. Anything else takes
    /// `receive`'s path. Returns once every message is durable, as `receive` would leave it; a throw leaves nothing
    /// uncommitted, so the caller must not move its cursor.
    public func receiveArchived(account: String, messages: [ArchivedEncryptedMessage], transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.receiveArchivedLocked(account: account, messages: messages, transport: transport) }
    }

    private func receiveArchivedLocked(account: String, messages: [ArchivedEncryptedMessage], transport: any OMEMOTransport) async throws {
        let batch = ReceiveBatch()
        do {
            for item in messages {
                try Task.checkCancellation()
                // Only an exact copy of our own saved send matches, and it touches only that outbox row.
                if try await reconcileArchivedOutgoing(account: account, message: item.message) { continue }
                if try await stage(item, account: account, into: batch) {
                    if batch.commits.count >= ReceiveBatch.limit { try await commit(batch, account: account, transport: transport) }
                    continue
                }
                try await commit(batch, account: account, transport: transport)
                try await receiveArchivedOne(item, account: account, transport: transport)
            }
            try await commit(batch, account: account, transport: transport)
        } catch {
            // The held engines carry ratchet steps nothing durable matches.
            batch.reset()
            throw error
        }
    }

    // True when the message waits in `batch` or needs nothing written. False sends it down `receive`'s path, which
    // repeats every check here and writes whatever outcome it finds; nothing here is durable.
    private func stage(_ item: ArchivedEncryptedMessage, account: String, into batch: ReceiveBatch) async throws -> Bool {
        let message = item.message, sender = bare(message.from), profile = message.envelope.profile
        guard addressed(message, sender: sender, account: account) else { return false }
        if batch.base == nil { batch.base = try await load(account) }
        guard let base = batch.base else { return false }
        let state = base.state
        let localID = try batch.engines[profile]?.deviceID ?? localDeviceID(state, profile)
        if sender == account && message.envelope.senderDeviceID == localID { return true }
        let keys = message.envelope.keys.filter { $0.deviceID == localID && (profile == .legacy || $0.recipientJID == account) }
        guard keys.count == 1 else { return false }
        let key = keys[0], digest = try ciphertextDigest(message, key: key)
        // A device whose key changed resets its session on `receive`'s path.
        guard !batch.digests.contains([sender, digest]),
              try await !store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest),
              try await store.pendingEncryptedIncoming(accountID: account, sender: sender, digest: digest) == nil,
              let device = state.devices.last(where: { $0.jid == sender && $0.profile == profile && $0.deviceID == message.envelope.senderDeviceID }),
              device.trust.permitsEncryption, !device.identityChanged else { return false }
        let engine: OMEMOEngine
        if let held = batch.engines[profile] { engine = held } else {
            engine = try liveEngine(state, profile, account: account)
            batch.engines[profile] = engine
        }
        guard engine.deviceID == localID else { return false }
        let peer = sender == account ? bare(message.to ?? account) : sender
        let address = DeviceAddress(jid: sender, deviceID: device.deviceID)
        let decrypted: DecryptedIncoming
        try engine.beginChange()
        do {
            try engine.trustIdentity(device.identityKey, for: address)
            let material = try engine.decrypt(RatchetCiphertext(data: key.data, isPreKey: key.keyExchange), from: address)
            let context = IncomingContext(sender: sender, peer: peer, digest: digest, sentAt: item.sentAt ?? Date(), replaces: message.replaces)
            decrypted = try await interpret(material, message: message, account: account, context: context)
        } catch {
            try engine.revertChange()
            return false
        }
        engine.keepChange()
        batch.commits.append(EncryptedIncomingCommit(sender: sender, digest: digest, message: decrypted.stored, reaction: decrypted.reaction,
                                                     event: decrypted.event, archiveStanzaID: decrypted.stored == nil ? nil : message.archiveStanzaID,
                                                     readMarker: decrypted.readMarker,
                                                     queuesReceipt: queuesReceipt(decrypted, message: message, sender: sender, peer: peer, state: state)))
        batch.inputs.append(item)
        batch.digests.insert([sender, digest])
        if key.keyExchange {
            batch.preKeyProfiles.insert(profile)
            // One answer per device: it is encrypted after every message the batch read from that device.
            if !batch.answers.contains(where: { $0.address == address && $0.profile == profile }) { batch.answers.append((address, profile)) }
        }
        return true
    }

    // The provenance `receive` accepts: delivered to this account, or our own send to someone.
    private func addressed(_ message: XMPPEncryptedMessage, sender: String, account: String) -> Bool {
        guard !sender.isEmpty else { return false }
        switch message.provenance {
        case .direct, .receivedCarbon: return message.to.map({ bare($0) == account }) ?? true
        case .sentCarbon: return sender == account && message.to != nil
        }
    }

    // Commits what `batch` holds. When the commit fails nothing of it is durable and the dropped engines held its only
    // ratchet steps, so each message takes `receive`'s path from the stored state instead.
    private func commit(_ batch: ReceiveBatch, account: String, transport: any OMEMOTransport) async throws {
        guard let base = batch.base, !batch.commits.isEmpty else {
            if let base = batch.base {
                for (profile, engine) in batch.engines { park(engine, snapshot: base.state.engines[profile.rawValue], profile: profile, account: account) }
            }
            batch.reset()
            return
        }
        var state = base.state
        do {
            var controls: [EncryptionControl] = []
            for answer in batch.answers {
                guard let engine = batch.engines[answer.profile] else { throw OMEMOError.stateUnavailable }
                controls.append(try keyTransport(from: engine, to: answer.address, profile: answer.profile))
            }
            for (profile, engine) in batch.engines {
                try engine.replenishPreKeys()
                state.engines[profile.rawValue] = try engine.snapshot()
            }
            for profile in batch.preKeyProfiles { state.pendingBundlePublications.insert(profile.rawValue) }
            try await store.commitEncryptedIncoming(accountID: account, expectedRevision: base.revision, state: encode(state, account: account),
                                                    commits: batch.commits, controls: controls)
        } catch {
            let waiting = batch.inputs
            batch.reset()
            forgetState(account)
            if error is CancellationError { throw error }
            for item in waiting { try await receiveArchivedOne(item, account: account, transport: transport) }
            return
        }
        committed(state, revision: base.revision, account: account)
        for (profile, engine) in batch.engines { park(engine, snapshot: state.engines[profile.rawValue], profile: profile, account: account) }
        batch.reset()
    }
}

// Decrypted messages not yet committed and the engines holding their ratchet steps. Lives for one
// `receiveArchived` call; dropping it discards every step it held.
private final class ReceiveBatch {
    static let limit = 100
    var base: (revision: Int, state: AccountEncryptionState)?
    var engines: [XMPPOMEMOProfile: OMEMOEngine] = [:]
    var commits: [EncryptedIncomingCommit] = []
    var inputs: [ArchivedEncryptedMessage] = []
    var digests: Set<[String]> = []
    var answers: [(address: DeviceAddress, profile: XMPPOMEMOProfile)] = []
    var preKeyProfiles: Set<XMPPOMEMOProfile> = []

    func reset() {
        base = nil; engines = [:]; commits = []; inputs = []; digests = []; answers = []; preKeyProfiles = []
    }
}
