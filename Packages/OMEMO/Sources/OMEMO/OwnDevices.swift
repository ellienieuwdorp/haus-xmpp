import Foundation
import XMPPProtocol

/// The account's other devices, for a review that is not tied to a chat. Trust is stored per device record
/// (owner, version, device ID, identity key) in the account's state, and every 1:1 chat and group addresses the
/// account's own active devices of its version, so one decision here applies to every chat.
extension OMEMOService {
    /// This account's other devices as stored, both OMEMO versions, in stored order. No network; this installation's
    /// own device is never listed.
    public func ownDevices(account: String) async throws -> [EncryptionDevice] {
        let (_, state) = try await load(account)
        return try ownDevices(state, account: account)
    }

    /// Re-reads the account's device list and bundles in both versions and stores them as a chat refresh does, without
    /// choosing a version for any chat. A device seen for the first time, or with a new key, is stored `.undecided`:
    /// nothing is trusted here. Returns `ownDevices`.
    ///
    /// The lists and bundles are fetched before taking the gate and merged under it, so decrypts and seals do not wait
    /// behind these round trips; this runs on every connection. The merge reads the state current at that point.
    public func refreshOwnDevices(account: String, transport: any OMEMOTransport) async throws -> [EncryptionDevice] {
        let (_, snapshot) = try await load(account)
        var fetched: [AdvertisedOwnDevices] = []
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let local = try localDeviceID(snapshot, profile)
            let ids = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
            // The same bound as a chat refresh: one bundle request per listed device.
            guard ids.count <= 200 else { throw OMEMOError.invalidContent }
            var bundles: [UInt32: XMPPOMEMOBundle] = [:]
            for id in ids where id != local {
                bundles[id] = try await availableBundle(owner: account, deviceID: id, profile: profile, transport: transport)
            }
            fetched.append(AdvertisedOwnDevices(profile: profile, ids: ids, bundles: bundles))
        }
        let advertised = fetched
        return try await gate.run { try await self.mergeOwnDevicesLocked(advertised, account: account) }
    }

    private func mergeOwnDevicesLocked(_ advertised: [AdvertisedOwnDevices], account: String) async throws -> [EncryptionDevice] {
        let (revision, old) = try await load(account)
        var state = old
        for list in advertised {
            _ = try await mergeAdvertised(list.ids, owner: account, profile: list.profile, skipping: try localDeviceID(state, list.profile),
                                          into: &state) { list.bundles[$0] }
        }
        try await save(state, revision: revision, account: account)
        return try ownDevices(state, account: account)
    }

    private func ownDevices(_ state: AccountEncryptionState, account: String) throws -> [EncryptionDevice] {
        var local: [XMPPOMEMOProfile: UInt32] = [:]
        for profile in [XMPPOMEMOProfile.legacy, .modern] { local[profile] = try localDeviceID(state, profile) }
        return state.devices.filter { $0.jid == account && $0.deviceID != local[$0.profile] }
    }
}

/// One version's own device list as fetched before the merge; a listed ID without a bundle is gone or unreadable.
private struct AdvertisedOwnDevices: Sendable {
    let profile: XMPPOMEMOProfile
    let ids: [UInt32]
    let bundles: [UInt32: XMPPOMEMOBundle]
}
