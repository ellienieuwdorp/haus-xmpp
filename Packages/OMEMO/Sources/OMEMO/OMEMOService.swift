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

/// Encryption and trust policy. Every operation loads an ephemeral engine and commits its snapshot together with
/// the resulting message or ciphertext, so a thrown operation never advances durable ratchets. No network call or
/// callback runs inside a SQL transaction.
public actor OMEMOService {
    let store: MessageStore
    let protection: StateProtection
    let gate = OperationGate()
    // Holds only a (revision, state) pair one row produced or this actor committed; `load` trusts it only after
    // reading the current revision, so another process's write (the notification extension) is always seen.
    // Engines, lookups and anything clock-derived are never cached.
    private var stateCache: [String: (revision: Int, state: AccountEncryptionState)] = [:]
    // Versions whose bundle the latest `initialize` published; only those may be advertised by
    // `maintainLocalAdvertisement`.
    private var publishedBundles: [String: Set<XMPPOMEMOProfile>] = [:]
    public init(store: MessageStore, protection: StateProtection) {
        self.store = store; self.protection = protection
    }

    public func initialize(account: String, transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.initializeLocked(account: account, transport: transport) }
    }

    private func initializeLocked(account: String, transport: any OMEMOTransport) async throws {
        // A pass that fails before a version's bundle goes out (another identity under our ID, a timeout) leaves that
        // version unadvertised by `maintainLocalAdvertisement`.
        publishedBundles[account] = nil
        if try await store.encryptionState(accountID: account) == nil {
            // State under another spelling of this account is its identity: never create a second one beside it.
            guard try await !store.encryptionStateAccountIDs().contains(where: { bare($0) == bare(account) }) else { throw OMEMOError.stateUnavailable }
            // A device ID this account gave up (`startOver`) is never taken again.
            let deviceID = try Self.newDeviceID(avoiding: try await store.retiredOwnDevices(accountID: account))
            let legacy = try OMEMOEngine(profile: .legacy, deviceID: deviceID)
            let modern = try OMEMOEngine(profile: .modern, sharingIdentityWith: legacy)
            let state = AccountEncryptionState(engines: ["legacy": try legacy.snapshot(), "modern": try modern.snapshot()])
            try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: encode(state, account: account))
        }
        let (_, identityState) = try await load(account)
        let legacyIdentity = try engine(identityState, .legacy)
        let modernIdentity = try engine(identityState, .modern)
        guard try OMEMOEngine.fingerprintBytes(for: legacyIdentity.identityKey, profile: .legacy) == OMEMOEngine.fingerprintBytes(for: modernIdentity.identityKey, profile: .modern), legacyIdentity.deviceID == modernIdentity.deviceID else {
            // Both profiles share one identity per device ID. Fail closed otherwise; never repair by silently
            // replacing a published identity or prepared ciphertext.
            throw OMEMOError.stateUnavailable
        }
        // Kept in plain text so the device can still be retired if the wrapping key is ever lost.
        try await store.recordEncryptionDeviceID(accountID: account, deviceID: legacyIdentity.deviceID)
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
                do {
                    let published = try await transport.fetchOMEMOBundle(for: account, deviceID: engine.deviceID, profile: profile)
                    guard published.identityKey == (try engine.identityKey) else { throw OMEMOError.identityChanged }
                } catch XMPPIQError.stanza(condition: "item-not-found") {
                    // Listed without a bundle: publishing ours replaces nothing. Any other failure (timeout, wait-type
                    // or server error, unreadable answer) is not proof of absence and fails the setup unchanged.
                }
            }
            try await transport.publishOMEMOBundle(wireBundle(try engine.bundle(), profile: profile))
            publishedBundles[account, default: []].insert(profile)
            // Another client may register while the bundle publishes: re-read the list before changing it.
            try await maintainLocalAdvertisementLocked(account: account, profile: profile, transport: transport, removingRetired: true)
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
        var otherVersionOnly: [String: Int] = [:]
        var unavailable: [String: Int] = [:]
        var advertised: [String: Int] = [:]
        // Own devices given up by `startOver` are not offered for review while listed, unless reclaimed: then something
        // still holds the key and it is reviewed like any other device.
        let retired = try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue, statuses: [.pending, .removed])
        for owner in Array(Set([account, peer])).sorted() {
            let ids = try validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: profile))
            guard ids.count <= 200 else { throw OMEMOError.invalidContent }
            if owner == peer, !ids.isEmpty { peerAdvertises = true }
            advertised[owner] = ids.count
            let otherProfile: XMPPOMEMOProfile = profile == .legacy ? .modern : .legacy
            // The other version only feeds the incompatibility hint; an unreadable list there must not block this one.
            let otherIDs = (try? validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: otherProfile))) ?? []
            // Device IDs do not prove identity across profiles, so an other-version-only device is never encrypted to.
            // That is reported, not enforced: refusing to send would queue messages indefinitely.
            let onlyOther = Set(otherIDs).subtracting(ids).count
            if onlyOther > 0 { incompatible = true; otherVersionOnly[owner] = onlyOther }
            let missing = try await mergeAdvertised(ids, owner: owner, profile: profile,
                                                    skipping: owner == account ? retired.union([local.deviceID]) : [],
                                                    into: &state) { id in
                try await self.availableBundle(owner: owner, deviceID: id, profile: profile, transport: transport)
            }
            if missing > 0 { unavailable[owner] = missing }
        }
        // An empty probe (offline server, missing node) must not pin a version the peer never published.
        if updateSelection, !(probedEmpty && !peerAdvertises) { state.profiles[peer] = profile }
        if updateSelection { state.incompatiblePeers[peer] = incompatible }
        try await save(state, revision: revision, account: account)
        var result = try overview(state, account: account, peer: peer, profileOverride: profile, incompatibleOverride: incompatible,
                                  waiting: try await waitingDevices(state, account: account, peer: peer, sending: profile))
        result.unavailableDevices = unavailable
        result.advertisedDevices = advertised
        result.otherVersionOnlyDevices = otherVersionOnly
        return result
    }

    // Unlisted devices go inactive. Returns how many listed devices without a bundle were never seen before.
    func mergeAdvertised(_ ids: [UInt32], owner: String, profile: XMPPOMEMOProfile, skipping: Set<UInt32>,
                         into state: inout AccountEncryptionState,
                         bundle: (UInt32) async throws -> XMPPOMEMOBundle?) async throws -> Int {
        var missing = 0
        for index in state.devices.indices where state.devices[index].jid == owner && state.devices[index].profile == profile {
            state.devices[index].active = false
        }
        for id in ids where !skipping.contains(id) {
            guard let bundle = try await bundle(id) else {
                // A device reviewed earlier keeps its stored key rather than vanishing on a server hiccup; an unknown
                // one cannot be reviewed yet, so it is counted instead of failing the refresh.
                if let index = state.devices.lastIndex(where: { $0.jid == owner && $0.profile == profile && $0.deviceID == id }) {
                    state.devices[index].active = true
                } else { missing += 1 }
                continue
            }
            // A bundle that fails validation still fails closed: it must never deactivate a reviewed key.
            try validateBundle(bundle, id: id, profile: profile)
            mergeDevice(bundle, owner: owner, profile: profile, id: id, into: &state)
        }
        return missing
    }

    // Nil when gone or unreadable: device lists in the wild carry stale IDs. Any other failure (timeout, server
    // error) is not proof of absence and fails the caller.
    func availableBundle(owner: String, deviceID: UInt32, profile: XMPPOMEMOProfile,
                         transport: any OMEMOTransport) async throws -> XMPPOMEMOBundle? {
        do { return try await transport.fetchOMEMOBundle(for: owner, deviceID: deviceID, profile: profile) }
        catch XMPPIQError.stanza(condition: "item-not-found"), XMPPIQError.malformedResponse { return nil }
    }

    // A new key is stored `.undecided`, flagged `identityChanged` when the device had another key before; a returning
    // key moves to the end and needs review again unless it is still the last key.
    func mergeDevice(_ bundle: XMPPOMEMOBundle, owner: String, profile: XMPPOMEMOProfile, id: UInt32,
                     into state: inout AccountEncryptionState) {
        if let index = state.devices.firstIndex(where: { $0.jid == owner && $0.profile == profile && $0.deviceID == id && $0.identityKey == bundle.identityKey }) {
            let lastIdentity = state.devices.last { $0.jid == owner && $0.profile == profile && $0.deviceID == id }?.identityKey
            var returning = state.devices.remove(at: index)
            if lastIdentity != bundle.identityKey {
                returning.trust = .undecided
                returning.identityChanged = true
            }
            returning.active = true
            // The last record tracks the most recently observed key, so A→B→A needs one review.
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

    // Receive path for an unseen sender device: one device list and one bundle, leaving selection and other devices
    // alone. An unlisted device or a missing bundle leaves state unchanged and the caller waits for keys.
    func refreshSenderDeviceLocked(account: String, owner: String, deviceID: UInt32, profile: XMPPOMEMOProfile,
                                   transport: any OMEMOTransport) async throws {
        let ids = try validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: profile))
        guard ids.contains(deviceID) else { return }
        // A given-up own device is not added until reclaimed; its message waits until then.
        if owner == account, try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue, statuses: [.pending, .removed]).contains(deviceID) { return }
        let bundle: XMPPOMEMOBundle
        do { bundle = try await transport.fetchOMEMOBundle(for: owner, deviceID: deviceID, profile: profile) }
        catch XMPPIQError.stanza(condition: "item-not-found"), XMPPIQError.malformedResponse { return }
        try validateBundle(bundle, id: deviceID, profile: profile)
        let (revision, old) = try await load(account)
        var state = old
        mergeDevice(bundle, owner: owner, profile: profile, id: deviceID, into: &state)
        try await save(state, revision: revision, account: account)
    }

    public func overview(account: String, peer: String) async throws -> EncryptionOverview {
        let (_, state) = try await load(account)
        return try overview(state, account: account, peer: peer,
                            waiting: try await waitingDevices(state, account: account, peer: peer, sending: state.profiles[peer] ?? .legacy))
    }

    private func overview(_ state: AccountEncryptionState, account: String, peer: String, profileOverride: XMPPOMEMOProfile? = nil,
                          incompatibleOverride: Bool? = nil, waiting: [EncryptionDevice]) throws -> EncryptionOverview {
        let profile = profileOverride ?? state.profiles[peer] ?? .legacy
        let local = try engine(state, profile)
        var result = EncryptionOverview(profile: profile, localDeviceID: local.deviceID,
                                        localFingerprint: try OMEMOEngine.fingerprintBytes(for: local.identityKey, profile: profile.crypto).map { String(format: "%02x", $0) }.joined(),
                                        devices: state.devices.filter { $0.profile == profile && ($0.jid == peer || $0.jid == account) } + waiting,
                                        hasIncompatibleDevices: incompatibleOverride ?? state.incompatiblePeers[peer] ?? false)
        // Only a completed refresh stores devices, a pinned version or an incompatibility answer.
        result.isPeerKnown = state.incompatiblePeers[peer] != nil || state.profiles[peer] != nil || state.devices.contains { $0.jid == peer }
        return result
    }

    // Incoming messages decrypt in the version they were sent in, so other-version devices holding retained
    // ciphertext must be reviewable from this chat. Read from retained envelopes, never from content.
    private func waitingDevices(_ state: AccountEncryptionState, account: String, peer: String,
                                sending profile: XMPPOMEMOProfile) async throws -> [EncryptionDevice] {
        var result: [EncryptionDevice] = []
        for sender in Set([peer, account]).sorted() {
            for item in try await store.pendingEncryptedIncoming(accountID: account, sender: sender) {
                // Group envelopes have their own shape and never decode here.
                guard let retained = try? JSONDecoder().decode(RetainedEnvelope.self, from: item.wire),
                      retained.envelope.profile != profile,
                      sender == peer || retained.to.map(bare) == peer,
                      let device = state.devices.last(where: { $0.jid == sender && $0.profile == retained.envelope.profile
                                                               && $0.deviceID == retained.envelope.senderDeviceID }),
                      !device.trust.permitsEncryption, !result.contains(where: { $0.id == device.id }) else { continue }
                result.append(device)
            }
        }
        return result
    }

    /// Takes the fingerprint-scoped identifier the UI displayed, so a stale trust sheet cannot accept a replacement
    /// key under the same numeric device ID.
    public func setTrust(account: String, deviceID: String, trust: DeviceTrust) async throws {
        try await setTrust(account: account, deviceIDs: [deviceID], trust: trust)
    }

    /// One decision for several fingerprint-scoped identifiers, saved together or not at all.
    public func setTrust(account: String, deviceIDs: [String], trust: DeviceTrust) async throws {
        try await gate.run {
            let (revision, old) = try await self.load(account)
            var state = old
            for deviceID in deviceIDs {
                guard let index = state.devices.firstIndex(where: { $0.id == deviceID }), state.devices[index].active else { throw OMEMOError.identityChanged }
                state.devices[index].trust = trust
            }
            try await self.save(state, revision: revision, account: account)
        }
    }

    /// Rebuilds only the session for the selected fingerprint. The ratchet archives the old session so delayed
    /// messages still decrypt; identity, prekeys, drafts and prepared ciphertext never change.
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

    /// Removes another own device from every profile advertising the selected fingerprint. PEP is last-writer-wins,
    /// so each change is a fresh read, merge and confirmation. Never claims the remote device was wiped and never
    /// changes this installation's identity.
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
        // Validate both public identities before the first mutation: a stale sheet must not retire an unrelated
        // replacement that reused this numeric device ID.
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

    /// Call after an own-account PEP update. A racing publication that omitted this device is repaired by merging
    /// into the newest server list, not by replaying a cached one. Does nothing for a version whose bundle
    /// `initialize` has not published yet, so the device is never listed without keys.
    public func maintainLocalAdvertisement(account: String, profile: XMPPOMEMOProfile, transport: any OMEMOTransport) async throws {
        try await gate.run {
            guard await self.hasPublishedBundle(account: account, profile: profile) else { return }
            try await self.maintainLocalAdvertisementLocked(account: account, profile: profile, transport: transport, removingRetired: false)
        }
    }

    private func hasPublishedBundle(account: String, profile: XMPPOMEMOProfile) -> Bool {
        publishedBundles[account]?.contains(profile) == true
    }

    // `removingRetired` (connection setup only, so it never trades publications with a restored old installation)
    // also drops `pending` given-up IDs. A `removed` ID listed again becomes `reclaimed` and is left alone. Removal is
    // best effort: an ID still listed after three tries stays `pending` for the next connection.
    private func maintainLocalAdvertisementLocked(account: String, profile: XMPPOMEMOProfile, transport: any OMEMOTransport,
                                                  removingRetired: Bool) async throws {
        let (_, state) = try await load(account)
        let local = try engine(state, profile)
        var pending = try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue, statuses: [.pending])
        var removed = try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue, statuses: [.removed])
        var localListed = false
        for _ in 0..<3 {
            let latest = try await readOwnDevices(account: account, profile: profile, transport: transport, removed: &removed)
            localListed = latest.contains(local.deviceID)
            let removing = removingRetired ? pending.intersection(latest) : []
            if localListed, removing.isEmpty { return }
            let wanted = Set(latest).subtracting(removing).union([local.deviceID])
            guard wanted.count <= 200 else { throw OMEMOError.invalidContent }
            try await transport.publishOMEMODevices(wanted.sorted(), profile: profile)
            let confirmed = try await readOwnDevices(account: account, profile: profile, transport: transport, removed: &removed)
            let gone = removing.subtracting(confirmed)
            if !gone.isEmpty {
                try await store.advanceRetiredOwnDevices(accountID: account, profile: profile.rawValue, deviceIDs: gone, to: .removed)
                pending.subtract(gone)
                removed.formUnion(gone)
            }
            localListed = confirmed.contains(local.deviceID)
            if localListed, !removingRetired || pending.isDisjoint(with: confirmed) { return }
        }
        if localListed { return }
        throw OMEMOError.concurrentChange
    }

    private func readOwnDevices(account: String, profile: XMPPOMEMOProfile, transport: any OMEMOTransport,
                                removed: inout Set<UInt32>) async throws -> [UInt32] {
        let list = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
        let back = removed.intersection(list)
        if !back.isEmpty {
            try await store.advanceRetiredOwnDevices(accountID: account, profile: profile.rawValue, deviceIDs: back, to: .reclaimed)
            removed.subtract(back)
        }
        return list
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

    func validateBundle(_ bundle: XMPPOMEMOBundle, id: UInt32, profile: XMPPOMEMOProfile) throws {
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

    /// One unavailable contact must not starve other chats. Only the returned set may be claimed by the sender;
    /// messages enqueued during preparation wait for the next pass.
    public func prepareAvailableMessages(account: String, transport: any OMEMOTransport) async throws -> EncryptionPreparation {
        try await gate.run {
            let queued = try await self.store.queuedOutgoing(accountID: account)
            var ready = Set<String>()
            var blocked: [String: String] = [:]
            var firstFailure: OMEMOError?
            var droppedReplies = Set<String>(), droppedLinkPreviews = Set<String>()
            let (_, currentState) = try await self.load(account)
            // A chat's devices are fetched once per pass, not per message, so several files sent together do not each
            // wait behind a refresh.
            var refreshed = Set<String>()
            for message in queued where currentState.groupRooms[message.chatID] == nil {
                do {
                    try Task.checkCancellation()
                    let wire = try await self.store.encryptedOutgoing(accountID: account, messageID: message.id)
                    let saved = try wire.map { try JSONDecoder().decode(PreparedEnvelope.self, from: $0) }
                    let refresh = [message.chatID, saved?.envelope.profile.rawValue ?? "selected"].joined(separator: " ")
                    if !refreshed.contains(refresh) {
                        _ = try await self.refreshLocked(account: account, peer: message.chatID, profile: saved?.envelope.profile, transport: transport, updateSelection: saved == nil)
                        refreshed.insert(refresh)
                    }
                    if let saved {
                        let (_, state) = try await self.load(account)
                        let candidates = state.devices.filter { $0.profile == saved.envelope.profile && $0.active && ($0.jid == message.chatID || $0.jid == account) }
                        guard !candidates.contains(where: { $0.trust == .undecided }) else { throw OMEMOError.trustRequired }
                        guard candidates.filter({ $0.trust.permitsEncryption }).map(\.id).sorted() == saved.recipientIdentities.sorted() else { throw OMEMOError.recipientSetChanged }
                    } else {
                        let dropped = try await self.sealLocked(message)
                        if dropped.reply { droppedReplies.insert(message.id) }
                        if dropped.linkPreview { droppedLinkPreviews.insert(message.id) }
                    }
                    ready.insert(message.id)
                } catch {
                    if error is CancellationError { throw error }
                    if firstFailure == nil { firstFailure = (error as? OMEMOError) ?? .unavailable }
                    blocked[message.chatID] = (error as? OMEMOError)?.errorDescription ?? "Encryption preparation failed. This message remains queued."
                }
            }
            return EncryptionPreparation(messageIDs: ready, blockedChats: blocked, failure: firstFailure, droppedReplies: droppedReplies,
                                         droppedLinkPreviews: droppedLinkPreviews)
        }
    }

    private func sealLocked(_ message: StoredMessage) async throws -> (reply: Bool, linkPreview: Bool) {
        let account = message.accountID
        let (revision, old) = try await load(account)
        var state = old
        guard let profile = state.profiles[message.chatID] else { throw OMEMOError.unavailable }
        let plaintext = try EncryptedContent.encode(body: message.body, reply: message.reply,
                                                    sender: account, recipient: message.chatID, modern: profile == .modern,
                                                    originID: message.id, fileSharing: message.attachment.map { try fileSharing(for: $0, account: account) },
                                                    linkMetadata: message.linkPreview?.metadata)
        let saved = try sealContent(plaintext, account: account, peer: message.chatID, profile: profile, state: &state)
        // A reply or preview that cannot ride along (legacy fallback) is cleared from storage with the seal, so the
        // sender's bubble never shows what the peer did not get.
        let droppedReply = message.attachment != nil && message.reply.map { !EncryptedContent.fileCarries($0, modern: profile == .modern) } == true
        let droppedLinkPreview = message.linkPreview.map {
            !EncryptedContent.linkMetadataRides($0.metadata, body: message.body, modern: profile == .modern, fileSharing: message.attachment != nil)
        } ?? false
        try await store.sealQueuedOutgoing(accountID: account, messageID: message.id, profile: profile.rawValue,
                                           expectedRevision: revision, state: encode(state, account: account), wire: JSONEncoder().encode(saved),
                                           clearReply: droppedReply, clearLinkPreview: droppedLinkPreview)
        return (droppedReply, droppedLinkPreview)
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
            // The explicit trust decision for a changed key authorizes dropping only this peer session, never the
            // local identity or other devices.
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

    /// Records a full replacement set (empty clears) for one message. Modern chats need an authenticated target;
    /// there is no XML-in-body fallback.
    @discardableResult
    public func queueReactions(account: String, chatID: String, messageID: String, reactions: [String]) async throws -> String {
        try await gate.run { try await self.queueReactionsLocked(account: account, chatID: chatID, messageID: messageID, reactions: reactions) }
    }

    private func queueReactionsLocked(account: String, chatID: String, messageID: String, reactions: [String]) async throws -> String {
        let (_, state) = try await load(account)
        if state.groupRooms[chatID] != nil {
            return try await queueGroupReactionsLocked(account: account, room: chatID, messageID: messageID, reactions: reactions)
        }
        // Modern peers get an encrypted reaction to an authenticated reference. Legacy peers (Conversations) only
        // accept plain XEP-0444, so any unique stored wire ID will do.
        guard let profile = state.profiles[chatID],
              let target = try await store.message(accountID: account, messageID: messageID),
              target.chatID == chatID, let wireID = target.wireID,
              profile == .legacy || (target.encryptionProfile == XMPPOMEMOProfile.modern.rawValue && target.wireIDAuthenticated),
              let unique = try await store.reactionTarget(accountID: account, chatID: chatID, wireID: wireID), unique.id == target.id
        else { throw OMEMOError.unsupportedEncryptedReactions }
        let values = try ReactionContent.normalized(reactions)
        let update = StoredReactionUpdate(id: UUID().uuidString, accountID: account, chatID: chatID,
                                           targetMessageID: messageID, targetWireID: wireID, actorID: account,
                                           reactions: values, createdAt: Date())
        _ = try await store.enqueueReaction(update)
        return update.id
    }

    /// XEP-0424 retraction of an own message: inside the envelope for modern peers, a plain stanza for legacy peers.
    /// Projected immediately, sent through the outbox.
    @discardableResult
    public func queueRetraction(account: String, chatID: String, messageID: String) async throws -> String {
        try await gate.run { try await self.queueMessageUpdateLocked(account: account, chatID: chatID, messageID: messageID, kind: .retraction, body: "") }
    }

    /// XEP-0308 correction of an own message. The new body is always encrypted; for legacy peers the reference
    /// travels outside the ciphertext, bound like a legacy reaction.
    @discardableResult
    public func queueCorrection(account: String, chatID: String, messageID: String, body: String) async throws -> String {
        try await gate.run { try await self.queueMessageUpdateLocked(account: account, chatID: chatID, messageID: messageID, kind: .correction, body: body) }
    }

    private func queueMessageUpdateLocked(account: String, chatID: String, messageID: String, kind: StoredUpdate.Kind, body: String) async throws -> String {
        let (_, state) = try await load(account)
        guard state.groupRooms[chatID] == nil, let profile = state.profiles[chatID],
              let target = try await store.message(accountID: account, messageID: messageID),
              target.chatID == chatID, target.isOutgoing, target.senderID == account, let wireID = target.wireID,
              profile == .legacy || (target.encryptionProfile == XMPPOMEMOProfile.modern.rawValue && target.wireIDAuthenticated),
              try await store.reactionTarget(accountID: account, chatID: chatID, wireID: wireID)?.id == target.id
        else { throw OMEMOError.unsupportedMessageUpdate }
        let id = UUID().uuidString
        // An edit sends the whole message: the shown preview goes along only while its link stays in the text and the
        // chat is modern; otherwise the correction removes it on both sides.
        var preview: StoredLinkPreview?
        if kind == .correction, profile == .modern,
           let shown = try await target.applying(store.events(accountID: account, chatID: chatID, messageID: messageID)).linkPreview,
           EncryptedContent.linkMetadataRides(shown.metadata, body: body, modern: true, fileSharing: target.attachment != nil) {
            preview = StoredLinkPreview(shown.metadata, source: .own)
        }
        _ = try await store.enqueueMessageUpdate(accountID: account, id: id, kind: kind, chatID: chatID, targetMessageID: messageID, body: body,
                                                 linkPreview: preview)
        return id
    }

    /// Nil when there is nothing to send: receipts are switched off, the chat is a group, or the target has no
    /// usable identity.
    @discardableResult
    public func queueReceipt(account: String, chatID: String, messageID: String, kind: StoredUpdate.Kind) async throws -> String? {
        try await gate.run { try await self.queueReceiptLocked(account: account, chatID: chatID, messageID: messageID, kind: kind) }
    }

    private func queueReceiptLocked(account: String, chatID: String, messageID: String, kind: StoredUpdate.Kind) async throws -> String? {
        let (_, state) = try await load(account)
        guard state.groupRooms[chatID] == nil, state.profiles[chatID] != nil else { return nil }
        do { return try await store.enqueueReceipt(accountID: account, chatID: chatID, targetMessageID: messageID, kind: kind) }
        catch MessageStoreError.invalidValue { return nil }
    }

    /// Seals direct reactions, receipts, retractions and corrections (plain wire for legacy peers, envelope for
    /// modern ones) and returns every update the drain may claim. Key transports are sealed at creation.
    public func prepareAvailableUpdates(account: String, transport: any OMEMOTransport) async throws -> EncryptionPreparation {
        try await gate.run { try await self.prepareUpdatesLocked(account: account, transport: transport) }
    }

    private func prepareUpdatesLocked(account: String, transport: any OMEMOTransport) async throws -> EncryptionPreparation {
        // A correction has a body, so it is encrypted for legacy peers too (`plain` is nil) and its reference rides
        // outside.
        struct Pending {
            let id: String; let chatID: String; let kind: StoredUpdate.Kind; let plain: (() throws -> String)?; let plaintext: (_ modern: Bool) throws -> Data
            var dropsLinkPreview: (_ modern: Bool) -> Bool = { _ in false }
        }
        var queued = try await store.queuedReactions(accountID: account).map { update in
            Pending(id: update.id, chatID: update.chatID, kind: .reaction,
                    plain: { try XMPPClient.reactionXML(to: update.chatID, targetID: update.targetWireID, reactions: update.reactions, id: update.id) },
                    plaintext: { _ in try EncryptedContent.encodeReaction(targetWireID: update.targetWireID, reactions: update.reactions, sender: account,
                                                                          recipient: update.chatID, originID: update.id, modern: true) })
        }
        queued += try await store.queuedReceipts(accountID: account).compactMap { update in
            guard let target = update.targetWireID else { return nil }
            let kind: MessageContent.Receipt.Kind = update.kind == .marker ? .displayed : .delivered
            return Pending(id: update.id, chatID: update.chatID, kind: update.kind,
                           plain: { try XMPPClient.receiptXML(to: update.chatID, targetID: target, kind: kind, id: update.id) },
                           plaintext: { _ in try EncryptedContent.encodeReceipt(targetWireID: target, kind: kind, sender: account, recipient: update.chatID, originID: update.id) })
        }
        queued += try await store.queuedUpdates(accountID: account, kind: .retraction).compactMap { update in
            guard let target = update.targetWireID else { return nil }
            return Pending(id: update.id, chatID: update.chatID, kind: .retraction,
                           plain: { try XMPPClient.retractionXML(to: update.chatID, targetID: target, id: update.id) },
                           plaintext: { _ in try EncryptedContent.encodeRetraction(targetWireID: target, sender: account, recipient: update.chatID, originID: update.id, modern: true) })
        }
        for update in try await store.queuedUpdates(accountID: account, kind: .correction) {
            guard let target = update.targetWireID, let payload = update.payload, let body = MessageEvent.correctionBody(payload) else { continue }
            let linkMetadata = MessageEvent.correctionLinkPreview(payload)?.metadata
            // Editing a caption re-sends the same file reference: a peer that replaces the whole message keeps the attachment.
            var attachment: StoredAttachment?
            if let id = update.targetMessageID { attachment = try await store.message(accountID: account, messageID: id)?.attachment }
            let file = try attachment.map { try fileSharing(for: $0, account: account) }
            queued.append(Pending(id: update.id, chatID: update.chatID, kind: .correction, plain: nil,
                                  plaintext: { modern in try EncryptedContent.encode(body: body, reply: nil, sender: account, recipient: update.chatID,
                                                                                     modern: modern, originID: update.id, fileSharing: file, correction: target,
                                                                                     linkMetadata: linkMetadata) },
                                  dropsLinkPreview: { modern in
                                      linkMetadata.map { !EncryptedContent.linkMetadataRides($0, body: body, modern: modern, fileSharing: file != nil) } ?? false
                                  }))
        }
        var ready = Set(try await store.queuedUpdates(accountID: account, kind: .keyTransport).map(\.id)), blocked: [String: String] = [:]
        var droppedLinkPreviews = Set<String>()
        var failure: OMEMOError?
        for update in queued {
            do {
                try Task.checkCancellation()
                let (_, selected) = try await load(account)
                if selected.groupRooms[update.chatID] != nil { continue }
                let legacy = selected.profiles[update.chatID] == .legacy
                if legacy, let plain = update.plain {
                    // Legacy peers (Conversations) only speak unencrypted XEP-0444/0184/0424; the exact stanza is the wire.
                    try await store.sealQueuedUpdate(accountID: account, updateID: update.id, wire: Data(try plain().utf8))
                    ready.insert(update.id)
                    continue
                }
                let profile: XMPPOMEMOProfile = legacy ? .legacy : .modern
                guard selected.profiles[update.chatID] == profile else { throw update.kind == .retraction || update.kind == .correction ? OMEMOError.unsupportedMessageUpdate : .unsupportedEncryptedReactions }
                _ = try await refreshLocked(account: account, peer: update.chatID, profile: profile,
                                            transport: transport, updateSelection: false)
                if let wire = try await store.updateWire(accountID: account, updateID: update.id) {
                    let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
                    let (_, state) = try await load(account)
                    try validatePrepared(saved, state: state, account: account)
                } else {
                    let (revision, old) = try await load(account)
                    var state = old
                    let saved = try sealContent(try update.plaintext(!legacy), account: account, peer: update.chatID, profile: profile, state: &state)
                    // A preview the legacy seal leaves out is cleared from storage in the same transaction.
                    let dropped = update.dropsLinkPreview(!legacy)
                    try await store.sealQueuedUpdate(accountID: account, updateID: update.id, expectedRevision: revision,
                                                     state: encode(state, account: account), wire: JSONEncoder().encode(saved), clearLinkPreview: dropped)
                    if dropped { droppedLinkPreviews.insert(update.id) }
                }
                ready.insert(update.id)
            } catch {
                if error is CancellationError { throw error }
                if failure == nil { failure = (error as? OMEMOError) ?? .unavailable }
                blocked[update.chatID] = (error as? OMEMOError)?.errorDescription ?? "The private update remains queued."
            }
        }
        return EncryptionPreparation(messageIDs: ready, blockedChats: blocked, failure: failure, droppedLinkPreviews: droppedLinkPreviews)
    }

    /// Stream Management may retransmit a journaled stanza only when it is exactly one durable outgoing row: a plain
    /// wire byte-for-byte, or a prepared envelope that still re-derives under current trust. Anything else (unknown
    /// IDs, forged recipients, group ciphertext, drifted trust) refuses resumption.
    public func canReplay(account: String, xml: String) async throws -> Bool {
        guard let message = try? XMPPClient.decodeOutgoingEncryptedMessageXML(xml, from: account) else {
            let plain = XMPPClient.decodeOutgoingReactionXML(xml, from: account).map { ($0.id, $0.to) }
                ?? XMPPClient.decodeOutgoingReceiptXML(xml, from: account).map { ($0.id, $0.to) }
                ?? XMPPClient.decodeOutgoingRetractionXML(xml, from: account).map { ($0.id, $0.to) }
            guard let (id, to) = plain,
                  let update = try await store.update(accountID: account, updateID: id), update.chatID == bare(to ?? ""),
                  let wire = try await store.updateWire(accountID: account, updateID: id) else { return false }
            return wire == Data(xml.utf8)
        }
        guard let recipient = message.to else { return false }
        return try await canReplayEncrypted(account: account, messageID: message.id, recipient: recipient, envelope: message.envelope, replaces: message.replaces)
    }

    private func canReplayEncrypted(account: String, messageID: String, recipient: String, envelope: XMPPOMEMOEnvelope, replaces: String? = nil) async throws -> Bool {
        if let wire = try await store.encryptedOutgoing(accountID: account, messageID: messageID) {
            guard let saved = try? JSONDecoder().decode(PreparedEnvelope.self, from: wire), saved.groupMembers == nil,
                  let intention = try await store.message(accountID: account, messageID: messageID),
                  intention.isOutgoing, intention.senderID == account,
                  intention.chatID == bare(recipient), saved.envelope == envelope else { return false }
            do { return try await outgoingEnvelope(account: account, messageID: messageID) == envelope }
            catch let error as OMEMOError where error == .trustRequired || error == .recipientSetChanged || error == .unsupportedEncryptedReactions { return false }
        }
        guard let update = try await store.update(accountID: account, updateID: messageID), update.chatID == bare(recipient),
              let wire = try await store.updateWire(accountID: account, updateID: messageID) else { return false }
        switch update.kind {
        case .reaction, .receipt, .marker, .retraction, .correction:
            guard let saved = try? JSONDecoder().decode(PreparedEnvelope.self, from: wire), saved.groupMembers == nil, saved.envelope == envelope,
                  replaces == nil || (update.kind == .correction && replaces == update.targetWireID) else { return false }
            do { return try await outgoingUpdateEnvelope(account: account, updateID: messageID) == envelope }
            catch let error as OMEMOError where error == .trustRequired || error == .recipientSetChanged || error == .unsupportedEncryptedReactions || error == .unsupportedMessageUpdate { return false }
        case .keyTransport:
            // Header-only, no recipient set to re-derive: exact bytes, addressed to one device we may still encrypt to.
            guard (try? JSONDecoder().decode(XMPPOMEMOEnvelope.self, from: wire)) == envelope, envelope.keys.count == 1 else { return false }
            let (_, state) = try await load(account)
            return state.devices.contains { $0.jid == update.chatID && $0.profile == envelope.profile && $0.deviceID == envelope.keys[0].deviceID && $0.active && $0.trust.permitsEncryption }
        }
    }

    // The target must still resolve to the message it was queued against and every recipient device must still be
    // trusted.
    func outgoingUpdateEnvelope(account: String, updateID: String) async throws -> XMPPOMEMOEnvelope {
        guard let wire = try await store.updateWire(accountID: account, updateID: updateID),
              let update = try await store.update(accountID: account, updateID: updateID),
              let targetWireID = update.targetWireID, let targetMessageID = update.targetMessageID else { throw OMEMOError.unavailable }
        guard try await store.reactionTarget(accountID: account, chatID: update.chatID, wireID: targetWireID)?.id == targetMessageID else {
            throw update.kind == .retraction || update.kind == .correction ? OMEMOError.unsupportedMessageUpdate : .unsupportedEncryptedReactions
        }
        let saved = try JSONDecoder().decode(PreparedEnvelope.self, from: wire)
        guard saved.groupMembers == nil else { throw OMEMOError.unsupportedProfile }
        let (_, state) = try await load(account)
        try validatePrepared(saved, state: state, account: account)
        return saved.envelope
    }

    /// Drains every update kind; MessageStore enforces transport ownership. A preflight failure (trust, membership,
    /// malformed wire) releases the claim before any socket use; an attempted send stays unconfirmed until Stream
    /// Management or the archive proves acceptance. Group rows need `groupTransport` to re-check membership.
    public func flushUpdates(account: String, updateIDs: Set<String>? = nil, groupTransport: (any OMEMOGroupTransport)? = nil,
                             send: @Sendable (StoredUpdate, PreparedUpdate) async throws -> Void) async throws {
        while !Task.isCancelled {
            guard let claim = try await store.claimNextUpdate(accountID: account, updateIDs: updateIDs) else { return }
            let prepared: PreparedUpdate
            do {
                try Task.checkCancellation()
                prepared = try await preparedUpdate(account: account, claim: claim, groupTransport: groupTransport)
            } catch {
                try await store.releaseUnsentUpdateSubmission(accountID: account, updateID: claim.update.id, attemptID: claim.attemptID)
                throw error
            }
            do {
                try await send(claim.update, prepared)
            } catch {
                _ = try await store.finishUpdateSubmission(accountID: account, updateID: claim.update.id, attemptID: claim.attemptID)
                throw error
            }
            _ = try await store.finishUpdateSubmission(accountID: account, updateID: claim.update.id, attemptID: claim.attemptID)
        }
    }

    private func preparedUpdate(account: String, claim: UpdateSubmission, groupTransport: (any OMEMOGroupTransport)?) async throws -> PreparedUpdate {
        switch claim.update.kind {
        case .keyTransport:
            return .encrypted(to: claim.update.chatID, envelope: try JSONDecoder().decode(XMPPOMEMOEnvelope.self, from: claim.wire))
        case .reaction, .receipt, .marker:
            if let saved = try? JSONDecoder().decode(PreparedEnvelope.self, from: claim.wire) {
                if saved.groupMembers != nil {
                    guard claim.update.kind == .reaction, let groupTransport else { throw OMEMOError.unavailable }
                    let group = try await outgoingGroupReactionEnvelope(account: account, updateID: claim.update.id, room: claim.update.chatID, transport: groupTransport)
                    return .group(room: claim.update.chatID, envelope: group.envelope, members: group.members)
                }
                return .encrypted(to: claim.update.chatID, envelope: try await outgoingUpdateEnvelope(account: account, updateID: claim.update.id))
            }
            let xml = String(decoding: claim.wire, as: UTF8.self)
            if let reaction = XMPPClient.decodeOutgoingReactionXML(xml, from: account), bare(reaction.to ?? "") == claim.update.chatID {
                return .plainReaction(to: claim.update.chatID, targetID: reaction.targetID, reactions: reaction.reactions)
            }
            guard let receipt = XMPPClient.decodeOutgoingReceiptXML(xml, from: account), bare(receipt.to ?? "") == claim.update.chatID else { throw OMEMOError.invalidContent }
            return .plainReceipt(to: claim.update.chatID, targetID: receipt.targetID, kind: receipt.kind)
        case .retraction, .correction:
            if (try? JSONDecoder().decode(PreparedEnvelope.self, from: claim.wire)) != nil {
                return .encrypted(to: claim.update.chatID, envelope: try await outgoingUpdateEnvelope(account: account, updateID: claim.update.id))
            }
            guard claim.update.kind == .retraction, let retraction = XMPPClient.decodeOutgoingRetractionXML(String(decoding: claim.wire, as: UTF8.self), from: account),
                  bare(retraction.to ?? "") == claim.update.chatID else { throw OMEMOError.invalidContent }
            return .plainRetraction(to: claim.update.chatID, targetID: retraction.targetID)
        }
    }

    public func retryUpdate(account: String, updateID: String) async throws {
        try await store.retryUpdate(accountID: account, updateID: updateID)
    }

    /// Delivery bookkeeping only: a returned stanza is never decrypted and no crypto state changes, so this does not
    /// take the operation gate.
    public func rejectOutgoing(account: String, chatID: String, wireID: String, rejection: String, firstOnly: Bool = false) async throws -> RejectedOutgoing? {
        try await store.rejectOutgoing(accountID: account, chatID: chatID, wireID: wireID, rejection: rejection, firstOnly: firstOnly)
    }

    /// Plain XEP-0444, as Conversations and most clients send even in OMEMO chats. The actor is server-authenticated
    /// only; the untrusted target must resolve to one stored message. False for ignored content; throws only when
    /// storage fails.
    @discardableResult
    public func receivePlaintextReaction(account: String, reaction: XMPPReaction, sentAt: Date? = nil) async throws -> Bool {
        let actor = bare(reaction.from)
        let peer = actor == account ? bare(reaction.to ?? "") : actor
        let values = reaction.reactions.filter(ReactionContent.isEmoji)
        guard !actor.isEmpty, !peer.isEmpty, values.count <= 12 else { return false }
        let event = AuthenticatedReaction(id: reaction.id, chatID: peer, actorID: actor, targetWireID: reaction.targetID,
                                          reactions: values, updatedAt: min(sentAt ?? Date(), Date()))
        do { try await store.recordReaction(accountID: account, reaction: event) }
        catch MessageStoreError.invalidValue { return false }
        // Our own plain send coming back from the archive proves the server accepted it.
        if actor == account, let update = try await store.reactionUpdate(accountID: account, updateID: reaction.id), update.chatID == peer,
           update.targetWireID == reaction.targetID, update.reactions == values.sorted(),
           let wire = try await store.updateWire(accountID: account, updateID: reaction.id) {
            _ = try? await store.reconcileArchivedUpdate(accountID: account, updateID: reaction.id, expectedWire: wire)
        }
        return true
    }

    /// The plain XEP-0424 twin of `receivePlaintextReaction`: server-authenticated actor, untrusted target.
    @discardableResult
    public func receivePlaintextRetraction(account: String, retraction: XMPPRetraction, sentAt: Date? = nil) async throws -> Bool {
        let actor = bare(retraction.from)
        let peer = actor == account ? bare(retraction.to ?? "") : actor
        guard !actor.isEmpty, !peer.isEmpty else { return false }
        let event = MessageEvent(id: retraction.id, chatID: peer, actorID: actor, targetWireID: retraction.targetID, kind: .retraction, payload: "{}", updatedAt: min(sentAt ?? Date(), Date()))
        do { try await store.recordEvent(accountID: account, event: event) }
        catch MessageStoreError.invalidValue { return false }
        if actor == account, let update = try await store.update(accountID: account, updateID: retraction.id), update.kind == .retraction,
           update.chatID == peer, update.targetWireID == retraction.targetID,
           let wire = try await store.updateWire(accountID: account, updateID: retraction.id) {
            _ = try? await store.reconcileArchivedUpdate(accountID: account, updateID: retraction.id, expectedWire: wire)
        }
        return true
    }

    /// A plain XEP-0184/0333 element from the peer, or our own echoed by the archive or a carbon; the store decides
    /// whether the target is ours. Our own `displayed` moves the read pointer: the sender is our account as the
    /// server stamped it (validated carbon or own archive), never a peer's claim.
    @discardableResult
    public func receivePlaintextReceipt(account: String, receipt: XMPPReceipt, sentAt: Date? = nil) async throws -> Bool {
        let actor = bare(receipt.from)
        let peer = actor == account ? bare(receipt.to ?? "") : actor
        guard !actor.isEmpty, !peer.isEmpty else { return false }
        if actor == account {
            // Our own plain send coming back from the archive proves the server accepted it.
            if let update = try await store.update(accountID: account, updateID: receipt.id), update.chatID == peer, update.targetWireID == receipt.targetID,
               let wire = try await store.updateWire(accountID: account, updateID: receipt.id) {
                _ = try? await store.reconcileArchivedUpdate(accountID: account, updateID: receipt.id, expectedWire: wire)
            }
            guard receipt.kind == .displayed, peer != account else { return false }
            return try await store.recordOwnDisplayed(accountID: account, chatID: peer, targetWireID: receipt.targetID)
        }
        let event = MessageEvent(id: receipt.id, chatID: peer, actorID: actor, targetWireID: receipt.targetID,
                                 kind: receipt.kind == .displayed ? .displayed : .delivered, payload: "{}", updatedAt: min(sentAt ?? Date(), Date()))
        do { try await store.recordReceipt(accountID: account, event: event) }
        catch MessageStoreError.invalidValue { return false }
        return true
    }

    /// XEP-0490 items from our own PEP node, already verified as from our bare JID. Unknown ids are ignored. True when
    /// any read pointer moved.
    @discardableResult
    public func receiveDisplayedSync(account: String, items: [XMPPDisplayedItem]) async throws -> Bool {
        var moved = false
        for item in items where item.chat != account {
            if try await store.applyDisplayedSync(accountID: account, chatID: item.chat, stanzaID: item.stanzaID, by: item.by) { moved = true }
        }
        return moved
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

    /// Only for the stanza inside a validated own-server archive wrapper, never a live echo. An exact ciphertext match
    /// proves this is our saved send, so untrusted outer IDs alone cannot promote an intention to server acceptance.
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
        if let update = try await store.update(accountID: account, updateID: message.id), update.chatID == bare(recipient),
           let wire = try await store.updateWire(accountID: account, updateID: message.id) {
            guard savedEnvelope(wire) == message.envelope else { return false }
            return try await store.reconcileArchivedUpdate(accountID: account, updateID: message.id, expectedWire: wire)
        }
        return false
    }

    // A sealed update wire is a prepared envelope (reactions) or a bare envelope (key transports).
    nonisolated func savedEnvelope(_ wire: Data) -> XMPPOMEMOEnvelope? {
        (try? JSONDecoder().decode(PreparedEnvelope.self, from: wire))?.envelope ?? (try? JSONDecoder().decode(XMPPOMEMOEnvelope.self, from: wire))
    }

    /// Ciphertext from an unknown or unapproved sender device is retained before any network request or trust wait.
    /// An approved device decrypts without that write; any failure still leaves a placeholder or retained row before
    /// the error, or nothing durable only when storage failed (the caller must then not acknowledge the stanza).
    /// `sentAt` comes from a validated archive or delivery context, never a peer's delay element; it can correct a
    /// retained arrival time before retry.
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
        // The device ID comes from the snapshot header: nothing is imported into an engine before the ciphertext is
        // known to be new and addressed to us.
        let (_, initialState) = try await load(account)
        let localID = try localDeviceID(initialState, message.envelope.profile)
        if sender == account && message.envelope.senderDeviceID == localID { return false }
        let addressedKeys = message.envelope.keys.filter { $0.deviceID == localID && (message.envelope.profile == .legacy || $0.recipientJID == account) }
        if addressedKeys.count != 1 {
            // Never decryptable here (no key for this device, or ambiguous keys). A would-be bubble leaves a durable
            // placeholder before the error is thrown.
            let reason: UnreadableReason = addressedKeys.isEmpty ? .notForThisDevice : .malformedContent
            if Self.expectsBubble(message) {
                _ = try await store.recordUnreadableMessage(placeholder(for: message, account: account, reason: reason, sentAt: sentAt,
                                                                        key: .ciphertext(sender: sender, digest: try unaddressedDigest(message))))
            }
            throw addressedKeys.isEmpty ? OMEMOError.notForThisDevice : OMEMOError.undecryptable
        }
        let digest = try ciphertextDigest(message, key: addressedKeys[0])
        if try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest) {
            // The archive copy carries the stanza id XEP-0490 refers to.
            if let stanzaID = message.archiveStanzaID {
                try await store.bindArchivedDirectStanzaID(accountID: account, sender: sender, digest: digest, stanzaID: stanzaID)
            }
            return false
        }
        let previous = try await store.pendingEncryptedIncoming(accountID: account, sender: sender, digest: digest)
        var retained = try previous.map { try JSONDecoder().decode(RetainedEnvelope.self, from: $0.wire) }
            ?? RetainedEnvelope(from: message.from, to: message.to, envelope: message.envelope, provenance: message.provenance, sentAt: sentAt ?? Date(),
                                replaces: message.replaces, expectsBubble: Self.expectsBubble(message))
        if let previous, let sentAt, retained.sentAt != sentAt {
            // The digest covers only the addressed key and payload: require the whole envelope and conversation
            // context to match before changing durable metadata.
            let retainedRecipient: String
            switch retained.provenance {
            case .direct, .receivedCarbon:
                // Authenticated MAM turns direct delivery into received-carbon provenance and may restore an
                // omitted `to`; both mean this account.
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
                                        provenance: retained.provenance, sentAt: sentAt, replaces: retained.replaces, expectsBubble: retained.expectsBubble)
            guard try await store.replacePendingEncryptedIncomingContext(accountID: account, sender: sender, digest: digest,
                    expectedWire: previous.wire, wire: JSONEncoder().encode(retained)) else { throw OMEMOError.concurrentChange }
        }
        // Retention is decided before any network await or trust wait. An approved sender identity decrypts without
        // PEP (inactive approved devices may have delayed traffic); unknown ones need discovery and explicit approval.
        let profile = message.envelope.profile
        let known = initialState.devices.last {
            $0.jid == sender && $0.profile == profile && $0.deviceID == message.envelope.senderDeviceID
        }
        // A rejected device's ciphertext is never opened; any retained copy leaves with the final outcome.
        if known?.trust == .rejected {
            return try await recordRejectedDevice(account: account, message: message, sender: sender, digest: digest, sentAt: retained.sentAt)
        }
        // An approved device needs no pending row: until `receive` returns the stream token is unacknowledged and the
        // archive cursor unmoved, so a process death before the commit is redelivered.
        let retentionSkipped = previous == nil && known?.trust.permitsEncryption == true
        // A peer's would-be bubble waiting for trust or keys alerts without content. Own-device sends, key transports
        // and SCE reactions, receipts or retractions never do.
        let alert = sender == account || !Self.expectsBubble(message) ? nil
            : PendingNotificationContext(chatID: sender, sentAt: retained.sentAt ?? Date())
        let context = retained
        let peer = sender == account ? bare(message.to ?? account) : sender
        // Past a retention limit the store records this placeholder (or consumes the replay identity) in the same
        // transaction instead. `approved` copies are bounded only by the account ceiling.
        let overflowPlaceholder = Self.expectsBubble(message)
            ? placeholder(for: message, account: account, reason: .retentionLimit, sentAt: retained.sentAt, key: .ciphertext(sender: sender, digest: digest)) : nil
        func retain(_ reason: PendingEncryptedReason, notification: PendingNotificationContext?, approved: Bool = false) async throws -> Bool {
            try await store.retainEncryptedIncoming(accountID: account, sender: sender, digest: digest, wire: JSONEncoder().encode(context),
                                                    reason: reason, notification: notification,
                                                    overflow: RetentionOverflow(chatID: peer, placeholder: overflowPlaceholder, senderApproved: approved))
        }
        if previous == nil, !retentionSkipped {
            guard try await retain(known == nil ? .keysPending : .trustPending, notification: alert) else { return false }
        }
        // False when a limit gave the ciphertext its final outcome instead of keeping it.
        func hold(_ reason: PendingEncryptedReason) async throws -> Bool {
            if retentionSkipped { return try await retain(reason, notification: alert) }
            try await store.classifyPendingEncryptedIncoming(accountID: account, sender: sender, digest: digest, reason: reason)
            return true
        }
        if known == nil {
            // If this throws (offline), the row is already `keysPending`.
            try await refreshSenderDeviceLocked(account: account, owner: sender, deviceID: message.envelope.senderDeviceID,
                                                profile: profile, transport: transport)
        }
        do {
            let (revision, old) = try await load(account)
            var state = old
            let local = try engine(state, profile)
            guard local.deviceID == localID else { throw OMEMOError.stateUnavailable }
            guard let device = state.devices.last(where: { $0.jid == sender && $0.profile == profile && $0.deviceID == message.envelope.senderDeviceID }) else {
                guard try await hold(.keysPending) else { return false }
                throw OMEMOError.trustRequired
            }
            if device.trust == .rejected {
                return try await recordRejectedDevice(account: account, message: message, sender: sender, digest: digest, sentAt: retained.sentAt)
            }
            guard device.trust.permitsEncryption else {
                guard try await hold(.trustPending) else { return false }
                throw OMEMOError.trustRequired
            }
            let address = DeviceAddress(jid: sender, deviceID: device.deviceID)
            // Outside the failure handler: malformed stored key bytes are a state problem, not this message's.
            try local.trustIdentity(device.identityKey, for: address, resetSession: device.identityChanged)
            if let index = state.devices.firstIndex(where: { $0.id == device.id }) { state.devices[index].identityChanged = false }
            let key = addressedKeys[0]
            var stored: StoredMessage?
            var reaction: AuthenticatedReaction?
            var event: MessageEvent?
            var readMarker: OwnReadMarker?
            do {
                let material = try local.decrypt(RatchetCiphertext(data: key.data, isPreKey: key.keyExchange), from: address)
                if let payload = message.envelope.payload {
                    let plaintext = try PayloadCrypto.open(SealedPayload(payload: payload, keyMaterial: material, iv: message.envelope.iv), profile: profile.crypto)
                    let content = try EncryptedContent.decode(plaintext, sender: sender, recipient: sender == account ? peer : account,
                                                               modern: profile == .modern, sendingTime: retained.sentAt)
                    let date = min(content.timestamp ?? retained.sentAt ?? Date(), Date())
                    // A legacy correction reference sits outside the ciphertext, bound like a legacy reaction.
                    let correction = content.correction ?? (profile == .legacy ? retained.replaces : nil)
                    if let target = content.retraction {
                        guard profile == .modern, sender == account || sender == peer else { throw OMEMOError.invalidContent }
                        event = MessageEvent(id: content.originID ?? digest, chatID: peer, actorID: sender, targetWireID: target, kind: .retraction, payload: "{}", updatedAt: date)
                    } else if let target = correction, !content.body.isEmpty {
                        // An edit projects onto the original bubble, never a second bubble.
                        guard sender == account || sender == peer else { throw OMEMOError.invalidContent }
                        event = MessageEvent(id: content.originID ?? message.originID ?? message.id, chatID: peer, actorID: sender, targetWireID: target,
                                             kind: .correction, payload: try MessageEvent.correctionPayload(
                                                content.body, linkPreview: content.linkMetadata.map { StoredLinkPreview($0, source: .sender) }),
                                             updatedAt: date)
                    } else if !content.body.isEmpty || content.fileSharing != nil {
                        stored = StoredMessage(id: UUID().uuidString, accountID: account, chatID: peer, senderID: sender,
                                               body: content.body, sentAt: retained.sentAt ?? Date(), isOutgoing: sender == account,
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
                                             updatedAt: min(content.timestamp ?? retained.sentAt ?? Date(), Date()))
                    }
                    // Another device of ours displayed a peer message: authenticated as our account, it moves the read pointer.
                    if let receipt = content.receipt, receipt.kind == .displayed, profile == .modern, sender == account, peer != account,
                       stored == nil, reaction == nil, event == nil {
                        readMarker = OwnReadMarker(chatID: peer, targetWireID: receipt.targetID)
                    }
                } else if profile == .modern {
                    guard material == Data(repeating: 0, count: 32) else { throw OMEMOError.invalidContent }
                }
            } catch is SendingTimeOutsideWindow {
                // Context, not ciphertext: the retained row waits for a validated archive stamp (written below if
                // retention was skipped).
                throw OMEMOError.invalidContent
            } catch let error as OMEMOCryptoError where error != .invalidSnapshot {
                // A trusted device's ciphertext that fails now always will: record a durable outcome, discard the
                // ephemeral engine, commit no ratchet state.
                guard try await recordDecryptFailure(account: account, message: message, sender: sender, digest: digest, sentAt: retained.sentAt) else { return false }
                throw OMEMOError.undecryptable
            } catch OMEMOError.invalidContent {
                guard try await recordDecryptFailure(account: account, message: message, sender: sender, digest: digest, sentAt: retained.sentAt) else { return false }
                throw OMEMOError.undecryptable
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
            do {
                try await store.commitEncryptedIncoming(accountID: account, sender: sender, digest: digest, expectedRevision: revision,
                                                        state: encode(state, account: account), message: stored, control: control, reaction: reaction, event: event,
                                                        archiveStanzaID: stored == nil ? nil : message.archiveStanzaID, readMarker: readMarker)
            } catch { forgetState(account); throw error }
            committed(state, revision: revision, account: account)
            if let stored, sender == peer, message.requestsReceipt {
                _ = try? await queueReceiptLocked(account: account, chatID: peer, messageID: stored.id, kind: .receipt)
            }
            // The message is already durable; a network error must not turn success into a decryption failure.
            if key.keyExchange { try? await flushBundlePublicationsLocked(account: account, transport: transport) }
            return stored != nil || reaction != nil || event != nil || readMarker != nil
        } catch let failure {
            // Retention was skipped and this failure left no durable outcome: retain now so a failure repeating on
            // redelivery cannot wedge the archive walk. If that write fails too, the caller sees no durable disposition
            // and tears the stream down.
            if retentionSkipped, !Self.leavesDurableOutcome(failure) {
                let kept: Bool
                do { kept = try await retain(.trustPending, notification: nil, approved: true) } catch { throw failure }
                if !kept { return false }
            }
            throw failure
        }
    }

    // Errors `receive` throws only after their outcome is durable.
    static func leavesDurableOutcome(_ error: any Error) -> Bool {
        guard let error = error as? OMEMOError else { return false }
        return error == .undecryptable || error == .trustRequired
    }

    /// Whether a stream or archive acknowledgement is safe: an authenticated commit or durable retention exists. Uses
    /// the same ciphertext identity as `receive`, never outer stanza IDs.
    public func hasDurableIncomingDisposition(account: String, message: XMPPEncryptedMessage) async throws -> Bool {
        let (_, state) = try await load(account)
        let localID = try localDeviceID(state, message.envelope.profile)
        let sender = bare(message.from)
        guard !sender.isEmpty else { return false }
        switch message.provenance {
        case .direct, .receivedCarbon:
            guard message.to.map({ bare($0) == account }) ?? true else { return false }
        case .sentCarbon:
            guard sender == account, message.to != nil else { return false }
        }
        if sender == account && message.envelope.senderDeviceID == localID { return true }
        let keys = message.envelope.keys.filter {
            $0.deviceID == localID && (message.envelope.profile == .legacy || $0.recipientJID == account)
        }
        if keys.count != 1 {
            guard Self.expectsBubble(message) else { return true }
            return try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: try unaddressedDigest(message))
        }
        let digest = try ciphertextDigest(message, key: keys[0])
        if try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest) { return true }
        return try await store.pendingEncryptedIncoming(accountID: account, sender: sender, digest: digest) != nil
    }

    // Only a would-be bubble deserves a placeholder. SCE payloads also carry reactions, receipts and retractions, so
    // modern needs an outer hint: the XEP-0384 `<body/>` fallback or a receipt/marker request. Legacy payloads are
    // always messages.
    static func expectsBubble(_ message: XMPPEncryptedMessage) -> Bool {
        message.envelope.payload != nil
            && (message.envelope.profile == .legacy || message.hasFallbackBody || message.requestsReceipt || message.markable)
    }
    static func expectsBubble(_ message: XMPPEncryptedGroupMessage) -> Bool {
        message.envelope.payload != nil && message.hasFallbackBody
    }

    // Domain-separated from `ciphertextDigest` so the two can never collide.
    func unaddressedDigest(_ message: XMPPEncryptedMessage) throws -> String {
        let identity = UnaddressedCiphertextIdentity(profile: message.envelope.profile, senderDeviceID: message.envelope.senderDeviceID,
                                                     iv: message.envelope.iv, payload: message.envelope.payload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var material = Data("unaddressed\u{0}".utf8)
        material.append(try encoder.encode(identity))
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    func placeholder(for message: XMPPEncryptedMessage, account: String, reason: UnreadableReason, sentAt: Date?,
                     key: UnreadableMessage.Key) -> UnreadableMessage {
        let sender = bare(message.from)
        let outgoing = sender == account
        return UnreadableMessage(accountID: account, chatID: outgoing ? bare(message.to ?? account) : sender, senderID: sender,
                                 isOutgoing: outgoing, sentAt: sentAt ?? Date(), reason: reason, key: key)
    }

    // Never decrypted, never alerts; a retained copy and its review candidate leave in the same transaction.
    private func recordRejectedDevice(account: String, message: XMPPEncryptedMessage, sender: String, digest: String, sentAt: Date?) async throws -> Bool {
        if Self.expectsBubble(message) {
            try await store.recordUnreadableMessage(placeholder(for: message, account: account, reason: .rejectedDevice, sentAt: sentAt,
                                                                key: .ciphertext(sender: sender, digest: digest)))
        } else {
            try await store.consumeUndecryptableIncoming(accountID: account, sender: sender, digest: digest)
        }
        return false
    }

    // Only for ciphertext this device will never read, never for storage, cancellation or state errors. Returns true
    // when a placeholder marks the message.
    @discardableResult
    private func recordDecryptFailure(account: String, message: XMPPEncryptedMessage, sender: String, digest: String, sentAt: Date?) async throws -> Bool {
        guard message.envelope.payload != nil else {
            try await store.consumeUndecryptableIncoming(accountID: account, sender: sender, digest: digest)
            return false
        }
        try await store.recordUnreadableMessage(placeholder(for: message, account: account, reason: .decryptFailed, sentAt: sentAt,
                                                            key: .ciphertext(sender: sender, digest: digest)))
        return true
    }

    func ciphertextDigest(_ message: XMPPEncryptedMessage, key: XMPPOMEMOKey) throws -> String {
        let identity = IncomingCiphertextIdentity(profile: message.envelope.profile,
                                                  senderDeviceID: message.envelope.senderDeviceID,
                                                  key: key.data, iv: message.envelope.iv, payload: message.envelope.payload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    /// Retained ciphertext per conversation, counted from the store's projection without reading ciphertext.
    /// Retained ciphertext is not authenticated display content, so only counts are exposed.
    public func pendingConversations(account: String) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for item in try await store.pendingEncryptedIncomingSummaries(accountID: account) {
            if let room = item.room, let roomSender = item.roomSender {
                guard roomSender == item.sender else { continue }
                result[room, default: 0] += 1
                continue
            }
            guard let from = item.from, let sender = boundedBareJID(from), sender == item.sender,
                  let provenance = item.provenance.flatMap(XMPPMessageProvenance.init(rawValue:)) else { continue }
            switch provenance {
            case .direct, .receivedCarbon:
                guard item.to.map({ boundedBareJID($0) == account }) ?? true else { continue }
            case .sentCarbon:
                guard sender == account, item.to != nil else { continue }
            }
            guard let peer = sender == account ? item.to.flatMap(boundedBareJID) : sender else { continue }
            result[peer, default: 0] += 1
        }
        return result
    }

    /// Retries retained ciphertext. `reasons` narrows the work to what the trigger can unblock: a trust decision
    /// retries `trustPending`, a device list `keysPending` from its owner, a connection both. A row that now fails
    /// permanently, or whose sender device is rejected, becomes a placeholder and is never retried.
    public func retryPendingIncoming(account: String, transport: any OMEMOTransport,
                                     reasons: Set<PendingEncryptedReason> = [.trustPending, .keysPending],
                                     sender: String? = nil) async throws {
        let pending = try await store.pendingEncryptedIncoming(accountID: account, reasons: reasons, sender: sender)
        var firstFailure: (any Error)?
        // A room still unknown after one attempt in this pass is not refreshed again for its other rows.
        var unresolvedRooms: Set<String> = []
        for item in pending {
            do {
                // Skip rows that would only throw `trustRequired` again.
                if let group = try? JSONDecoder().decode(RetainedGroupEnvelope.self, from: item.wire) {
                    guard let groupTransport = transport as? any OMEMOGroupTransport else { continue }
                    let (_, state) = try await load(account)
                    if state.groupRooms[group.message.room] == nil {
                        if unresolvedRooms.contains(group.message.room) { continue }
                    } else if let device = state.devices.last(where: { $0.jid == group.message.sender && $0.profile == .modern
                                                                       && $0.deviceID == group.message.envelope.senderDeviceID }),
                              device.trust == .undecided {
                        try await awaitTrustDecision(item, account: account)
                        continue
                    }
                    let message = group.recordsBubbleHint ? group.message
                        : try XMPPEncryptedGroupMessage(id: group.message.id, room: group.message.room, occupant: group.message.occupant,
                                                        sender: group.message.sender, envelope: group.message.envelope, provenance: group.message.provenance,
                                                        roomStanzaID: group.message.roomStanzaID, hasFallbackBody: true)
                    do { _ = try await receiveGroup(account: account, message: message, transport: groupTransport, sentAt: group.sentAt) }
                    catch {
                        if (try? await load(account))?.1.groupRooms[group.message.room] == nil { unresolvedRooms.insert(group.message.room) }
                        throw error
                    }
                    continue
                }
                let value = try JSONDecoder().decode(RetainedEnvelope.self, from: item.wire)
                let (_, state) = try await load(account)
                if let device = state.devices.last(where: { $0.jid == item.sender && $0.profile == value.envelope.profile
                                                            && $0.deviceID == value.envelope.senderDeviceID }),
                   device.trust == .undecided {
                    try await awaitTrustDecision(item, account: account)
                    continue
                }
                // A row without the bubble hint counts as a bubble, so a rejected device's message leaves a placeholder.
                _ = try await receive(account: account, message: XMPPEncryptedMessage(id: item.digest, from: value.from, to: value.to, originID: nil, envelope: value.envelope, provenance: value.provenance,
                                                                                      hasFallbackBody: value.expectsBubble ?? true, replaces: value.replaces),
                                      transport: transport, sentAt: value.sentAt)
            } catch {
                if error is CancellationError { throw error }
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    // A `keysPending` row whose device became known elsewhere now waits for trust; relabel it so the retry after
    // that decision selects it.
    private func awaitTrustDecision(_ item: PendingEncryptedMessage, account: String) async throws {
        guard item.reason != .trustPending else { return }
        try await store.classifyPendingEncryptedIncoming(accountID: account, sender: item.sender, digest: item.digest, reason: .trustPending)
    }

    // The returned (revision, state) pair always comes from one row or our own commit of it.
    func load(_ account: String) async throws -> (Int, AccountEncryptionState) {
        guard let revision = try await store.encryptionStateRevision(accountID: account) else {
            stateCache[account] = nil
            throw OMEMOError.unavailable
        }
        if let cached = stateCache[account], cached.revision == revision { return (cached.revision, cached.state) }
        guard let row = try await store.encryptionState(accountID: account) else {
            stateCache[account] = nil
            throw OMEMOError.unavailable
        }
        do {
            let state = try JSONDecoder().decode(AccountEncryptionState.self, from: protection.open(row.data, account: account, sealedAs: row.sealedAccount))
            guard state.format == 1 else { throw OMEMOError.stateUnavailable }
            remember(state, revision: row.revision, account: account)
            return (row.revision, state)
        } catch {
            stateCache[account] = nil
            throw OMEMOError.stateUnavailable
        }
    }
    func encode(_ state: AccountEncryptionState, account: String) throws -> Data { try protection.seal(JSONEncoder().encode(state), account: account) }
    func save(_ state: AccountEncryptionState, revision: Int, account: String) async throws {
        do { try await store.saveEncryptionState(accountID: account, expectedRevision: revision, data: encode(state, account: account)) }
        catch { stateCache[account] = nil; throw error }
        committed(state, revision: revision, account: account)
    }
    func committed(_ state: AccountEncryptionState, revision expected: Int, account: String) {
        remember(state, revision: expected + 1, account: account)
    }
    func forgetState(_ account: String) { stateCache[account] = nil }
    private func remember(_ state: AccountEncryptionState, revision: Int, account: String) {
        // An interleaved load may already hold a newer revision.
        if let cached = stateCache[account], cached.revision > revision { return }
        stateCache[account] = (revision, state)
    }
    // Reads the snapshot header without importing ratchet records into an engine.
    func localDeviceID(_ state: AccountEncryptionState, _ profile: XMPPOMEMOProfile) throws -> UInt32 {
        guard let data = state.engines[profile.rawValue],
              let header = try? JSONDecoder().decode(EngineHeader.self, from: data),
              header.profile == profile.crypto, header.deviceID > 0, header.deviceID <= Int32.max else { throw OMEMOError.stateUnavailable }
        return header.deviceID
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
    private func boundedBareJID(_ jid: String) -> String? { JID.normalizedBare(jid) }
    func bare(_ jid: String) -> String { JID.normalizedBare(jid) ?? String(jid.split(separator: "/", maxSplits: 1).first ?? "") }
}

private struct EngineHeader: Decodable {
    let profile: CryptoProfile
    let deviceID: UInt32
}

struct RetainedEnvelope: Codable {
    let from: String
    let to: String?
    let envelope: XMPPOMEMOEnvelope
    let provenance: XMPPMessageProvenance
    let sentAt: Date?
    // Outer legacy correction reference, kept so a trust retry still applies it.
    var replaces: String? = nil
    // The arriving stanza's outer hints are not otherwise kept. Nil in older rows.
    var expectsBubble: Bool? = nil
}

struct PreparedEnvelope: Codable {
    let envelope: XMPPOMEMOEnvelope
    let recipientIdentities: [String]
    var groupMembers: [String]? = nil
}

private struct UnaddressedCiphertextIdentity: Codable {
    let profile: XMPPOMEMOProfile
    let senderDeviceID: UInt32
    let iv: Data?
    let payload: Data?
}

private struct IncomingCiphertextIdentity: Codable {
    let profile: XMPPOMEMOProfile
    let senderDeviceID: UInt32
    let key: Data
    let iv: Data?
    let payload: Data?
}
