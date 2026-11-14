import Foundation
import XMPPProtocol

// A refresh's lookups, asked together. Each answer, success or failure, is kept as returned and read in the refresh's
// own order, so validation and fatal failures are those of lookups asked one at a time.
struct DeviceLookups: Sendable {
    struct List: Hashable, Sendable {
        let owner: String
        let profile: XMPPOMEMOProfile
    }
    struct Bundle: Hashable, Sendable {
        let owner: String
        let deviceID: UInt32
        let profile: XMPPOMEMOProfile
    }

    // Below the client's limit of pending queries, which other work on the connection shares.
    static let width = 16

    let transport: any OMEMOTransport

    private var lists: [List: Result<[UInt32], any Error>] = [:]
    private var bundles: [Bundle: Result<XMPPOMEMOBundle?, any Error>] = [:]

    func list(_ owner: String, _ profile: XMPPOMEMOProfile) throws -> [UInt32] {
        guard let answer = lists[List(owner: owner, profile: profile)] else { throw OMEMOError.unavailable }
        return try answer.get()
    }

    func bundle(_ owner: String, _ deviceID: UInt32, _ profile: XMPPOMEMOProfile) throws -> XMPPOMEMOBundle? {
        guard let answer = bundles[Bundle(owner: owner, deviceID: deviceID, profile: profile)] else { throw OMEMOError.unavailable }
        return try answer.get()
    }

    // A bundle asked for a device the list no longer names is never read, so its failure cannot fail the refresh.
    mutating func ask(lists wanted: [List] = [], bundles wantedBundles: [Bundle] = []) async {
        let transport = transport
        enum Lookup: Sendable {
            case list(List)
            case bundle(Bundle)
        }
        enum Answer: Sendable {
            case list(List, Result<[UInt32], any Error>)
            case bundle(Bundle, Result<XMPPOMEMOBundle?, any Error>)
        }
        var pending = wanted.filter { lists[$0] == nil }.map(Lookup.list) + wantedBundles.filter { bundles[$0] == nil }.map(Lookup.bundle)
        guard !pending.isEmpty else { return }
        pending.reverse()
        let answers = await withTaskGroup(of: Answer.self, returning: [Answer].self) { group in
            func start(_ lookup: Lookup) {
                group.addTask {
                    switch lookup {
                    case .list(let key):
                        do { return .list(key, .success(try await transport.fetchOMEMODevices(for: key.owner, profile: key.profile))) }
                        catch { return .list(key, .failure(error)) }
                    case .bundle(let key):
                        do {
                            return .bundle(key, .success(try await OMEMOService.availableBundle(owner: key.owner, deviceID: key.deviceID,
                                                                                             profile: key.profile, transport: transport)))
                        } catch { return .bundle(key, .failure(error)) }
                    }
                }
            }
            for _ in 0..<Self.width { if let next = pending.popLast() { start(next) } }
            var answers: [Answer] = []
            for await answer in group {
                answers.append(answer)
                if let next = pending.popLast() { start(next) }
            }
            return answers
        }
        for answer in answers {
            switch answer {
            case .list(let key, let result): lists[key] = result
            case .bundle(let key, let result): bundles[key] = result
            }
        }
    }
}

extension OMEMOService {
    struct RefreshedOwners {
        var advertised: [String: Int] = [:]
        var unavailable: [String: Int] = [:]
        var otherVersionOnly: [String: Int] = [:]
    }

    func listLookups(_ owners: [String]) -> [DeviceLookups.List] {
        owners.flatMap { owner in XMPPOMEMOProfile.allCases.map { DeviceLookups.List(owner: owner, profile: $0) } }
    }

    // Bundles of the devices stored as listed, asked beside the lists: an unchanged list then needs no second round.
    func advertisedLookups(_ owners: [String], account: String, profile: XMPPOMEMOProfile,
                           state: AccountEncryptionState) async throws -> [DeviceLookups.Bundle] {
        let skipped = try await skippedOwnDevices(state, account: account, profile: profile)
        return state.devices.filter { device in
            device.profile == profile && device.active && owners.contains(device.jid) && !(device.jid == account && skipped.contains(device.deviceID))
        }.map { DeviceLookups.Bundle(owner: $0.jid, deviceID: $0.deviceID, profile: profile) }
    }

    // The other version's list only feeds the incompatibility hint.
    func mergeRefreshed(_ owners: [String], account: String, profile: XMPPOMEMOProfile, lookups: DeviceLookups,
                        into state: inout AccountEncryptionState) async throws -> RefreshedOwners {
        var lookups = lookups
        var result = RefreshedOwners()
        _ = try engine(state, profile)
        // Own devices given up by `startOver` are not offered for review while listed, unless reclaimed: then something
        // still holds the key and it is reviewed like any other device.
        let skipped = try await skippedOwnDevices(state, account: account, profile: profile)
        let otherProfile: XMPPOMEMOProfile = profile == .legacy ? .modern : .legacy
        var listed: [String: [UInt32]] = [:]
        for owner in owners {
            let ids = try validatedDevices(lookups.list(owner, profile))
            guard ids.count <= 200 else { throw OMEMOError.invalidContent }
            listed[owner] = ids
            result.advertised[owner] = ids.count
            let otherIDs = (try? validatedDevices(lookups.list(owner, otherProfile))) ?? []
            // Device IDs do not prove identity across profiles, so an other-version-only device is never encrypted to.
            // That is reported, not enforced: refusing to send would queue messages indefinitely.
            let onlyOther = Set(otherIDs).subtracting(ids).count
            if onlyOther > 0 { result.otherVersionOnly[owner] = onlyOther }
        }
        let wanted = owners.flatMap { owner in
            (listed[owner] ?? []).filter { !(owner == account && skipped.contains($0)) }
                .map { DeviceLookups.Bundle(owner: owner, deviceID: $0, profile: profile) }
        }
        await lookups.ask(bundles: wanted)
        try Task.checkCancellation()
        let answers = lookups
        for owner in owners {
            let missing = try await mergeAdvertised(listed[owner] ?? [], owner: owner, profile: profile,
                                                    skipping: owner == account ? skipped : [], into: &state) { id in
                try answers.bundle(owner, id, profile)
            }
            if missing > 0 { result.unavailable[owner] = missing }
        }
        return result
    }
}
