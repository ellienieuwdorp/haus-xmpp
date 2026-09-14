import Foundation
import CryptoKit
import MessageStore
import OMEMOCrypto
import XMPPProtocol

public protocol OMEMOTransport: Sendable {
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32]
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws
}
extension XMPPClient: OMEMOTransport {}

/// UI-independent encryption/trust policy. Every operation loads an ephemeral engine, then
/// commits its snapshot with the resulting message/ciphertext. A thrown operation cannot advance
/// durable ratchets. There are no network calls or independent callbacks inside SQL transactions.
public actor OMEMOService {
    private let store: MessageStore
    private let protection: StateProtection
    private let gate = OperationGate()
    public init(store: MessageStore, protection: StateProtection) {
        self.store = store; self.protection = protection
    }

    public func initialize(account: String, transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.initializeLocked(account: account, transport: transport) }
    }

    private func initializeLocked(account: String, transport: any OMEMOTransport) async throws {
        if try await store.encryptionState(accountID: account) == nil {
            let deviceID = UInt32.random(in: 1...UInt32(Int32.max))
            let legacy = try OMEMOEngine(profile: .legacy, deviceID: deviceID)
            let modern = try OMEMOEngine(profile: .modern, sharingIdentityWith: legacy)
            let state = AccountEncryptionState(engines: ["legacy": try legacy.snapshot(), "modern": try modern.snapshot()])
            try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: encode(state, account: account))
        }
        let (_, identityState) = try await load(account)
        let legacyIdentity = try engine(identityState, .legacy)
        let modernIdentity = try engine(identityState, .modern)
        guard try OMEMOEngine.fingerprintBytes(for: legacyIdentity.identityKey, profile: .legacy) == OMEMOEngine.fingerprintBytes(for: modernIdentity.identityKey, profile: .modern), legacyIdentity.deviceID == modernIdentity.deviceID else {
            // Fail closed for early prototype databases that advertised inconsistent profiles.
            // Never repair this by silently replacing a published identity or prepared ciphertext.
            throw OMEMOError.stateUnavailable
        }
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let (revision, old) = try await load(account)
            var state = old
            let engine = try engine(state, profile)
            if try engine.rotateSignedPreKeyIfNeeded() {
                state.engines[profile.rawValue] = try engine.snapshot()
                try await save(state, revision: revision, account: account)
            }
            var devices = try await transport.fetchOMEMODevices(for: account, profile: profile)
            if devices.contains(engine.deviceID) {
                let published = try await transport.fetchOMEMOBundle(for: account, deviceID: engine.deviceID, profile: profile)
                guard published.identityKey == (try engine.identityKey) else { throw OMEMOError.identityChanged }
            }
            try await transport.publishOMEMOBundle(wireBundle(try engine.bundle(), profile: profile))
            if !devices.contains(engine.deviceID) { devices.append(engine.deviceID) }
            try await transport.publishOMEMODevices(devices.sorted(), profile: profile)
            let confirmed = try await transport.fetchOMEMODevices(for: account, profile: profile)
            guard confirmed.contains(engine.deviceID) else { throw OMEMOError.unavailable }
        }
    }

    public func refreshDevices(account: String, peer: String, profile: XMPPOMEMOProfile? = nil,
                               transport: any OMEMOTransport) async throws -> EncryptionOverview {
        try await gate.run { try await self.refreshLocked(account: account, peer: peer, profile: profile, transport: transport) }
    }

    private func refreshLocked(account: String, peer: String, profile requested: XMPPOMEMOProfile?,
                               transport: any OMEMOTransport, updateSelection: Bool = true) async throws -> EncryptionOverview {
        let (revision, old) = try await load(account)
        var state = old
        let profile: XMPPOMEMOProfile
        if let selected = requested ?? state.profiles[peer] { profile = selected }
        else {
            let legacy = try await transport.fetchOMEMODevices(for: peer, profile: .legacy)
            // Select a deployed profile once, never silently downgrade an existing conversation.
            profile = legacy.isEmpty ? .modern : .legacy
        }
        if updateSelection { state.profiles[peer] = profile }
        let local = try engine(state, profile)
        var incompatible = false
        for owner in Array(Set([account, peer])).sorted() {
            let ids = try await transport.fetchOMEMODevices(for: owner, profile: profile)
            guard ids.count <= 200 else { throw OMEMOError.invalidContent }
            let otherProfile: XMPPOMEMOProfile = profile == .legacy ? .modern : .legacy
            let otherIDs = try await transport.fetchOMEMODevices(for: owner, profile: otherProfile)
            // Device IDs are not proof of physical identity across profiles. Conservatively block
            // an advertised device that exists only in the other profile rather than omit it.
            if !Set(otherIDs).subtracting(ids).isEmpty { incompatible = true }
            for index in state.devices.indices where state.devices[index].jid == owner && state.devices[index].profile == profile {
                state.devices[index].active = false
            }
            for id in ids where !(owner == account && id == local.deviceID) {
                let bundle = try await transport.fetchOMEMOBundle(for: owner, deviceID: id, profile: profile)
                guard bundle.deviceID == id, bundle.profile == profile else { throw OMEMOError.invalidContent }
                if let index = state.devices.firstIndex(where: { $0.jid == owner && $0.profile == profile && $0.deviceID == id && $0.identityKey == bundle.identityKey }) {
                    let lastIdentity = state.devices.last { $0.jid == owner && $0.profile == profile && $0.deviceID == id }?.identityKey
                    var returning = state.devices.remove(at: index)
                    if lastIdentity != bundle.identityKey {
                        returning.trust = .undecided
                        returning.identityChanged = true
                    }
                    returning.active = true
                    // Last record for a scoped device tracks its most recently observed key, so
                    // A→B→A requires review once and then remains usable after explicit approval.
                    state.devices.append(returning)
                    state.bundles[returning.id] = bundle
                } else {
                    let changed = state.devices.contains { $0.jid == owner && $0.profile == profile && $0.deviceID == id }
                    let device = EncryptionDevice(jid: owner, profile: profile, deviceID: id, identityKey: bundle.identityKey,
                                                  trust: .undecided, active: true, identityChanged: changed)
                    state.devices.append(device)
                    state.bundles[device.id] = bundle
                }
            }
        }
        if updateSelection { state.incompatiblePeers[peer] = incompatible }
        try await save(state, revision: revision, account: account)
        return try overview(state, account: account, peer: peer, profileOverride: profile, incompatibleOverride: incompatible)
    }

    public func overview(account: String, peer: String) async throws -> EncryptionOverview {
        let (_, state) = try await load(account)
        return try overview(state, account: account, peer: peer)
    }

    private func overview(_ state: AccountEncryptionState, account: String, peer: String, profileOverride: XMPPOMEMOProfile? = nil, incompatibleOverride: Bool? = nil) throws -> EncryptionOverview {
        let profile = profileOverride ?? state.profiles[peer] ?? .legacy
        let local = try engine(state, profile)
        return EncryptionOverview(profile: profile, localDeviceID: local.deviceID,
                                  localFingerprint: try OMEMOEngine.fingerprintBytes(for: local.identityKey, profile: profile.crypto).map { String(format: "%02x", $0) }.joined(),
                                  devices: state.devices.filter { $0.profile == profile && ($0.jid == peer || $0.jid == account) },
                                  hasIncompatibleDevices: incompatibleOverride ?? state.incompatiblePeers[peer] ?? false)
    }

    /// The UI supplies the full fingerprint-scoped identifier it displayed, preventing a stale
    /// trust sheet from accepting a replacement key under the same numerical device ID.
    public func setTrust(account: String, deviceID: String, trust: DeviceTrust) async throws {
        try await gate.run {
            let (revision, old) = try await self.load(account)
            var state = old
            guard let index = state.devices.firstIndex(where: { $0.id == deviceID }), state.devices[index].active else { throw OMEMOError.identityChanged }
            state.devices[index].trust = trust
            try await self.save(state, revision: revision, account: account)
        }
    }

    public func prepareQueuedMessages(account: String, transport: any OMEMOTransport) async throws {
        let result = try await prepareAvailableMessages(account: account, transport: transport)
        if let failure = result.failure { throw failure }
    }

    /// One unavailable contact must not starve other chats. Only this returned, fixed set may be
    /// claimed by the sender; messages enqueued during network preparation wait for the next pass.
    public func prepareAvailableMessages(account: String, transport: any OMEMOTransport) async throws -> EncryptionPreparation {
        try await gate.run {
            let queued = try await self.store.queuedOutgoing(accountID: account)
            var ready = Set<String>()
            var blocked: [String: String] = [:]
            var firstFailure: OMEMOError?
            for message in queued {
                do {
                    try Task.checkCancellation()
                    let wire = try await self.store.encryptedOutgoing(accountID: account, messageID: message.id)
                    let saved = try wire.map { try JSONDecoder().decode(PreparedEnvelope.self, from: $0) }
                    let overview = try await self.refreshLocked(account: account, peer: message.chatID, profile: saved?.envelope.profile, transport: transport, updateSelection: saved == nil)
                    guard !overview.hasIncompatibleDevices else { throw OMEMOError.unsupportedProfile }
                    if let saved {
                        let (_, state) = try await self.load(account)
                        let candidates = state.devices.filter { $0.profile == saved.envelope.profile && $0.active && ($0.jid == message.chatID || $0.jid == account) }
                        guard !candidates.contains(where: { $0.trust == .undecided }) else { throw OMEMOError.trustRequired }
                        guard candidates.filter({ $0.trust.permitsEncryption }).map(\.id).sorted() == saved.recipientIdentities.sorted() else { throw OMEMOError.recipientSetChanged }
                    } else { try await self.sealLocked(message) }
                    ready.insert(message.id)
                } catch {
                    if error is CancellationError { throw error }
                    if firstFailure == nil { firstFailure = (error as? OMEMOError) ?? .unavailable }
                    blocked[message.chatID] = (error as? OMEMOError)?.errorDescription ?? "Encryption preparation failed. This message remains queued."
                }
            }
            return EncryptionPreparation(messageIDs: ready, blockedChats: blocked, failure: firstFailure)
        }
    }

    private func sealLocked(_ message: StoredMessage) async throws {
        let account = message.accountID
        let (revision, old) = try await load(account)
        var state = old
        guard let profile = state.profiles[message.chatID] else { throw OMEMOError.unavailable }
        guard state.incompatiblePeers[message.chatID] != true else { throw OMEMOError.unsupportedProfile }
        let recipients = state.devices.filter { $0.profile == profile && $0.active && ($0.jid == message.chatID || $0.jid == account) }
        guard !recipients.contains(where: { $0.trust == .undecided }) else { throw OMEMOError.trustRequired }
        let accepted = recipients.filter { $0.trust.permitsEncryption }
        let local = try engine(state, profile)
        guard message.chatID == account || accepted.contains(where: { $0.jid == message.chatID }) else { throw OMEMOError.noDevices }
        guard !accepted.isEmpty else { throw OMEMOError.noDevices }
        let plaintext = try EncryptedContent.encode(body: message.body, reply: message.reply, sender: account, recipient: message.chatID, modern: profile == .modern)
        let sealed = try PayloadCrypto.seal(plaintext, profile: profile.crypto)
        var keys: [XMPPOMEMOKey] = []
        for device in accepted {
            let address = DeviceAddress(jid: device.jid, deviceID: device.deviceID)
            guard let bundle = state.bundles[device.id] else { throw OMEMOError.unavailable }
            // Changed keys require an explicit trust decision above; that decision authorizes
            // dropping only this peer session, never the local identity or other devices.
            try local.trustIdentity(device.identityKey, for: address, resetSession: device.identityChanged)
            if let index = state.devices.firstIndex(where: { $0.id == device.id }) { state.devices[index].identityChanged = false }
            if !local.hasSession(with: address) {
                try local.establishSession(with: address, bundle: cryptoBundle(bundle))
            }
            let key = try local.encrypt(sealed.keyMaterial, to: address)
            keys.append(XMPPOMEMOKey(recipientJID: profile == .modern ? device.jid : nil, deviceID: device.deviceID, keyExchange: key.isPreKey, data: key.data))
        }
        let envelope = XMPPOMEMOEnvelope(profile: profile, senderDeviceID: local.deviceID, keys: keys, iv: sealed.iv, payload: sealed.payload)
        state.engines[profile.rawValue] = try local.snapshot()
        try await store.sealQueuedOutgoing(accountID: account, messageID: message.id, profile: profile.rawValue,
                                           expectedRevision: revision, state: encode(state, account: account), wire: JSONEncoder().encode(PreparedEnvelope(envelope: envelope, recipientIdentities: accepted.map(\.id))))
    }

    public func outgoingEnvelope(account: String, messageID: String) async throws -> XMPPOMEMOEnvelope {
        guard let wire = try await store.encryptedOutgoing(accountID: account, messageID: messageID) else { throw OMEMOError.unavailable }
        let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
        let (_, state) = try await load(account)
        let owners = Set(saved.recipientIdentities.compactMap { id in state.devices.first { $0.id == id }?.jid }).union([account])
        let current = state.devices.filter { owners.contains($0.jid) && $0.profile == saved.envelope.profile && $0.active }
        guard !current.contains(where: { $0.trust == .undecided }),
              current.filter({ $0.trust.permitsEncryption }).map(\.id).sorted() == saved.recipientIdentities.sorted() else { throw OMEMOError.recipientSetChanged }
        for id in saved.recipientIdentities {
            guard let device = state.devices.first(where: { $0.id == id }), device.active, device.trust.permitsEncryption else { throw OMEMOError.trustRequired }
        }
        return saved.envelope
    }

    /// Persist ciphertext before asking for keys/trust or attempting decryption. This also covers
    /// first-contact messages received before the user has reviewed the fingerprint sheet.
    public func receive(account: String, message: XMPPEncryptedMessage, transport: any OMEMOTransport) async throws -> Bool {
        try await gate.run { try await self.receiveLocked(account: account, message: message, transport: transport) }
    }

    private func receiveLocked(account: String, message: XMPPEncryptedMessage, transport: any OMEMOTransport) async throws -> Bool {
        let sender = bare(message.from)
        guard !sender.isEmpty else { throw OMEMOError.invalidContent }
        switch message.provenance {
        case .direct, .receivedCarbon:
            guard message.to.map({ bare($0) == account }) ?? true else { throw OMEMOError.invalidContent }
        case .sentCarbon:
            guard sender == account, message.to != nil else { throw OMEMOError.invalidContent }
        }
        let (_, initialState) = try await load(account)
        let initialEngine = try engine(initialState, message.envelope.profile)
        if sender == account && message.envelope.senderDeviceID == initialEngine.deviceID { return false }
        let addressedKeys = message.envelope.keys.filter { $0.deviceID == initialEngine.deviceID && (message.envelope.profile == .legacy || $0.recipientJID == account) }
        guard addressedKeys.count == 1 else { throw OMEMOError.notForThisDevice }
        let identity = IncomingCiphertextIdentity(profile: message.envelope.profile, senderDeviceID: message.envelope.senderDeviceID,
                                                  key: addressedKeys[0].data, iv: message.envelope.iv, payload: message.envelope.payload)
        let digestEncoder = JSONEncoder(); digestEncoder.outputFormatting = [.sortedKeys]
        let canonical = try digestEncoder.encode(identity)
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        if try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest) { return false }
        let retained = RetainedEnvelope(from: message.from, to: message.to, envelope: message.envelope, provenance: message.provenance)
        try await store.retainEncryptedIncoming(accountID: account, sender: sender, digest: digest, wire: JSONEncoder().encode(retained))
        let peer = sender == account ? bare(message.to ?? account) : sender
        _ = try await refreshLocked(account: account, peer: peer, profile: message.envelope.profile, transport: transport, updateSelection: false)
        let (revision, old) = try await load(account)
        var state = old
        let profile = message.envelope.profile
        let local = try engine(state, profile)
        let keys = message.envelope.keys.filter { $0.deviceID == local.deviceID && (profile == .legacy || $0.recipientJID == account) }
        guard keys.count == 1 else { throw OMEMOError.notForThisDevice }
        guard let device = state.devices.first(where: { $0.jid == sender && $0.profile == profile && $0.deviceID == message.envelope.senderDeviceID && $0.active }) else { throw OMEMOError.trustRequired }
        guard device.trust.permitsEncryption else { throw OMEMOError.trustRequired }
        let address = DeviceAddress(jid: sender, deviceID: device.deviceID)
        try local.trustIdentity(device.identityKey, for: address, resetSession: device.identityChanged)
        if let index = state.devices.firstIndex(where: { $0.id == device.id }) { state.devices[index].identityChanged = false }
        let key = keys[0]
        let material = try local.decrypt(RatchetCiphertext(data: key.data, isPreKey: key.keyExchange), from: address)
        var stored: StoredMessage?
        if let payload = message.envelope.payload {
            let plaintext = try PayloadCrypto.open(SealedPayload(payload: payload, keyMaterial: material, iv: message.envelope.iv), profile: profile.crypto)
            let content = try EncryptedContent.decode(plaintext, sender: sender, recipient: sender == account ? peer : account, modern: profile == .modern)
            stored = StoredMessage(id: UUID().uuidString, accountID: account, chatID: peer, senderID: sender,
                                   body: content.body, isOutgoing: sender == account, reply: content.reply, encryptionProfile: profile.rawValue)
        } else if profile == .modern {
            guard material == Data(repeating: 0, count: 32) else { throw OMEMOError.invalidContent }
        }
        var control: EncryptionControl?
        if key.keyExchange {
            let response = try local.encrypt(Data(repeating: 0, count: 32), to: address)
            let header = XMPPOMEMOKey(recipientJID: profile == .modern ? sender : nil, deviceID: device.deviceID, keyExchange: response.isPreKey, data: response.data)
            let responseEnvelope = XMPPOMEMOEnvelope(profile: profile, senderDeviceID: local.deviceID, keys: [header], iv: profile == .legacy ? Data(repeating: 0, count: 12) : nil, payload: nil)
            control = EncryptionControl(id: UUID().uuidString, recipient: sender, wire: try encodeWire(responseEnvelope))
        }
        try local.replenishPreKeys()
        state.engines[profile.rawValue] = try local.snapshot()
        try await store.commitEncryptedIncoming(accountID: account, sender: sender, digest: digest, expectedRevision: revision,
                                                state: encode(state, account: account), message: stored, control: control)
        if key.keyExchange { try await transport.publishOMEMOBundle(wireBundle(try local.bundle(), profile: profile)) }
        return stored != nil
    }

    public func retryPendingIncoming(account: String, transport: any OMEMOTransport) async throws {
        let pending = try await store.pendingEncryptedIncoming(accountID: account)
        var firstFailure: (any Error)?
        for item in pending {
            do {
                let value = try JSONDecoder().decode(RetainedEnvelope.self, from: item.wire)
                _ = try await receive(account: account, message: XMPPEncryptedMessage(id: item.digest, from: value.from, to: value.to, originID: nil, envelope: value.envelope, provenance: value.provenance), transport: transport)
            } catch {
                if error is CancellationError { throw error }
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    public func flushKeyTransports(account: String,
        send: @Sendable (String, String, XMPPOMEMOEnvelope) async throws -> Void) async throws {
        while !Task.isCancelled {
            guard let command = try await store.claimEncryptionControl(accountID: account) else { return }
            do {
                let envelope = try JSONDecoder().decode(XMPPOMEMOEnvelope.self, from: command.wire)
                try await send(command.recipient, command.id, envelope)
            } catch {
                try await store.finishEncryptionControl(accountID: account, id: command.id)
                throw error
            }
            try await store.finishEncryptionControl(accountID: account, id: command.id)
        }
    }

    private func load(_ account: String) async throws -> (Int, AccountEncryptionState) {
        guard let row = try await store.encryptionState(accountID: account) else { throw OMEMOError.unavailable }
        do {
            let state = try JSONDecoder().decode(AccountEncryptionState.self, from: protection.open(row.data, account: account))
            guard state.format == 1 else { throw OMEMOError.stateUnavailable }
            return (row.revision, state)
        } catch { throw OMEMOError.stateUnavailable }
    }
    private func encode(_ state: AccountEncryptionState, account: String) throws -> Data { try protection.seal(JSONEncoder().encode(state), account: account) }
    private func save(_ state: AccountEncryptionState, revision: Int, account: String) async throws {
        try await store.saveEncryptionState(accountID: account, expectedRevision: revision, data: encode(state, account: account))
    }
    private func engine(_ state: AccountEncryptionState, _ profile: XMPPOMEMOProfile) throws -> OMEMOEngine {
        guard let data = state.engines[profile.rawValue] else { throw OMEMOError.stateUnavailable }
        let engine = try OMEMOEngine(snapshot: data)
        guard engine.profile == profile.crypto else { throw OMEMOError.stateUnavailable }
        return engine
    }
    private func wireBundle(_ bundle: DeviceBundle, profile: XMPPOMEMOProfile) -> XMPPOMEMOBundle {
        XMPPOMEMOBundle(profile: profile, deviceID: bundle.deviceID, identityKey: bundle.identityKey,
                        signedPreKeyID: bundle.signedPreKeyID, signedPreKey: bundle.signedPreKey,
                        signedPreKeySignature: bundle.signedPreKeySignature, preKeys: bundle.preKeys)
    }
    private func cryptoBundle(_ bundle: XMPPOMEMOBundle) -> DeviceBundle {
        DeviceBundle(deviceID: bundle.deviceID, identityKey: bundle.identityKey, signedPreKeyID: bundle.signedPreKeyID,
                     signedPreKey: bundle.signedPreKey, signedPreKeySignature: bundle.signedPreKeySignature, preKeys: bundle.preKeys)
    }
    private func encodeWire(_ envelope: XMPPOMEMOEnvelope) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }
    private func bare(_ jid: String) -> String { String(jid.split(separator: "/", maxSplits: 1).first ?? "") }
}

private struct RetainedEnvelope: Codable {
    let from: String
    let to: String?
    let envelope: XMPPOMEMOEnvelope
    let provenance: XMPPMessageProvenance
}

private struct PreparedEnvelope: Codable {
    let envelope: XMPPOMEMOEnvelope
    let recipientIdentities: [String]
}

private struct IncomingCiphertextIdentity: Codable {
    let profile: XMPPOMEMOProfile
    let senderDeviceID: UInt32
    let key: Data
    let iv: Data?
    let payload: Data?
}
