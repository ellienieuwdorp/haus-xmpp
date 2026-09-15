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
    let store: MessageStore
    let protection: StateProtection
    let gate = OperationGate()
    public init(store: MessageStore, protection: StateProtection) {
        self.store = store; self.protection = protection
    }

    public func initialize(account: String, transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.initializeLocked(account: account, transport: transport) }
    }

    private func initializeLocked(account: String, transport: any OMEMOTransport) async throws {
        if try await store.encryptionState(accountID: account) == nil {
            let deviceID = try OMEMOEngine.randomDeviceID()
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
            let devices = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
            if devices.contains(engine.deviceID) {
                let published = try await transport.fetchOMEMOBundle(for: account, deviceID: engine.deviceID, profile: profile)
                guard published.identityKey == (try engine.identityKey) else { throw OMEMOError.identityChanged }
            }
            try await transport.publishOMEMOBundle(wireBundle(try engine.bundle(), profile: profile))
            // Bundle publication can take long enough for another client to register. Read
            // the latest list again before changing it, then confirm our own inclusion.
            try await maintainLocalAdvertisementLocked(account: account, profile: profile, transport: transport)
            let (publishedRevision, publishedOld) = try await load(account)
            if publishedOld.pendingBundlePublications.contains(profile.rawValue) {
                var published = publishedOld
                published.pendingBundlePublications.remove(profile.rawValue)
                try await save(published, revision: publishedRevision, account: account)
            }
        }
    }

    public func refreshDevices(account: String, peer: String, profile: XMPPOMEMOProfile? = nil,
                               transport: any OMEMOTransport) async throws -> EncryptionOverview {
        try await gate.run { try await self.refreshLocked(account: account, peer: peer, profile: profile, transport: transport) }
    }

    func refreshLocked(account: String, peer: String, profile requested: XMPPOMEMOProfile?,
                               transport: any OMEMOTransport, updateSelection: Bool = true) async throws -> EncryptionOverview {
        let (revision, old) = try await load(account)
        var state = old
        let profile: XMPPOMEMOProfile
        var probedEmpty = false
        if let selected = requested ?? state.profiles[peer] { profile = selected }
        else {
            let legacy = try await transport.fetchOMEMODevices(for: peer, profile: .legacy)
            // Select a deployed profile once, never silently downgrade an existing conversation.
            profile = legacy.isEmpty ? .modern : .legacy
            probedEmpty = legacy.isEmpty
        }
        var peerAdvertises = false
        let local = try engine(state, profile)
        var incompatible = false
        var unavailable: [String: Int] = [:]
        var advertised: [String: Int] = [:]
        for owner in Array(Set([account, peer])).sorted() {
            let ids = try validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: profile))
            guard ids.count <= 200 else { throw OMEMOError.invalidContent }
            if owner == peer, !ids.isEmpty { peerAdvertises = true }
            advertised[owner] = ids.count
            let otherProfile: XMPPOMEMOProfile = profile == .legacy ? .modern : .legacy
            // The other version only feeds the incompatibility hint; an unreadable list there must not block this one.
            let otherIDs = (try? validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: otherProfile))) ?? []
            // Device IDs are not proof of physical identity across profiles. Conservatively block
            // an advertised device that exists only in the other profile rather than omit it.
            if !Set(otherIDs).subtracting(ids).isEmpty { incompatible = true }
            for index in state.devices.indices where state.devices[index].jid == owner && state.devices[index].profile == profile {
                state.devices[index].active = false
            }
            for id in ids where !(owner == account && id == local.deviceID) {
                let bundle: XMPPOMEMOBundle
                do { bundle = try await transport.fetchOMEMOBundle(for: owner, deviceID: id, profile: profile) }
                catch XMPPIQError.stanza(condition: "item-not-found"), XMPPIQError.malformedResponse {
                    // Device lists in the wild carry stale IDs whose bundles are gone or unreadable. A device
                    // reviewed earlier keeps its stored key rather than vanishing on a server hiccup; an
                    // unknown one cannot be reviewed yet, so it is counted instead of failing the refresh.
                    if let index = state.devices.lastIndex(where: { $0.jid == owner && $0.profile == profile && $0.deviceID == id }) {
                        state.devices[index].active = true
                    } else { unavailable[owner, default: 0] += 1 }
                    continue
                }
                // A bundle that fails validation still fails closed: it must never deactivate a reviewed key.
                try validateBundle(bundle, id: id, profile: profile)
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
        // An empty probe (offline server, missing node) must not pin a version the peer never published.
        if updateSelection, !(probedEmpty && !peerAdvertises) { state.profiles[peer] = profile }
        if updateSelection { state.incompatiblePeers[peer] = incompatible }
        try await save(state, revision: revision, account: account)
        var result = try overview(state, account: account, peer: peer, profileOverride: profile, incompatibleOverride: incompatible)
        result.unavailableDevices = unavailable
        result.advertisedDevices = advertised
        return result
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

    /// Rebuilds only the session whose complete fingerprint the user selected. The
    /// upstream ratchet archives its old session so delayed messages can still decrypt;
    /// the device identity, prekeys, queued drafts and prepared ciphertext never change.
    public func repairSession(account: String, deviceID: String, transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.repairSessionLocked(account: account, deviceID: deviceID, transport: transport) }
    }

    private func repairSessionLocked(account: String, deviceID: String, transport: any OMEMOTransport) async throws {
        let (_, before) = try await load(account)
        guard let selected = before.devices.first(where: { $0.id == deviceID }),
              selected.active, selected.trust.permitsEncryption else { throw OMEMOError.trustRequired }
        _ = try await refreshLocked(account: account, peer: selected.jid,
                                        profile: selected.profile, transport: transport, updateSelection: false)
        let (revision, old) = try await load(account)
        var state = old
        guard let current = state.devices.first(where: { $0.id == deviceID }), current.active,
              current.trust.permitsEncryption,
              let bundle = state.bundles[deviceID] else { throw OMEMOError.identityChanged }
        let local = try engine(state, current.profile)
        let address = DeviceAddress(jid: current.jid, deviceID: current.deviceID)
        try local.trustIdentity(current.identityKey, for: address, resetSession: current.identityChanged)
        try local.establishSession(with: address, bundle: cryptoBundle(bundle))
        let key = try local.encrypt(Data(repeating: 0, count: 32), to: address)
        let header = XMPPOMEMOKey(recipientJID: current.profile == .modern ? current.jid : nil,
                                  deviceID: current.deviceID, keyExchange: key.isPreKey, data: key.data)
        let envelope = XMPPOMEMOEnvelope(profile: current.profile, senderDeviceID: local.deviceID,
                                         keys: [header], iv: current.profile == .legacy ? Data(repeating: 0, count: 12) : nil, payload: nil)
        state.engines[current.profile.rawValue] = try local.snapshot()
        if let index = state.devices.firstIndex(where: { $0.id == deviceID }) { state.devices[index].identityChanged = false }
        let control = EncryptionControl(id: UUID().uuidString, recipient: current.jid,
                                         wire: try encodeWire(envelope))
        try await store.saveEncryptionState(accountID: account, expectedRevision: revision,
                                                   data: encode(state, account: account), control: control)

    }

    /// Removes another own device from all profiles advertising the selected fingerprint.
    /// PEP is last-writer-wins: this performs fresh read/merge/confirmation, never claims a
    /// remote device was wiped, and never changes this installation's private identity.
    public func retireOwnDevice(account: String, deviceID: String, transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.retireOwnDeviceLocked(account: account, deviceID: deviceID, transport: transport) }
    }

    private func retireOwnDeviceLocked(account: String, deviceID: String, transport: any OMEMOTransport) async throws {
        let (_, old) = try await load(account)
        guard let selected = old.devices.first(where: { $0.id == deviceID }), selected.jid == account else {
            throw OMEMOError.invalidContent
        }
        let local = try engine(old, selected.profile)
        guard selected.deviceID != local.deviceID else { throw OMEMOError.cannotRetireCurrentDevice }
        let fingerprint = try OMEMOEngine.fingerprintBytes(for: selected.identityKey, profile: selected.profile.crypto)
        // Validate both public identities before the first mutation. A stale sheet must
        // not retire an unrelated replacement that reused this numerical device ID.
        var profiles: [XMPPOMEMOProfile] = []
        for profile in [selected.profile, selected.profile == .legacy ? .modern : .legacy] {
            let ids = try await validatedDevices(transport.fetchOMEMODevices(for: account, profile: profile))
            if ids.contains(selected.deviceID) {
                let bundle = try await transport.fetchOMEMOBundle(for: account, deviceID: selected.deviceID, profile: profile)
                try validateBundle(bundle, id: selected.deviceID, profile: profile)
                guard try OMEMOEngine.fingerprintBytes(for: bundle.identityKey, profile: profile.crypto) == fingerprint else {
                    throw OMEMOError.identityChanged
                }
            }
            profiles.append(profile)
        }
        for profile in profiles {
            var confirmed = false
            for _ in 0..<3 {
                let latest = try await validatedDevices(transport.fetchOMEMODevices(for: account, profile: profile))
                if !latest.contains(selected.deviceID) { confirmed = true; break }
                let bundle = try await transport.fetchOMEMOBundle(for: account, deviceID: selected.deviceID, profile: profile)
                guard try OMEMOEngine.fingerprintBytes(for: bundle.identityKey, profile: profile.crypto) == fingerprint else {
                    throw OMEMOError.identityChanged
                }
                try await transport.publishOMEMODevices(latest.filter { $0 != selected.deviceID }, profile: profile)
                let after = try await validatedDevices(transport.fetchOMEMODevices(for: account, profile: profile))
                if !after.contains(selected.deviceID) { confirmed = true; break }
            }
            guard confirmed else { throw OMEMOError.concurrentChange }
            let (revision, current) = try await load(account)
            var state = current
            for index in state.devices.indices where state.devices[index].jid == account
                && state.devices[index].profile == profile && state.devices[index].deviceID == selected.deviceID {
                state.devices[index].active = false
                state.devices[index].trust = .rejected
            }
            try await save(state, revision: revision, account: account)
        }

    }

    /// Call after an own-account PEP update. A racing publication that omitted this device
    /// is repaired by merging into the newest server list, not by replaying a cached list.
    public func maintainLocalAdvertisement(account: String, profile: XMPPOMEMOProfile, transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.maintainLocalAdvertisementLocked(account: account, profile: profile, transport: transport) }
    }

    private func maintainLocalAdvertisementLocked(account: String, profile: XMPPOMEMOProfile, transport: any OMEMOTransport) async throws {
        let (_, state) = try await load(account)
        let local = try engine(state, profile)
        for _ in 0..<3 {
            let latest = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
            if latest.contains(local.deviceID) { return }
            guard latest.count < 200 else { throw OMEMOError.invalidContent }
            try await transport.publishOMEMODevices((latest + [local.deviceID]).sorted(), profile: profile)
            let confirmed = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
            if confirmed.contains(local.deviceID) { return }
        }
        throw OMEMOError.concurrentChange
    }

    public func flushBundlePublications(account: String, transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.flushBundlePublicationsLocked(account: account, transport: transport) }
    }

    func flushBundlePublicationsLocked(account: String, transport: any OMEMOTransport) async throws {
        let (_, initial) = try await load(account)
        for name in initial.pendingBundlePublications.sorted() {
            guard let profile = XMPPOMEMOProfile(rawValue: name) else { throw OMEMOError.stateUnavailable }
            let (revision, old) = try await load(account)
            let local = try engine(old, profile)
            try await transport.publishOMEMOBundle(wireBundle(try local.bundle(), profile: profile))
            var state = old
            state.pendingBundlePublications.remove(name)
            try await save(state, revision: revision, account: account)
        }
    }

    func validatedDevices(_ ids: [UInt32]) throws -> [UInt32] {
        guard ids.count <= 200, Set(ids).count == ids.count,
              ids.allSatisfy({ $0 > 0 && $0 <= Int32.max }) else { throw OMEMOError.invalidContent }
        return ids
    }

    private func validateBundle(_ bundle: XMPPOMEMOBundle, id: UInt32, profile: XMPPOMEMOProfile) throws {
        let width = profile == .legacy ? 33 : 32
        guard bundle.deviceID == id, bundle.profile == profile,
              bundle.signedPreKeyID > 0, bundle.signedPreKeyID <= Int32.max,
              bundle.identityKey.count == width, bundle.signedPreKey.count == width,
              !bundle.preKeys.isEmpty, bundle.preKeys.count <= 1000,
              bundle.preKeys.allSatisfy({ $0.key > 0 && $0.key <= Int32.max && $0.value.count == width }),
              try OMEMOEngine.verifySignature(bundle.signedPreKeySignature, for: bundle.signedPreKey,
                                              identityKey: bundle.identityKey, profile: profile.crypto)
        else { throw OMEMOError.invalidContent }
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
            let (_, currentState) = try await self.load(account)
            for message in queued where currentState.groupRooms[message.chatID] == nil {
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
        let plaintext = try EncryptedContent.encode(body: message.body, reply: message.reply,
                                                    sender: account, recipient: message.chatID, modern: profile == .modern,
                                                    originID: message.id)
        let saved = try sealContent(plaintext, account: account, peer: message.chatID, profile: profile, state: &state)
        try await store.sealQueuedOutgoing(accountID: account, messageID: message.id, profile: profile.rawValue,
                                           expectedRevision: revision, state: encode(state, account: account), wire: JSONEncoder().encode(saved))
    }

    private func sealContent(_ plaintext: Data, account: String, peer: String, profile: XMPPOMEMOProfile,
                             state: inout AccountEncryptionState) throws -> PreparedEnvelope {
        let recipients = state.devices.filter { $0.profile == profile && $0.active && ($0.jid == peer || $0.jid == account) }
        guard !recipients.contains(where: { $0.trust == .undecided }) else { throw OMEMOError.trustRequired }
        let accepted = recipients.filter { $0.trust.permitsEncryption }
        guard peer == account || accepted.contains(where: { $0.jid == peer }) else { throw OMEMOError.noDevices }
        guard !accepted.isEmpty else { throw OMEMOError.noDevices }
        return try sealForRecipients(plaintext, profile: profile, accepted: accepted, state: &state)
    }

    func sealForRecipients(_ plaintext: Data, profile: XMPPOMEMOProfile, accepted: [EncryptionDevice],
                           state: inout AccountEncryptionState) throws -> PreparedEnvelope {
        guard !accepted.isEmpty, accepted.count <= 1024 else { throw OMEMOError.noDevices }
        let local = try engine(state, profile)
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
        return PreparedEnvelope(envelope: envelope, recipientIdentities: accepted.map(\.id))
    }

    /// Records a full replacement set (including an empty set to clear) for one
    /// authenticated modern message. There is no legacy/XML-in-body fallback.
    @discardableResult
    public func queueReactions(account: String, chatID: String, messageID: String, reactions: [String]) async throws -> String {
        try await gate.run { try await self.queueReactionsLocked(account: account, chatID: chatID, messageID: messageID, reactions: reactions) }
    }

    private func queueReactionsLocked(account: String, chatID: String, messageID: String, reactions: [String]) async throws -> String {
        let (_, state) = try await load(account)
        if state.groupRooms[chatID] != nil {
            return try await queueGroupReactionsLocked(account: account, room: chatID, messageID: messageID, reactions: reactions)
        }
        guard state.profiles[chatID] == .modern,
              let target = try await store.message(accountID: account, messageID: messageID),
              target.chatID == chatID, target.encryptionProfile == XMPPOMEMOProfile.modern.rawValue,
              target.wireIDAuthenticated, let wireID = target.wireID,
              let unique = try await store.reactionTarget(accountID: account, chatID: chatID, wireID: wireID), unique.id == target.id
        else { throw OMEMOError.unsupportedEncryptedReactions }
        let values = try ReactionContent.normalized(reactions)
        let update = StoredReactionUpdate(id: UUID().uuidString, accountID: account, chatID: chatID,
                                           targetMessageID: messageID, targetWireID: wireID, actorID: account,
                                           reactions: values, createdAt: Date())
        _ = try await store.enqueueReaction(update)
        return update.id
    }

    public func prepareAvailableReactions(account: String, transport: any OMEMOTransport) async throws -> EncryptionPreparation {
        try await gate.run { try await self.prepareReactionsLocked(account: account, transport: transport) }
    }

    private func prepareReactionsLocked(account: String, transport: any OMEMOTransport) async throws -> EncryptionPreparation {
        let queued = try await store.queuedReactions(accountID: account)
        var ready = Set<String>(), blocked: [String: String] = [:]
        var failure: OMEMOError?
        for update in queued {
            do {
                try Task.checkCancellation()
                let (_, selected) = try await load(account)
                if selected.groupRooms[update.chatID] != nil { continue }
                guard selected.profiles[update.chatID] == .modern else { throw OMEMOError.unsupportedEncryptedReactions }
                let overview = try await refreshLocked(account: account, peer: update.chatID, profile: .modern,
                                                       transport: transport, updateSelection: false)
                guard !overview.hasIncompatibleDevices else { throw OMEMOError.unsupportedProfile }
                if let wire = try await store.encryptedReaction(accountID: account, updateID: update.id) {
                    let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
                    let (_, state) = try await load(account)
                    try validatePrepared(saved, state: state, account: account)
                } else {
                    let (revision, old) = try await load(account)
                    var state = old
                    let plaintext = try EncryptedContent.encodeReaction(targetWireID: update.targetWireID,
                                                                         reactions: update.reactions, sender: account,
                                                                         recipient: update.chatID, originID: update.id, modern: true)
                    let saved = try sealContent(plaintext, account: account, peer: update.chatID, profile: .modern, state: &state)
                    try await store.sealQueuedReaction(accountID: account, updateID: update.id, expectedRevision: revision,
                                                        state: encode(state, account: account), wire: JSONEncoder().encode(saved))
                }
                ready.insert(update.id)
            } catch {
                if error is CancellationError { throw error }
                if failure == nil { failure = (error as? OMEMOError) ?? .unavailable }
                blocked[update.chatID] = (error as? OMEMOError)?.errorDescription ?? "The private reaction remains queued."
            }
        }
        return EncryptionPreparation(messageIDs: ready, blockedChats: blocked, failure: failure)
    }

    public func outgoingReactionEnvelope(account: String, updateID: String) async throws -> XMPPOMEMOEnvelope {
        guard let wire = try await store.encryptedReaction(accountID: account, updateID: updateID),
              let update = try await store.reactionUpdate(accountID: account, updateID: updateID) else { throw OMEMOError.unavailable }
        guard try await store.reactionTarget(accountID: account, chatID: update.chatID, wireID: update.targetWireID)?.id == update.targetMessageID else {
            throw OMEMOError.unsupportedEncryptedReactions
        }
        let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
        guard saved.groupMembers == nil else { throw OMEMOError.unsupportedProfile }
        let (_, state) = try await load(account)
        try validatePrepared(saved, state: state, account: account)
        return saved.envelope
    }

    /// Transport ownership is enforced by MessageStore. A preflight failure releases the
    /// claim; an attempted send stays unconfirmed until SM/archive proves acceptance.
    public func flushPreparedReactions(account: String, preparedIDs: Set<String>,
        send: @Sendable (String, String, XMPPOMEMOEnvelope) async throws -> Void) async throws {
        while !Task.isCancelled {
            guard let claim = try await store.claimNextReaction(accountID: account, updateIDs: preparedIDs) else { return }
            let envelope: XMPPOMEMOEnvelope
            do {
                try Task.checkCancellation()
                envelope = try await outgoingReactionEnvelope(account: account, updateID: claim.update.id)
            } catch {
                try await store.releaseUnsentReactionSubmission(accountID: account, updateID: claim.update.id, attemptID: claim.attemptID)
                throw error
            }
            do {
                try await send(claim.update.chatID, claim.update.id, envelope)
            } catch {
                _ = try await store.finishReactionSubmission(accountID: account, updateID: claim.update.id, attemptID: claim.attemptID)
                throw error
            }
            _ = try await store.finishReactionSubmission(accountID: account, updateID: claim.update.id, attemptID: claim.attemptID)
        }
    }

    public func retryReaction(account: String, updateID: String) async throws {
        try await store.retryReaction(accountID: account, updateID: updateID)
    }

    public func reactions(account: String, chatID: String, messageID: String) async throws -> [AuthenticatedReaction] {
        try await store.reactions(accountID: account, chatID: chatID, messageID: messageID)
    }

    public func outgoingEnvelope(account: String, messageID: String) async throws -> XMPPOMEMOEnvelope {
        guard let wire = try await store.encryptedOutgoing(accountID: account, messageID: messageID) else { throw OMEMOError.unavailable }
        let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
        guard saved.groupMembers == nil else { throw OMEMOError.unsupportedProfile }
        let (_, state) = try await load(account)
        try validatePrepared(saved, state: state, account: account)
        return saved.envelope
    }

    private func validatePrepared(_ saved: PreparedEnvelope, state: AccountEncryptionState, account: String) throws {
        let owners = Set(saved.recipientIdentities.compactMap { id in state.devices.first { $0.id == id }?.jid }).union([account])
        let current = state.devices.filter { owners.contains($0.jid) && $0.profile == saved.envelope.profile && $0.active }
        guard !current.contains(where: { $0.trust == .undecided }),
              current.filter({ $0.trust.permitsEncryption }).map(\.id).sorted() == saved.recipientIdentities.sorted() else { throw OMEMOError.recipientSetChanged }
        for id in saved.recipientIdentities {
            guard let device = state.devices.first(where: { $0.id == id }), device.active, device.trust.permitsEncryption else { throw OMEMOError.trustRequired }
        }
    }


    /// SM may retransmit only the exact, already prepared message and only while its
    /// fingerprint-scoped recipient policy is still valid. Header-only controls currently
    /// return false; they do not carry a saved recipient fingerprint set.
    public func canReplayEncryptedMessage(account: String, messageID: String, recipient: String,
                                          envelope: XMPPOMEMOEnvelope) async throws -> Bool {
        if let wire = try await store.encryptedOutgoing(accountID: account, messageID: messageID) {
            let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
            guard saved.groupMembers == nil, let intention = try await store.message(accountID: account, messageID: messageID),
                  intention.isOutgoing, intention.senderID == account,
                  intention.chatID == bare(recipient), saved.envelope == envelope else { return false }
            do { return try await outgoingEnvelope(account: account, messageID: messageID) == envelope }
            catch let error as OMEMOError where error == .trustRequired || error == .recipientSetChanged || error == .unsupportedEncryptedReactions { return false }
        }
        if let wire = try await store.encryptedReaction(accountID: account, updateID: messageID) {
            let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
            guard saved.groupMembers == nil, let update = try await store.reactionUpdate(accountID: account, updateID: messageID),
                  update.actorID == account, update.chatID == bare(recipient), saved.envelope == envelope else { return false }
            do { return try await outgoingReactionEnvelope(account: account, updateID: messageID) == envelope }
            catch let error as OMEMOError where error == .trustRequired || error == .recipientSetChanged || error == .unsupportedEncryptedReactions { return false }
        }
        return false
    }

    /// Invoke only for the stanza inside a validated own-server archive wrapper. An exact
    /// ciphertext match proves this is our saved send, so untrusted outer IDs alone cannot
    /// promote an outgoing intention to server acceptance. Live echoes are not callers.
    public func reconcileArchivedOutgoing(account: String, message: XMPPEncryptedMessage) async throws -> Bool {
        guard message.provenance == .sentCarbon, bare(message.from) == account, let recipient = message.to else { return false }
        let (_, state) = try await load(account)
        let local = try engine(state, message.envelope.profile)
        guard message.envelope.senderDeviceID == local.deviceID else { return false }
        if let intention = try await store.message(accountID: account, messageID: message.id),
           intention.isOutgoing, intention.senderID == account, intention.chatID == bare(recipient),
           let wire = try await store.encryptedOutgoing(accountID: account, messageID: message.id) {
            let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
            guard saved.envelope == message.envelope else { return false }
            return try await store.reconcileArchivedOutgoing(accountID: account, messageID: message.id, expectedEncryptedWire: wire)
        }
        if let update = try await store.reactionUpdate(accountID: account, updateID: message.id),
           update.actorID == account, update.chatID == bare(recipient),
           let wire = try await store.encryptedReaction(accountID: account, updateID: message.id) {
            let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
            guard saved.envelope == message.envelope else { return false }
            return try await store.reconcileArchivedReaction(accountID: account, updateID: message.id, expectedEncryptedWire: wire)
        }
        return false
    }

    /// Persist ciphertext before asking for keys/trust or attempting decryption. This also covers
    /// first-contact messages received before the user has reviewed the fingerprint sheet.
    /// `sentAt` must come from a validated archive/delivery context, never a peer-supplied
    /// outer delay element. It can correct a retained live arrival timestamp before retry.
    public func receive(account: String, message: XMPPEncryptedMessage, transport: any OMEMOTransport, sentAt: Date? = nil) async throws -> Bool {
        try await gate.run { try await self.receiveLocked(account: account, message: message, sentAt: sentAt, transport: transport) }
    }

    private func receiveLocked(account: String, message: XMPPEncryptedMessage, sentAt: Date?, transport: any OMEMOTransport) async throws -> Bool {
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
        let digest = try ciphertextDigest(message, key: addressedKeys[0])
        if try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest) { return false }
        let previous = try await store.pendingEncryptedIncoming(accountID: account).first { $0.sender == sender && $0.digest == digest }
        var retained = try previous.map { try JSONDecoder().decode(RetainedEnvelope.self, from: $0.wire) }
            ?? RetainedEnvelope(from: message.from, to: message.to, envelope: message.envelope, provenance: message.provenance, sentAt: sentAt ?? Date())
        if let previous, let sentAt, retained.sentAt != sentAt {
            // The cipher digest identifies the addressed key/payload. Require the entire
            // envelope and conversation context too before changing durable metadata.
            let retainedRecipient: String
            switch retained.provenance {
            case .direct, .receivedCarbon:
                // Authenticated MAM changes direct delivery into received-carbon provenance
                // and may restore an omitted local `to`. Both represent this same account.
                guard retained.to.map({ bare($0) == account }) ?? true else { throw OMEMOError.invalidContent }
                retainedRecipient = account
            case .sentCarbon:
                guard bare(retained.from) == account, let recipient = retained.to else { throw OMEMOError.invalidContent }
                retainedRecipient = bare(recipient)
            }
            guard retained.envelope == message.envelope, bare(retained.from) == sender,
                  retainedRecipient == (message.to.map(bare) ?? account) else {
                throw OMEMOError.invalidContent
            }
            retained = RetainedEnvelope(from: retained.from, to: retained.to, envelope: retained.envelope,
                                        provenance: retained.provenance, sentAt: sentAt)
            guard try await store.replacePendingEncryptedIncomingContext(accountID: account, sender: sender, digest: digest,
                    expectedWire: previous.wire, wire: JSONEncoder().encode(retained)) else { throw OMEMOError.concurrentChange }
        }
        try await store.retainEncryptedIncoming(accountID: account, sender: sender, digest: digest, wire: JSONEncoder().encode(retained))
        let peer = sender == account ? bare(message.to ?? account) : sender
        // An authenticated session or an already approved sender identity does not need
        // PEP availability to decrypt. Inactive approved devices may have delayed traffic.
        // Unknown identities still require network discovery and explicit user approval.
        let known = initialState.devices.last {
            $0.jid == sender && $0.profile == message.envelope.profile
                && $0.deviceID == message.envelope.senderDeviceID
        }
        if known == nil {
            _ = try await refreshLocked(account: account, peer: peer, profile: message.envelope.profile, transport: transport, updateSelection: false)
        }
        let (revision, old) = try await load(account)
        var state = old
        let profile = message.envelope.profile
        let local = try engine(state, profile)
        let keys = message.envelope.keys.filter { $0.deviceID == local.deviceID && (profile == .legacy || $0.recipientJID == account) }
        guard keys.count == 1 else { throw OMEMOError.notForThisDevice }
        guard let device = state.devices.last(where: { $0.jid == sender && $0.profile == profile && $0.deviceID == message.envelope.senderDeviceID }) else { throw OMEMOError.trustRequired }
        guard device.trust.permitsEncryption else { throw OMEMOError.trustRequired }
        let address = DeviceAddress(jid: sender, deviceID: device.deviceID)
        try local.trustIdentity(device.identityKey, for: address, resetSession: device.identityChanged)
        if let index = state.devices.firstIndex(where: { $0.id == device.id }) { state.devices[index].identityChanged = false }
        let key = keys[0]
        let material = try local.decrypt(RatchetCiphertext(data: key.data, isPreKey: key.keyExchange), from: address)
        var stored: StoredMessage?
        var reaction: AuthenticatedReaction?
        if let payload = message.envelope.payload {
            let plaintext = try PayloadCrypto.open(SealedPayload(payload: payload, keyMaterial: material, iv: message.envelope.iv), profile: profile.crypto)
            let content = try EncryptedContent.decode(plaintext, sender: sender, recipient: sender == account ? peer : account,
                                                       modern: profile == .modern, sendingTime: retained.sentAt)
            if !content.body.isEmpty {
                stored = StoredMessage(id: UUID().uuidString, accountID: account, chatID: peer, senderID: sender,
                                       body: content.body, sentAt: retained.sentAt ?? Date(), isOutgoing: sender == account,
                                       reply: content.reply, encryptionProfile: profile.rawValue,
                                       wireID: content.originID, wireIDAuthenticated: content.originID != nil)
            }
            if let update = content.reaction {
                guard profile == .modern, sender == account || sender == peer else { throw OMEMOError.invalidContent }
                let date = min(content.timestamp ?? retained.sentAt ?? Date(), Date())
                reaction = AuthenticatedReaction(id: content.originID ?? digest, chatID: peer, actorID: sender,
                                                 targetWireID: update.targetWireID, reactions: update.reactions, updatedAt: date)
            }
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
        if key.keyExchange { state.pendingBundlePublications.insert(profile.rawValue) }
        try await store.commitEncryptedIncoming(accountID: account, sender: sender, digest: digest, expectedRevision: revision,
                                                state: encode(state, account: account), message: stored, control: control, reaction: reaction)
        // The authenticated message is already durable. A network error must not turn
        // success into a decryption failure; the pending publication survives a restart.
        if key.keyExchange { try? await flushBundlePublicationsLocked(account: account, transport: transport) }
        return stored != nil || reaction != nil
    }

    /// A stream/archive acknowledgment is safe after either an authenticated commit or
    /// durable retention for later key/trust review. A storage error must not advance it.
    /// This deliberately uses the same ciphertext identity as receive, not outer stanza IDs.
    public func hasDurableIncomingDisposition(account: String, message: XMPPEncryptedMessage) async throws -> Bool {
        let (_, state) = try await load(account)
        let local = try engine(state, message.envelope.profile)
        let sender = bare(message.from)
        guard !sender.isEmpty else { return false }
        switch message.provenance {
        case .direct, .receivedCarbon:
            guard message.to.map({ bare($0) == account }) ?? true else { return false }
        case .sentCarbon:
            guard sender == account, message.to != nil else { return false }
        }
        if sender == account && message.envelope.senderDeviceID == local.deviceID { return true }
        let keys = message.envelope.keys.filter {
            $0.deviceID == local.deviceID && (message.envelope.profile == .legacy || $0.recipientJID == account)
        }
        // Old archives can predate this installation. A valid envelope with no key for
        // this device is an intentional non-recipient disposition, not recoverable work.
        // Ambiguous duplicate keys still fail closed instead of silently selecting one.
        if keys.isEmpty { return true }
        guard keys.count == 1 else { return false }
        let digest = try ciphertextDigest(message, key: keys[0])
        if try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest) { return true }
        return try await store.pendingEncryptedIncoming(accountID: account).contains {
            $0.sender == sender && $0.digest == digest
        }
    }

    func ciphertextDigest(_ message: XMPPEncryptedMessage, key: XMPPOMEMOKey) throws -> String {
        let identity = IncomingCiphertextIdentity(profile: message.envelope.profile,
                                                  senderDeviceID: message.envelope.senderDeviceID,
                                                  key: key.data, iv: message.envelope.iv, payload: message.envelope.payload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    /// Conversation addresses/counts only; retained ciphertext is not authenticated display content.
    /// This lets first-contact trust requests remain discoverable without inventing message bubbles.
    public func pendingConversations(account: String) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for item in try await store.pendingEncryptedIncoming(accountID: account) {
            if let group = try? JSONDecoder().decode(RetainedGroupEnvelope.self, from: item.wire) {
                guard group.message.sender == item.sender else { continue }
                result[group.message.room, default: 0] += 1
                continue
            }
            let value = try JSONDecoder().decode(RetainedEnvelope.self, from: item.wire)
            guard let sender = boundedBareJID(value.from), sender == item.sender else { continue }
            switch value.provenance {
            case .direct, .receivedCarbon:
                guard value.to.map({ boundedBareJID($0) == account }) ?? true else { continue }
            case .sentCarbon:
                guard sender == account, value.to != nil else { continue }
            }
            guard let peer = sender == account ? value.to.flatMap(boundedBareJID) : sender else { continue }
            result[peer, default: 0] += 1
        }
        return result
    }

    public func retryPendingIncoming(account: String, transport: any OMEMOTransport) async throws {
        let pending = try await store.pendingEncryptedIncoming(accountID: account)
        var firstFailure: (any Error)?
        for item in pending {
            do {
                if let group = try? JSONDecoder().decode(RetainedGroupEnvelope.self, from: item.wire) {
                    if let groupTransport = transport as? any OMEMOGroupTransport {
                        _ = try await receiveGroup(account: account, message: group.message, transport: groupTransport, sentAt: group.sentAt)
                    }
                    continue
                }
                let value = try JSONDecoder().decode(RetainedEnvelope.self, from: item.wire)
                _ = try await receive(account: account, message: XMPPEncryptedMessage(id: item.digest, from: value.from, to: value.to, originID: nil, envelope: value.envelope, provenance: value.provenance), transport: transport, sentAt: value.sentAt)
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

    func load(_ account: String) async throws -> (Int, AccountEncryptionState) {
        guard let row = try await store.encryptionState(accountID: account) else { throw OMEMOError.unavailable }
        do {
            let state = try JSONDecoder().decode(AccountEncryptionState.self, from: protection.open(row.data, account: account))
            guard state.format == 1 else { throw OMEMOError.stateUnavailable }
            return (row.revision, state)
        } catch { throw OMEMOError.stateUnavailable }
    }
    func encode(_ state: AccountEncryptionState, account: String) throws -> Data { try protection.seal(JSONEncoder().encode(state), account: account) }
    func save(_ state: AccountEncryptionState, revision: Int, account: String) async throws {
        try await store.saveEncryptionState(accountID: account, expectedRevision: revision, data: encode(state, account: account))
    }
    func engine(_ state: AccountEncryptionState, _ profile: XMPPOMEMOProfile) throws -> OMEMOEngine {
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
    func cryptoBundle(_ bundle: XMPPOMEMOBundle) -> DeviceBundle {
        DeviceBundle(deviceID: bundle.deviceID, identityKey: bundle.identityKey, signedPreKeyID: bundle.signedPreKeyID,
                     signedPreKey: bundle.signedPreKey, signedPreKeySignature: bundle.signedPreKeySignature, preKeys: bundle.preKeys)
    }
    func encodeWire(_ envelope: XMPPOMEMOEnvelope) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }
    private func boundedBareJID(_ jid: String) -> String? {
        guard !jid.isEmpty, jid.utf8.count <= 3_071,
              !jid.contains(where: { $0.isWhitespace || $0.isNewline }),
              jid.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f && $0.value != 0xfffe && $0.value != 0xffff }) else { return nil }
        let value = String(jid.prefix { $0 != "/" })
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return value
    }
    func bare(_ jid: String) -> String { String(jid.split(separator: "/", maxSplits: 1).first ?? "") }
}

private struct RetainedEnvelope: Codable {
    let from: String
    let to: String?
    let envelope: XMPPOMEMOEnvelope
    let provenance: XMPPMessageProvenance
    let sentAt: Date?
}

struct PreparedEnvelope: Codable {
    let envelope: XMPPOMEMOEnvelope
    let recipientIdentities: [String]
    var groupMembers: [String]? = nil
}

private struct IncomingCiphertextIdentity: Codable {
    let profile: XMPPOMEMOProfile
    let senderDeviceID: UInt32
    let key: Data
    let iv: Data?
    let payload: Data?
}
