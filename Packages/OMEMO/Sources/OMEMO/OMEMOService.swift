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
    /// The last decoded state per account and the CAS revision it was read at. Only ever holds a (revision, state)
    /// pair that one row produced, or that this actor just committed as that revision; `load` trusts it only after
    /// reading the current revision, so a write by another process (the notification extension shares the database)
    /// is always seen. Engines, lookups and anything derived from the clock are never cached.
    private var stateCache: [String: (revision: Int, state: AccountEncryptionState)] = [:]
    /// Versions whose bundle the latest `initialize` of an account published from this service. Only those may be
    /// advertised by `maintainLocalAdvertisement`; `initialize` itself advertises each version right after its bundle.
    private var publishedBundles: [String: Set<XMPPOMEMOProfile>] = [:]
    public init(store: MessageStore, protection: StateProtection) {
        self.store = store; self.protection = protection
    }

    public func initialize(account: String, transport: any OMEMOTransport) async throws {
        try await gate.run { try await self.initializeLocked(account: account, transport: transport) }
    }

    private func initializeLocked(account: String, transport: any OMEMOTransport) async throws {
        // Each pass re-earns advertisement: after a pass that failed before a version's bundle went out again (a
        // different identity under our ID, a timeout), `maintainLocalAdvertisement` leaves that version alone.
        publishedBundles[account] = nil
        if try await store.encryptionState(accountID: account) == nil {
            // State kept under another spelling of this account (a store whose address rewrite could not complete) is
            // this account's identity: never create a second one beside it.
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
            // Fail closed for early prototype databases that advertised inconsistent profiles.
            // Never repair this by silently replacing a published identity or prepared ciphertext.
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
                    // Listed without a bundle (no node, or a shared OMEMO 2 node without our item): nothing sits under
                    // our ID in this version, so publishing ours below replaces nothing. A server that lost PEP data,
                    // another client, or an earlier build can leave this state. Any other failure (timeout, wait-type
                    // or server error, unreadable answer) is not proof of absence and fails the setup unchanged.
                }
            }
            try await transport.publishOMEMOBundle(wireBundle(try engine.bundle(), profile: profile))
            publishedBundles[account, default: []].insert(profile)
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
        var otherVersionOnly: [String: Int] = [:]
        var unavailable: [String: Int] = [:]
        var advertised: [String: Int] = [:]
        // This account's own dead devices (`startOver`) are never offered for review, even while a list still names them.
        let retired = try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue)
        for owner in Array(Set([account, peer])).sorted() {
            let ids = try validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: profile))
            guard ids.count <= 200 else { throw OMEMOError.invalidContent }
            if owner == peer, !ids.isEmpty { peerAdvertises = true }
            advertised[owner] = ids.count
            let otherProfile: XMPPOMEMOProfile = profile == .legacy ? .modern : .legacy
            // The other version only feeds the incompatibility hint; an unreadable list there must not block this one.
            let otherIDs = (try? validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: otherProfile))) ?? []
            // Device IDs are not proof of physical identity across profiles, so a device that exists only in the
            // other version is never encrypted to here. Omitting it leaks nothing; it just does not receive the copy.
            // That is reported (Devices screen), not enforced: refusing every send because one client of either
            // side speaks only the other version left messages queued indefinitely.
            let onlyOther = Set(otherIDs).subtracting(ids).count
            if onlyOther > 0 { incompatible = true; otherVersionOnly[owner] = onlyOther }
            for index in state.devices.indices where state.devices[index].jid == owner && state.devices[index].profile == profile {
                state.devices[index].active = false
            }
            for id in ids where !(owner == account && (id == local.deviceID || retired.contains(id))) {
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
                mergeDevice(bundle, owner: owner, profile: profile, id: id, into: &state)
            }
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

    /// Records one validated bundle for a scoped device, the same way for the full refresh and the receive path's
    /// targeted one. A key never seen for this device is stored `.undecided`, flagged `identityChanged` when the device
    /// had another key before; a returning key moves to the end and needs review again unless it is still the last key.
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

    /// One device list and one bundle for `owner`; merges like `refreshLocked`; leaves selection, incompatibility and
    /// other devices alone. Used on the receive path for a sender device this installation has never seen: the full
    /// both-owners, both-profiles refresh stays on the sending path, which re-observes whatever this adds.
    /// An unlisted device, or a listed one whose bundle is gone or unreadable, leaves the state unchanged (the caller
    /// then waits for keys, exactly as after a full refresh that skipped it).
    func refreshSenderDeviceLocked(account: String, owner: String, deviceID: UInt32, profile: XMPPOMEMOProfile,
                                   transport: any OMEMOTransport) async throws {
        let ids = try validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: profile))
        guard ids.contains(deviceID) else { return }
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
        // Every completed selecting refresh records the incompatibility answer, even an empty one; devices and a
        // pinned version are also only ever stored by a completed refresh.
        result.isPeerKnown = state.incompatiblePeers[peer] != nil || state.profiles[peer] != nil || state.devices.contains { $0.jid == peer }
        return result
    }

    /// Devices of the version this chat does not send with whose retained ciphertext for it waits on their trust
    /// decision. Incoming messages decrypt in the version they were sent in, whatever the chat sends with, so an OMEMO 2
    /// device held for review must be reviewable from a chat that sends legacy OMEMO (and the reverse); listing only
    /// the sending version's devices left no way to release those messages. Read from the retained envelopes, never
    /// from content; own-device sends count for the chat they were addressed to.
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
    /// Does nothing for a version whose bundle `initialize` has not published yet: the update can arrive while connection
    /// setup runs, and listing the device first would name a device without keys. `initialize` reads the newest list
    /// and advertises the device itself once the bundle is out, and the gate orders the two.
    public func maintainLocalAdvertisement(account: String, profile: XMPPOMEMOProfile, transport: any OMEMOTransport) async throws {
        try await gate.run {
            guard await self.hasPublishedBundle(account: account, profile: profile) else { return }
            try await self.maintainLocalAdvertisementLocked(account: account, profile: profile, transport: transport)
        }
    }

    private func hasPublishedBundle(account: String, profile: XMPPOMEMOProfile) -> Bool {
        publishedBundles[account]?.contains(profile) == true
    }

    /// Also takes this account's retired device IDs (`startOver`) out of the list whenever it names them: they are ours
    /// and can never decrypt again, so they need no fingerprint check. That part is best effort: once the local ID is
    /// listed, a retired ID that something keeps putting back does not fail setup; the next connection removes it again.
    private func maintainLocalAdvertisementLocked(account: String, profile: XMPPOMEMOProfile, transport: any OMEMOTransport) async throws {
        let (_, state) = try await load(account)
        let local = try engine(state, profile)
        let retired = try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue)
        var localListed = false
        for _ in 0..<3 {
            let latest = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
            localListed = latest.contains(local.deviceID)
            if localListed, !latest.contains(where: retired.contains) { return }
            let wanted = Set(latest.filter { !retired.contains($0) }).union([local.deviceID])
            guard wanted.count <= 200 else { throw OMEMOError.invalidContent }
            try await transport.publishOMEMODevices(wanted.sorted(), profile: profile)
            let confirmed = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
            localListed = confirmed.contains(local.deviceID)
            if localListed, !confirmed.contains(where: retired.contains) { return }
        }
        if localListed { return }
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
            var droppedReplies = Set<String>()
            let (_, currentState) = try await self.load(account)
            // Several files sent together are one message each: a chat's devices are fetched once per pass, not once per
            // message, so the first of them is not held behind every other one's refresh.
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
                    } else if try await self.sealLocked(message) { droppedReplies.insert(message.id) }
                    ready.insert(message.id)
                } catch {
                    if error is CancellationError { throw error }
                    if firstFailure == nil { firstFailure = (error as? OMEMOError) ?? .unavailable }
                    blocked[message.chatID] = (error as? OMEMOError)?.errorDescription ?? "Encryption preparation failed. This message remains queued."
                }
            }
            return EncryptionPreparation(messageIDs: ready, blockedChats: blocked, failure: firstFailure, droppedReplies: droppedReplies)
        }
    }

    /// Returns whether a file's reply was left out of the seal (see `EncryptionPreparation.droppedReplies`).
    private func sealLocked(_ message: StoredMessage) async throws -> Bool {
        let account = message.accountID
        let (revision, old) = try await load(account)
        var state = old
        guard let profile = state.profiles[message.chatID] else { throw OMEMOError.unavailable }
        let plaintext = try EncryptedContent.encode(body: message.body, reply: message.reply,
                                                    sender: account, recipient: message.chatID, modern: profile == .modern,
                                                    originID: message.id, fileSharing: message.attachment.map { try fileSharing(for: $0, account: account) })
        let saved = try sealContent(plaintext, account: account, peer: message.chatID, profile: profile, state: &state)
        // A file whose reply could not ride along (the chat fell back to legacy after it was queued) loses the stored
        // quote with the seal, so the sender's bubble never shows a reply the peer did not get.
        let droppedReply = message.attachment != nil && message.reply.map { !EncryptedContent.fileCarries($0, modern: profile == .modern) } == true
        try await store.sealQueuedOutgoing(accountID: account, messageID: message.id, profile: profile.rawValue,
                                           expectedRevision: revision, state: encode(state, account: account), wire: JSONEncoder().encode(saved),
                                           clearReply: droppedReply)
        return droppedReply
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
        // Modern peers get an encrypted reaction to an authenticated reference. Legacy peers
        // (Conversations) can only receive plain XEP-0444, so any unique stored wire ID will do.
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

    /// Unsend one of our own messages (XEP-0424). Modern peers get it inside the envelope; legacy
    /// peers a plain stanza, exactly like reactions. Projected immediately, sent through the outbox.
    @discardableResult
    public func queueRetraction(account: String, chatID: String, messageID: String) async throws -> String {
        try await gate.run { try await self.queueMessageUpdateLocked(account: account, chatID: chatID, messageID: messageID, kind: .retraction, body: "") }
    }

    /// Rewrite one of our own messages (XEP-0308). The new body is encrypted for every peer; for
    /// legacy peers the reference travels outside the ciphertext, bound like a legacy reaction.
    @discardableResult
    public func queueCorrection(account: String, chatID: String, messageID: String, body: String) async throws -> String {
        try await gate.run { try await self.queueMessageUpdateLocked(account: account, chatID: chatID, messageID: messageID, kind: .correction, body: body) }
    }

    private func queueMessageUpdateLocked(account: String, chatID: String, messageID: String, kind: StoredUpdate.Kind, body: String) async throws -> String {
        let (_, state) = try await load(account)
        // ponytail: direct chats only; rooms need the group envelope path and a real-JID actor rule.
        guard state.groupRooms[chatID] == nil, let profile = state.profiles[chatID],
              let target = try await store.message(accountID: account, messageID: messageID),
              target.chatID == chatID, target.isOutgoing, target.senderID == account, let wireID = target.wireID,
              profile == .legacy || (target.encryptionProfile == XMPPOMEMOProfile.modern.rawValue && target.wireIDAuthenticated),
              try await store.reactionTarget(accountID: account, chatID: chatID, wireID: wireID)?.id == target.id
        else { throw OMEMOError.unsupportedMessageUpdate }
        let id = UUID().uuidString
        _ = try await store.enqueueMessageUpdate(accountID: account, id: id, kind: kind, chatID: chatID, targetMessageID: messageID, body: body)
        return id
    }

    /// Queue a delivery receipt (`.receipt`) or read marker (`.marker`) for a peer's message. Nil when the
    /// account's switch is off, the chat is a group, or the target has no usable identity: nothing to send.
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

    /// Every update the drain may claim now: direct reactions, receipts, retractions and corrections sealed
    /// here (plain wire for legacy peers, envelope for modern ones); key transports are sealed when they are created.
    public func prepareAvailableUpdates(account: String, transport: any OMEMOTransport) async throws -> EncryptionPreparation {
        try await gate.run { try await self.prepareUpdatesLocked(account: account, transport: transport) }
    }

    private func prepareUpdatesLocked(account: String, transport: any OMEMOTransport) async throws -> EncryptionPreparation {
        // One sealing rule for every kind: the plain stanza is the wire for a legacy peer, an SCE payload for a modern one.
        // A correction has a body, so it is encrypted for legacy peers too (`plain` is nil) and its reference rides outside.
        struct Pending { let id: String; let chatID: String; let kind: StoredUpdate.Kind; let plain: (() throws -> String)?; let plaintext: (_ modern: Bool) throws -> Data }
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
            guard let target = update.targetWireID, let body = update.payload.flatMap(MessageEvent.correctionBody) else { continue }
            // Editing a caption re-sends the same file reference: a peer that replaces the whole message keeps the attachment.
            var attachment: StoredAttachment?
            if let id = update.targetMessageID { attachment = try await store.message(accountID: account, messageID: id)?.attachment }
            let file = try attachment.map { try fileSharing(for: $0, account: account) }
            queued.append(Pending(id: update.id, chatID: update.chatID, kind: .correction, plain: nil,
                                  plaintext: { modern in try EncryptedContent.encode(body: body, reply: nil, sender: account, recipient: update.chatID,
                                                                                     modern: modern, originID: update.id, fileSharing: file, correction: target) }))
        }
        var ready = Set(try await store.queuedUpdates(accountID: account, kind: .keyTransport).map(\.id)), blocked: [String: String] = [:]
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
                    try await store.sealQueuedUpdate(accountID: account, updateID: update.id, expectedRevision: revision,
                                                     state: encode(state, account: account), wire: JSONEncoder().encode(saved))
                }
                ready.insert(update.id)
            } catch {
                if error is CancellationError { throw error }
                if failure == nil { failure = (error as? OMEMOError) ?? .unavailable }
                blocked[update.chatID] = (error as? OMEMOError)?.errorDescription ?? "The private update remains queued."
            }
        }
        return EncryptionPreparation(messageIDs: ready, blockedChats: blocked, failure: failure)
    }

    /// SM may retransmit a journaled stanza only when it is exactly one durable outgoing row of ours:
    /// a plain wire byte-for-byte, or a prepared envelope that still re-derives under current trust.
    /// Anything else (unknown IDs, forged recipients, group ciphertext, drifted trust) refuses resumption.
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

    /// The sealed envelope of a message-scoped update (reaction, receipt, marker, retraction, correction),
    /// re-validated: its target must still resolve to the message it was queued against and every
    /// recipient device must still be trusted.
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

    /// The one drain for every update kind. Transport ownership is enforced by MessageStore. A
    /// preflight failure (trust, membership, malformed wire) releases the claim before any socket
    /// use; an attempted send stays unconfirmed until SM/archive proves acceptance.
    /// `updateIDs == nil` claims anything sealed; group rows need a group transport to re-check membership.
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

    /// Delivery bookkeeping only (`MessageStore.rejectOutgoing`): a returned stanza is never decrypted, and no crypto
    /// state changes, so this does not take the operation gate.
    public func rejectOutgoing(account: String, chatID: String, wireID: String, rejection: String, firstOnly: Bool = false) async throws -> RejectedOutgoing? {
        try await store.rejectOutgoing(accountID: account, chatID: chatID, wireID: wireID, rejection: rejection, firstOnly: firstOnly)
    }

    /// Conversations and most deployed clients react unencrypted even in OMEMO chats. The actor is
    /// server-authenticated only; the untrusted target still has to resolve to one stored message.
    /// Returns false for content this client ignores; throws only when storage fails.
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

    /// A plain XEP-0184/0333 element from the peer (Conversations, slixmpp), or our own coming back
    /// from the archive or as a carbon. Receiving is unconditional; the store decides whether the target is ours.
    /// Our own `displayed` (this device's, or another device's) moves the chat's read pointer forward: the sender is
    /// our account as the server stamped it (a validated carbon or own-archive entry), never a peer's claim.
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

    /// XEP-0490 items from our own PEP node (the transport verified they came from our bare JID). Each moves its chat's
    /// read pointer forward when its id names a stored message; unknown ids are ignored. True when any pointer moved.
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
        if let update = try await store.update(accountID: account, updateID: message.id), update.chatID == bare(recipient),
           let wire = try await store.updateWire(accountID: account, updateID: message.id) {
            guard savedEnvelope(wire) == message.envelope else { return false }
            return try await store.reconcileArchivedUpdate(accountID: account, updateID: message.id, expectedWire: wire)
        }
        return false
    }

    /// A sealed update wire is a prepared envelope (reactions) or a bare envelope (key transports).
    nonisolated func savedEnvelope(_ wire: Data) -> XMPPOMEMOEnvelope? {
        (try? JSONDecoder().decode(PreparedEnvelope.self, from: wire))?.envelope ?? (try? JSONDecoder().decode(XMPPOMEMOEnvelope.self, from: wire))
    }

    /// Persist ciphertext before asking for keys/trust: a sender device that is unknown or not yet approved is
    /// retained before any network request or trust wait. This also covers first-contact messages received before the
    /// user has reviewed the fingerprint sheet. A known, approved sender device decrypts without that extra write; any
    /// failure it hits still leaves a placeholder or a retained row before the error, or nothing durable at all only
    /// when storage itself failed (the caller must then not acknowledge the stanza).
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
        // A. Validate and identify. The cached state costs one revision read; the device ID comes from the snapshot
        // header, so nothing is imported into a crypto engine before we know this ciphertext is new and addressed to us.
        let (_, initialState) = try await load(account)
        let localID = try localDeviceID(initialState, message.envelope.profile)
        if sender == account && message.envelope.senderDeviceID == localID { return false }
        let addressedKeys = message.envelope.keys.filter { $0.deviceID == localID && (message.envelope.profile == .legacy || $0.recipientJID == account) }
        if addressedKeys.count != 1 {
            // Never decryptable here: no key for this device (another own device's send, history from before this
            // installation) or ambiguous keys. A message that would have been a bubble leaves a durable placeholder
            // first; the error is thrown only once that outcome exists. A store error propagates as itself.
            let reason: UnreadableReason = addressedKeys.isEmpty ? .notForThisDevice : .malformedContent
            if Self.expectsBubble(message) {
                _ = try await store.recordUnreadableMessage(placeholder(for: message, account: account, reason: reason, sentAt: sentAt,
                                                                        key: .ciphertext(sender: sender, digest: try unaddressedDigest(message))))
            }
            throw addressedKeys.isEmpty ? OMEMOError.notForThisDevice : OMEMOError.undecryptable
        }
        let digest = try ciphertextDigest(message, key: addressedKeys[0])
        if try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest) {
            // Seen live before our archive's id was known: the archive copy names the message XEP-0490 will refer to.
            if let stanzaID = message.archiveStanzaID {
                try await store.bindArchivedDirectStanzaID(accountID: account, sender: sender, digest: digest, stanzaID: stanzaID)
            }
            return false
        }
        // B. This ciphertext's retained row only (a primary-key lookup), then the validated-archive context correction.
        let previous = try await store.pendingEncryptedIncoming(accountID: account, sender: sender, digest: digest)
        var retained = try previous.map { try JSONDecoder().decode(RetainedEnvelope.self, from: $0.wire) }
            ?? RetainedEnvelope(from: message.from, to: message.to, envelope: message.envelope, provenance: message.provenance, sentAt: sentAt ?? Date(),
                                replaces: message.replaces, expectsBubble: Self.expectsBubble(message))
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
                                        provenance: retained.provenance, sentAt: sentAt, replaces: retained.replaces, expectsBubble: retained.expectsBubble)
            guard try await store.replacePendingEncryptedIncomingContext(accountID: account, sender: sender, digest: digest,
                    expectedWire: previous.wire, wire: JSONEncoder().encode(retained)) else { throw OMEMOError.concurrentChange }
        }
        // C. Decide retention before any network await or trust wait. An authenticated session or an already approved
        // sender identity does not need PEP availability to decrypt; inactive approved devices may have delayed traffic.
        // Unknown identities still require network discovery and explicit user approval.
        let profile = message.envelope.profile
        let known = initialState.devices.last {
            $0.jid == sender && $0.profile == profile && $0.deviceID == message.envelope.senderDeviceID
        }
        // A device the user blocked: nothing to review, retry or alert. Its ciphertext is never opened, and a retained
        // copy (an earlier arrival, or a row from before this rule) leaves the table with the final outcome.
        if known?.trust == .rejected {
            return try await recordRejectedDevice(account: account, message: message, sender: sender, digest: digest, sentAt: retained.sentAt)
        }
        // The pending row only has to carry ciphertext across a long wait (trust decision, key fetch, offline). A known
        // sender device whose trust permits decryption needs none: until `receive` returns, the stream token is not
        // acknowledged and the archive cursor does not move, so a process death before the commit below is redelivered,
        // and nothing was written. A retry keeps its row until the commit deletes it.
        let retentionSkipped = previous == nil && known?.trust.permitsEncryption == true
        // Plan D5: someone else's message waiting for trust or keys still alerts, with review wording and no content.
        // Own-device sends (sent carbons, own other devices) never do; the store applies the shared rules as well. Only
        // an envelope that would have been a bubble alerts (the placeholder rule): a key transport, or an SCE reaction,
        // receipt or retraction, must not ask the user to review a message.
        let alert = sender == account || !Self.expectsBubble(message) ? nil
            : PendingNotificationContext(chatID: sender, sentAt: retained.sentAt ?? Date())
        let context = retained
        let peer = sender == account ? bare(message.to ?? account) : sender
        // Past a retention limit the store records this instead of a row, in the same transaction: a quiet placeholder
        // for a would-be bubble, else the consumed replay identity. Either is final, so `receive` then returns false.
        // `approved` marks a copy kept from an approved device, which only the account ceiling bounds.
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
        /// Keeps the ciphertext for a later retry with `reason`: retains it now when C skipped that, else relabels the row.
        /// False when a limit gave it its final outcome instead.
        func hold(_ reason: PendingEncryptedReason) async throws -> Bool {
            if retentionSkipped { return try await retain(reason, notification: alert) }
            try await store.classifyPendingEncryptedIncoming(accountID: account, sender: sender, digest: digest, reason: reason)
            return true
        }
        if known == nil {
            // Only the sending device's list and bundle: its owner's other devices and the other profile are the
            // sending path's business. If this throws (offline), the row is already `keysPending`.
            try await refreshSenderDeviceLocked(account: account, owner: sender, deviceID: message.envelope.senderDeviceID,
                                                profile: profile, transport: transport)
        }
        // D. Decrypt and commit under the current state (still the cached one unless the targeted refresh saved).
        do {
            let (revision, old) = try await load(account)
            var state = old
            let local = try engine(state, profile)
            // The addressed key was chosen for `localID`; an engine for another device ID is a state problem.
            guard local.deviceID == localID else { throw OMEMOError.stateUnavailable }
            guard let device = state.devices.last(where: { $0.jid == sender && $0.profile == profile && $0.deviceID == message.envelope.senderDeviceID }) else {
                // The refresh completed (or was not needed) and the sender device is still unknown: wait for its device list.
                guard try await hold(.keysPending) else { return false }
                throw OMEMOError.trustRequired
            }
            // The refresh found a key the user had blocked under this device ID.
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
                        // An edit is a projection on the original bubble, never a second bubble.
                        guard sender == account || sender == peer else { throw OMEMOError.invalidContent }
                        event = MessageEvent(id: content.originID ?? message.originID ?? message.id, chatID: peer, actorID: sender, targetWireID: target,
                                             kind: .correction, payload: try MessageEvent.correctionPayload(content.body), updatedAt: date)
                    } else if !content.body.isEmpty || content.fileSharing != nil {
                        stored = StoredMessage(id: UUID().uuidString, accountID: account, chatID: peer, senderID: sender,
                                               body: content.body, sentAt: retained.sentAt ?? Date(), isOutgoing: sender == account,
                                               reply: content.reply, encryptionProfile: profile.rawValue,
                                               // XEP-0444 targets the stanza id in 1:1 chats; peers without origin-id (Conversations) still get one.
                                               wireID: content.originID ?? message.originID ?? message.id, wireIDAuthenticated: content.originID != nil,
                                               attachment: try content.fileSharing.map { try storedAttachment($0, account: account) })
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
                // Context, not ciphertext: the retained row waits for a validated archive stamp (today's behaviour).
                // With retention skipped, the handler below writes that row before the error leaves `receive`.
                throw OMEMOError.invalidContent
            } catch let error as OMEMOCryptoError where error != .invalidSnapshot {
                // A trusted device's ciphertext that cannot decrypt, authenticate or decode never will: it leaves the
                // pending table (or never enters it) as a durable outcome. The ephemeral engine is discarded; no ratchet
                // state is committed.
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
            // The peer asked for a delivery receipt: queue it durably now; the drain sends it under the account switch.
            if let stored, sender == peer, message.requestsReceipt {
                _ = try? await queueReceiptLocked(account: account, chatID: peer, messageID: stored.id, kind: .receipt)
            }
            // The authenticated message is already durable. A network error must not turn
            // success into a decryption failure; the pending publication survives a restart.
            if key.keyExchange { try? await flushBundlePublicationsLocked(account: account, transport: transport) }
            return stored != nil || reaction != nil || event != nil || readMarker != nil
        } catch let failure {
            // C skipped retention and this failure left no durable outcome (a commit conflict, a state or storage error,
            // content the store refuses, a sending time awaiting an archive stamp): keep the ciphertext now, with the
            // reason the pre-skip path gave it, so a failure that repeats on redelivery cannot wedge the archive walk.
            // When that write fails too, nothing is durable: `hasDurableIncomingDisposition` is false and the caller
            // tears the stream down, as for any storage failure. Past a limit the overflow is the final outcome.
            if retentionSkipped, !Self.leavesDurableOutcome(failure) {
                let kept: Bool
                do { kept = try await retain(.trustPending, notification: nil, approved: true) } catch { throw failure }
                if !kept { return false }
            }
            throw failure
        }
    }

    /// Errors `receive` throws only once their outcome is durable: a placeholder (`undecryptable`) or a retained row
    /// awaiting keys or trust (`trustRequired`).
    static func leavesDurableOutcome(_ error: any Error) -> Bool {
        guard let error = error as? OMEMOError else { return false }
        return error == .undecryptable || error == .trustRequired
    }

    /// A stream/archive acknowledgment is safe after either an authenticated commit or
    /// durable retention for later key/trust review. A storage error must not advance it.
    /// This deliberately uses the same ciphertext identity as receive, not outer stanza IDs.
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
        // Old archives can predate this installation, and other own devices may not encrypt for this one. With no
        // single key for this device the disposition is the placeholder when the envelope would have been a bubble,
        // and nothing at all otherwise (a reaction or receipt from a device that excluded this one).
        if keys.count != 1 {
            guard Self.expectsBubble(message) else { return true }
            return try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: try unaddressedDigest(message))
        }
        let digest = try ciphertextDigest(message, key: keys[0])
        if try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest) { return true }
        return try await store.pendingEncryptedIncoming(accountID: account, sender: sender, digest: digest) != nil
    }

    /// D4: would this envelope have been a bubble here? Only then does an exclusion deserve a placeholder. Modern (SCE)
    /// payloads also carry reactions, receipts and retractions, so they need an outer hint: the XEP-0384 `<body/>`
    /// fallback, or a receipt/marker request (this client requests those on messages only). Legacy payloads are messages.
    static func expectsBubble(_ message: XMPPEncryptedMessage) -> Bool {
        message.envelope.payload != nil
            && (message.envelope.profile == .legacy || message.hasFallbackBody || message.requestsReceipt || message.markable)
    }
    static func expectsBubble(_ message: XMPPEncryptedGroupMessage) -> Bool {
        message.envelope.payload != nil && message.hasFallbackBody
    }

    /// Ciphertext identity when no key addresses this device: profile, sender device, iv and payload, domain-separated
    /// from `ciphertextDigest` so the two can never collide.
    func unaddressedDigest(_ message: XMPPEncryptedMessage) throws -> String {
        let identity = UnaddressedCiphertextIdentity(profile: message.envelope.profile, senderDeviceID: message.envelope.senderDeviceID,
                                                     iv: message.envelope.iv, payload: message.envelope.payload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var material = Data("unaddressed\u{0}".utf8)
        material.append(try encoder.encode(identity))
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the placeholder for a direct envelope: the chat is the peer (the sender, or the recipient of an own send),
    /// the author is the sender's bare JID, and the time is the validated archive stamp or now. Never content.
    func placeholder(for message: XMPPEncryptedMessage, account: String, reason: UnreadableReason, sentAt: Date?,
                     key: UnreadableMessage.Key) -> UnreadableMessage {
        let sender = bare(message.from)
        let outgoing = sender == account
        return UnreadableMessage(accountID: account, chatID: outgoing ? bare(message.to ?? account) : sender, senderID: sender,
                                 isOutgoing: outgoing, sentAt: sentAt ?? Date(), reason: reason, key: key)
    }

    /// The final outcome for ciphertext from a device the user blocked: a quiet `rejectedDevice` placeholder when it would
    /// have been a bubble, else only the consumed replay identity. Nothing is decrypted, no alert is queued, and a retained
    /// copy leaves the table (with its review candidate) in the same transaction. Returns false: nothing new to show.
    private func recordRejectedDevice(account: String, message: XMPPEncryptedMessage, sender: String, digest: String, sentAt: Date?) async throws -> Bool {
        if Self.expectsBubble(message) {
            try await store.recordUnreadableMessage(placeholder(for: message, account: account, reason: .rejectedDevice, sentAt: sentAt,
                                                                key: .ciphertext(sender: sender, digest: digest)))
        } else {
            try await store.consumeUndecryptableIncoming(accountID: account, sender: sender, digest: digest)
        }
        return false
    }

    /// Records the durable `decryptFailed` outcome for ciphertext this device will never read. Works whether or not a
    /// pending row exists (the DELETE inside the store is then a no-op). A key transport (no payload) was never a
    /// bubble, so only its replay identity is consumed. Returns true when a placeholder row marks the message.
    /// Never called for storage, cancellation or state errors; those propagate without a disposition.
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

    /// Conversation addresses/counts only; retained ciphertext is not authenticated display content.
    /// This lets first-contact trust requests remain discoverable without inventing message bubbles.
    /// Counted from the store's projection of the retained envelopes, so no ciphertext is read or decoded here.
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

    /// Retries retained ciphertext. `reasons` narrows the work to what the triggering event can unblock: a trust decision
    /// retries `trustPending`, a device list retries `keysPending` from its owner, a connection retries both.
    /// A row that now fails permanently becomes a placeholder and leaves the table, so it is never retried again; so does
    /// a row whose sender device the user has blocked since (or before an upgrade that stopped retaining those).
    public func retryPendingIncoming(account: String, transport: any OMEMOTransport,
                                     reasons: Set<PendingEncryptedReason> = [.trustPending, .keysPending],
                                     sender: String? = nil) async throws {
        let pending = try await store.pendingEncryptedIncoming(accountID: account, reasons: reasons, sender: sender)
        var firstFailure: (any Error)?
        // A room still unknown after one attempt in this pass is not refreshed again for its other rows.
        var unresolvedRooms: Set<String> = []
        for item in pending {
            do {
                // Each wire is decoded once. The pre-checks read the cached state (one revision read when unchanged)
                // and skip rows that would only throw `trustRequired` again after all the work.
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
                // A row written before the bubble hint was kept counts as a bubble, so a blocked device's retained message
                // still leaves a placeholder rather than vanishing.
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

    /// A skipped row now waits only for a trust decision on a device that became known elsewhere (for example a
    /// `keysPending` row whose device a full refresh added). Relabel it as `receive` would have, so the retry that
    /// follows that decision (`reasons: [.trustPending]`) selects it.
    private func awaitTrustDecision(_ item: PendingEncryptedMessage, account: String) async throws {
        guard item.reason != .trustPending else { return }
        try await store.classifyPendingEncryptedIncoming(accountID: account, sender: item.sender, digest: item.digest, reason: .trustPending)
    }

    /// The current state and its CAS revision. Reads the revision first and decodes the sealed blob only when it
    /// differs from the cached one; the pair returned always comes from a single row (or our own commit of it).
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
    /// After a successful CAS write from `expected`, the row is `expected + 1` holding exactly `state`.
    func committed(_ state: AccountEncryptionState, revision expected: Int, account: String) {
        remember(state, revision: expected + 1, account: account)
    }
    /// A failed write may have left anything behind in memory; the next `load` reads the row again.
    func forgetState(_ account: String) { stateCache[account] = nil }
    private func remember(_ state: AccountEncryptionState, revision: Int, account: String) {
        // An interleaved load may already hold a newer revision; keep whichever was read later in revision order.
        if let cached = stateCache[account], cached.revision > revision { return }
        stateCache[account] = (revision, state)
    }
    /// This installation's device ID for `profile`, read from the engine snapshot's top-level field without importing
    /// the ratchet records into the crypto engine. Validates the same way `engine` does before trusting it.
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
    /// In normal form (`JID`), so ciphertext retained or saved by a build that kept typed capitals still matches.
    func bare(_ jid: String) -> String { JID.normalizedBare(jid) ?? String(jid.split(separator: "/", maxSplits: 1).first ?? "") }
}

/// The two top-level fields of an `OMEMOEngine` snapshot needed to identify it; the rest stays opaque here.
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
    /// Outer legacy correction reference, kept with the ciphertext so a trust retry still applies it.
    var replaces: String? = nil
    /// `expectsBubble` of the arriving stanza, whose outer hints are not otherwise kept. Nil in rows written before it was.
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
