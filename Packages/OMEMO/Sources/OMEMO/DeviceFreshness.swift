import Foundation
import MessageStore
import XMPPProtocol

// Lookups read on this stream stay current while its `XMPPDeviceEpoch` is unchanged: for an owner whose list it
// received as a notification until the next event, for any other owner, whose changes are not announced, for `window`.
struct DeviceFreshness {
    static let window: Duration = .seconds(5)
    private static let origin = ContinuousClock.now

    struct Key: Hashable {
        let account: String
        let owner: String
        let profile: XMPPOMEMOProfile
    }
    // The epoch is read before the lookups are asked, and recorded only if the stream still shows it after.
    struct Reading {
        let epoch: XMPPDeviceEpoch
        let at: Duration
    }
    struct Answer {
        let reading: Reading
        let otherVersionOnly: Bool
    }

    var now: @Sendable () -> Duration = { ContinuousClock.now - DeviceFreshness.origin }
    private var answered: [Key: Answer] = [:]

    mutating func record(_ owners: [String], account: String, profile: XMPPOMEMOProfile, reading: Reading, otherVersionOnly: [String: Int]) {
        answered = answered.filter { $0.value.reading.epoch.isUnchanged(since: reading.epoch) }
        for owner in owners {
            answered[Key(account: account, owner: owner, profile: profile)] = Answer(reading: reading, otherVersionOnly: otherVersionOnly[owner] != nil)
        }
    }

    func current(_ owners: [String], account: String, profile: XMPPOMEMOProfile, epoch: XMPPDeviceEpoch?,
                 noOtherVersionOnly compatible: Bool = false) -> Bool {
        guard let epoch else { return false }
        let now = now()
        return owners.allSatisfy { owner in
            guard let answer = answered[Key(account: account, owner: owner, profile: profile)],
                  epoch.isUnchanged(since: answer.reading.epoch), !(compatible && answer.otherVersionOnly) else { return false }
            return epoch.notifies(owner, profile: profile) || now - answer.reading.at < Self.window
        }
    }

    mutating func forget(_ owner: String, account: String) {
        answered = answered.filter { $0.key.account != account || $0.key.owner != owner }
    }
}

extension OMEMOService {
    func useDeviceClock(_ now: @escaping @Sendable () -> Duration) { freshDevices.now = now }

    func refreshUnlessCurrent(account: String, peer: String, profile requested: XMPPOMEMOProfile?, transport: any OMEMOTransport,
                              updateSelection: Bool) async throws {
        let (_, state) = try await load(account)
        if let profile = requested ?? state.profiles[peer],
           freshDevices.current(Array(Set([account, peer])), account: account, profile: profile, epoch: await transport.omemoDeviceEpoch()) {
            return
        }
        _ = try await refreshLocked(account: account, peer: peer, profile: requested, transport: transport, updateSelection: updateSelection)
    }

    // Every member's devices as a chat refresh with that member stores them, the account's own read once for all.
    func refreshMembersLocked(_ owners: [String], account: String, transport: any OMEMOGroupTransport) async throws {
        let (revision, old) = try await load(account)
        var state = old
        let reading = await transport.omemoDeviceEpoch().map { DeviceFreshness.Reading(epoch: $0, at: freshDevices.now()) }
        var lookups = DeviceLookups(transport: transport)
        await lookups.ask(lists: listLookups(owners), bundles: try await advertisedLookups(owners, account: account, profile: .modern, state: old))
        let refreshed = try await mergeRefreshed(owners, account: account, profile: .modern, lookups: lookups, into: &state)
        try await save(state, revision: revision, account: account)
        guard refreshed.otherVersionOnly.isEmpty else { throw OMEMOError.unsupportedProfile }
        if let reading, await transport.omemoDeviceEpoch()?.isUnchanged(since: reading.epoch) == true {
            freshDevices.record(owners, account: account, profile: .modern, reading: reading, otherVersionOnly: refreshed.otherVersionOnly)
        }
    }

    // Receive path for an unseen sender device: one device list and one bundle, leaving selection and other devices
    // alone. An unlisted device or a missing bundle leaves state unchanged and the caller waits for keys.
    func refreshSenderDeviceLocked(account: String, owner: String, deviceID: UInt32, profile: XMPPOMEMOProfile,
                                   transport: any OMEMOTransport) async throws {
        // An unknown device means the owner's list moved; the next send reads all of it.
        freshDevices.forget(owner, account: account)
        let ids = try validatedDevices(await transport.fetchOMEMODevices(for: owner, profile: profile))
        guard ids.contains(deviceID) else { return }
        // A given-up own device is not added until reclaimed; its message waits until then.
        if owner == account,
           try await store.retiredOwnDevices(accountID: account, profile: profile.rawValue, statuses: [.pending, .removed]).contains(deviceID) { return }
        let bundle: XMPPOMEMOBundle
        do { bundle = try await transport.fetchOMEMOBundle(for: owner, deviceID: deviceID, profile: profile) }
        catch XMPPIQError.stanza(condition: "item-not-found"), XMPPIQError.malformedResponse { return }
        try validateBundle(bundle, id: deviceID, profile: profile)
        let (revision, old) = try await load(account)
        var state = old
        mergeDevice(bundle, owner: owner, profile: profile, id: deviceID, into: &state)
        try await save(state, revision: revision, account: account)
    }
}
