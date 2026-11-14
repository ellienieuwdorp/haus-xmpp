import Foundation
import MessageStore
import OMEMOCrypto
import XMPPProtocol

extension OMEMOService {
    /// Checks this device's identity against the server. Both versions' lists and own bundles are read at once outside
    /// the operation gate; a bundle is published only when pending, missing or different, and a list rewritten only
    /// when it lacks this device or names a given-up ID.
    public func initialize(account: String, transport: any OMEMOTransport) async throws {
        let local = try await gate.run { try await self.prepareIdentityLocked(account: account) }
        async let legacy = observeOwnPublication(account: account, profile: .legacy, deviceID: local, transport: transport)
        async let modern = observeOwnPublication(account: account, profile: .modern, deviceID: local, transport: transport)
        let observed = [try await legacy, try await modern]
        try await gate.run { try await self.reconcileOwnPublicationsLocked(observed, account: account, deviceID: local, transport: transport) }
    }

    private func prepareIdentityLocked(account: String) async throws -> UInt32 {
        // A pass that fails before a version's bundle is confirmed (another identity under our ID, a timeout) leaves
        // that version unadvertised by `maintainLocalAdvertisement`.
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
        let legacyFingerprint = try OMEMOEngine.fingerprintBytes(for: legacyIdentity.identityKey, profile: .legacy)
        let modernFingerprint = try OMEMOEngine.fingerprintBytes(for: modernIdentity.identityKey, profile: .modern)
        guard legacyFingerprint == modernFingerprint, legacyIdentity.deviceID == modernIdentity.deviceID else {
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
        }
        return legacyIdentity.deviceID
    }

    private struct OwnPublication: Sendable {
        let profile: XMPPOMEMOProfile
        let devices: [UInt32]
        let bundle: Result<XMPPOMEMOBundle?, any Error>
    }

    private func observeOwnPublication(account: String, profile: XMPPOMEMOProfile, deviceID: UInt32,
                                       transport: any OMEMOTransport) async throws -> OwnPublication {
        async let bundle: Result<XMPPOMEMOBundle?, any Error> = {
            do { return .success(try await transport.fetchOMEMOBundle(for: account, deviceID: deviceID, profile: profile)) }
            catch XMPPIQError.stanza(condition: "item-not-found") { return .success(nil) }
            catch { return .failure(error) }
        }()
        let devices = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
        return OwnPublication(profile: profile, devices: devices, bundle: await bundle)
    }

    private func reconcileOwnPublicationsLocked(_ observed: [OwnPublication], account: String, deviceID: UInt32,
                                                transport: any OMEMOTransport) async throws {
        // Either version's mismatch fails closed before anything is written in the other.
        for publication in observed { _ = try await verifyOwnPublicationLocked(publication, account: account, deviceID: deviceID) }
        for publication in observed {
            try await reconcileOwnPublicationLocked(publication, account: account, deviceID: deviceID, transport: transport)
        }
    }

    private typealias Verified = (state: AccountEncryptionState, engine: OMEMOEngine, published: XMPPOMEMOBundle?)

    private func verifyOwnPublicationLocked(_ observed: OwnPublication, account: String, deviceID: UInt32) async throws -> Verified {
        let (_, state) = try await load(account)
        let engine = try engine(state, observed.profile)
        // Only a reset replaces the identity, and it runs under the lease with transport work stopped.
        guard engine.deviceID == deviceID else { throw OMEMOError.concurrentChange }
        let listed = observed.devices.contains(deviceID)
        let published: XMPPOMEMOBundle?
        switch observed.bundle {
        case .success(let bundle): published = bundle
        // Listed, any failure but item-not-found is not proof of absence and fails unchanged; unlisted, ours goes over it.
        case .failure(let error): if listed { throw error } else { published = nil }
        }
        if listed, let published, published.identityKey != (try engine.identityKey) { throw OMEMOError.identityChanged }
        return (state, engine, published)
    }

    private func reconcileOwnPublicationLocked(_ observed: OwnPublication, account: String, deviceID: UInt32,
                                               transport: any OMEMOTransport) async throws {
        let profile = observed.profile
        let (state, engine, published) = try await verifyOwnPublicationLocked(observed, account: account, deviceID: deviceID)
        let listed = observed.devices.contains(deviceID)
        let local = wireBundle(try engine.bundle(), profile: profile)
        let pending = state.pendingBundlePublications.contains(profile.rawValue)
        // Missing, older (a consumed prekey, a rotated signed prekey) or another identity's under an unlisted ID.
        if pending || published != local { try await transport.publishOMEMOBundle(local) }
        publishedBundles[account, default: []].insert(profile)
        let retired = try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue, statuses: [.pending])
        if !listed || !retired.isDisjoint(with: observed.devices) {
            // The list changes: another client may have registered since it was read, so it is read again first.
            try await maintainLocalAdvertisementLocked(account: account, profile: profile, transport: transport, removingRetired: true)
        } else {
            var removed = try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue, statuses: [.removed])
            try await reclaimListed(observed.devices, account: account, profile: profile, removed: &removed)
        }
        guard pending else { return }
        let (publishedRevision, publishedOld) = try await load(account)
        var cleared = publishedOld
        cleared.pendingBundlePublications.remove(profile.rawValue)
        try await save(cleared, revision: publishedRevision, account: account)
    }

    func reclaimListed(_ list: [UInt32], account: String, profile: XMPPOMEMOProfile, removed: inout Set<UInt32>) async throws {
        let back = removed.intersection(list)
        guard !back.isEmpty else { return }
        try await store.advanceRetiredOwnDevices(accountID: account, profile: profile.rawValue, deviceIDs: back, to: .reclaimed)
        removed.subtract(back)
    }
}
