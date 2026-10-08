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
    public func refreshOwnDevices(account: String, transport: any OMEMOTransport) async throws -> [EncryptionDevice] {
        try await gate.run { try await self.refreshOwnDevicesLocked(account: account, transport: transport) }
    }

    private func refreshOwnDevicesLocked(account: String, transport: any OMEMOTransport) async throws -> [EncryptionDevice] {
        let (revision, old) = try await load(account)
        var state = old
        for profile in [XMPPOMEMOProfile.legacy, .modern] {
            let ids = try validatedDevices(await transport.fetchOMEMODevices(for: account, profile: profile))
            _ = try await mergeAdvertised(ids, owner: account, profile: profile, skipping: try localDeviceID(state, profile),
                                          transport: transport, into: &state)
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
