import Foundation
import XMPPProtocol
import OMEMOCrypto

public enum DeviceTrust: String, Codable, Sendable {
    case undecided, accepted, verified, rejected
    public var permitsEncryption: Bool { self == .accepted || self == .verified }
}

extension EncryptionDevice {
    /// One of `account`'s own devices that the user rejected: group sends leave it out instead of waiting, as 1:1 chats
    /// do. Other members' rejected devices are not covered and keep holding the group.
    public func isLeftOutOfGroups(account: String) -> Bool { jid == account && trust == .rejected }
}

public struct EncryptionDevice: Identifiable, Codable, Sendable, Equatable {
    public var id: String { "\(jid)|\(profile.rawValue)|\(deviceID)|\(identityKey.map { String(format: "%02x", $0) }.joined())" }
    public let jid: String
    public let profile: XMPPOMEMOProfile
    public let deviceID: UInt32
    public let identityKey: Data
    public var trust: DeviceTrust
    public var active: Bool
    public var identityChanged: Bool
    /// Public for sample data and app tests. A value made here changes nothing stored: trust is only ever set through
    /// `OMEMOService.setTrust` by the identifier of a stored record.
    public init(jid: String, profile: XMPPOMEMOProfile, deviceID: UInt32, identityKey: Data, trust: DeviceTrust,
                active: Bool, identityChanged: Bool) {
        self.jid = jid; self.profile = profile; self.deviceID = deviceID; self.identityKey = identityKey
        self.trust = trust; self.active = active; self.identityChanged = identityChanged
    }
    public var fingerprint: String {
        guard let bytes = try? OMEMOEngine.fingerprintBytes(for: identityKey, profile: profile.crypto) else { return "Invalid identity" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct EncryptionOverview: Sendable {
    public let profile: XMPPOMEMOProfile
    public let localDeviceID: UInt32
    public let localFingerprint: String
    /// The selected version's devices of both owners (the recipients of new messages), followed by any device of the
    /// other version whose retained incoming ciphertext for this chat waits on its trust decision.
    public let devices: [EncryptionDevice]
    /// Some device of either owner is published only in the other OMEMO version. Informational: those devices are
    /// simply not recipients in this version; sending goes ahead to the devices that are.
    public let hasIncompatibleDevices: Bool
    /// Per owner, how many advertised device IDs exist only in the other version (they will not receive these messages).
    public var otherVersionOnlyDevices: [String: Int] = [:]
    /// Advertised device IDs per owner whose bundle could not be fetched; they cannot be reviewed or messaged.
    public var unavailableDevices: [String: Int] = [:]
    /// Device IDs each owner advertised in this version, before bundle checks.
    public var advertisedDevices: [String: Int] = [:]
    /// A device refresh for this peer has completed on this account at some point, so an empty or unusable device
    /// list is a stored answer rather than "not fetched yet". Derived from stored state; no schema change.
    public var isPeerKnown = false
    /// Sending waits: a device of the selected version needs a fingerprint decision.
    public var needsTrust: Bool { devices.contains { $0.profile == profile && $0.active && $0.trust == .undecided } }
    /// Reading waits: messages sent in the other version are held until one of these devices is decided.
    public var needsIncomingReview: Bool { devices.contains { $0.profile != profile && $0.active && $0.trust == .undecided } }
}

public enum OMEMOError: Error, Equatable, Sendable, LocalizedError {
    case unavailable, noDevices, trustRequired, identityChanged, notForThisDevice
    /// Permanently unreadable here (a trusted device's ciphertext failed to decrypt, or keys addressed this device
    /// ambiguously). Thrown only after the durable outcome exists; nothing is retained for review.
    case undecryptable
    case invalidContent, stateUnavailable, unsupportedProfile, concurrentChange, recipientSetChanged, cannotRetireCurrentDevice, unsupportedEncryptedReactions, unsupportedMessageUpdate
    public var errorDescription: String? {
        switch self {
        case .unsupportedEncryptedReactions: "Private reactions require OMEMO 2 and an authenticated message reference. Nothing was sent unencrypted."
        case .unsupportedMessageUpdate: "This message can't be unsent or edited from here. Nothing was sent unencrypted."
        case .cannotRetireCurrentDevice: "This device cannot be removed while it is in use."
        case .unavailable: "Encryption is not ready. Connect to finish setting it up."
        case .noDevices: "No compatible encryption devices were found. Your message is waiting safely on this device."
        case .trustRequired: "Review the encryption devices before sending or opening messages."
        case .identityChanged: "A device’s encryption identity changed. Compare its new fingerprint before continuing."
        case .notForThisDevice: "This message was not encrypted for this device."
        case .undecryptable: "This message could not be decrypted on this device."
        case .invalidContent: "This encrypted message could not be authenticated."
        case .stateUnavailable: "Encryption keys are unavailable. No new identity has been created."
        case .unsupportedProfile: "These devices do not share the selected encryption version."
        case .recipientSetChanged: "The recipient devices changed after this message was encrypted. Start a new message to include the current devices."
        case .concurrentChange: "Encryption state changed. Please try again."
        }
    }
}

struct AccountEncryptionState: Codable {
    var format = 1
    var engines: [String: Data]
    var devices: [EncryptionDevice] = []
    var profiles: [String: XMPPOMEMOProfile] = [:]
    var bundles: [String: XMPPOMEMOBundle] = [:]
    var incompatiblePeers: [String: Bool] = [:]
    var pendingBundlePublications: Set<String> = []
    var groupRooms: [String: [String]] = [:]
    init(engines: [String: Data]) { self.engines = engines }
    enum CodingKeys: String, CodingKey { case format, engines, devices, profiles, bundles, incompatiblePeers, pendingBundlePublications, groupRooms }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(Int.self, forKey: .format)
        engines = try values.decode([String: Data].self, forKey: .engines)
        devices = try values.decodeIfPresent([EncryptionDevice].self, forKey: .devices) ?? []
        profiles = try values.decodeIfPresent([String: XMPPOMEMOProfile].self, forKey: .profiles) ?? [:]
        bundles = try values.decodeIfPresent([String: XMPPOMEMOBundle].self, forKey: .bundles) ?? [:]
        incompatiblePeers = try values.decodeIfPresent([String: Bool].self, forKey: .incompatiblePeers) ?? [:]
        pendingBundlePublications = try values.decodeIfPresent(Set<String>.self, forKey: .pendingBundlePublications) ?? []
        groupRooms = try values.decodeIfPresent([String: [String]].self, forKey: .groupRooms) ?? [:]
        normalizeOwners()
    }

    /// Owners and rooms in normal form (`JID`), for state saved before addresses were normalised. The engines' own
    /// session addresses stay opaque; a device keyed under another spelling gets a fresh session. An entry that
    /// collides with one already in normal form yields to it, so a merge never raises a trust decision.
    private mutating func normalizeOwners() {
        func normal(_ jid: String) -> String { JID.normalizedBare(jid) ?? jid }
        guard devices.contains(where: { normal($0.jid) != $0.jid }) || profiles.keys.contains(where: { normal($0) != $0 })
                || incompatiblePeers.keys.contains(where: { normal($0) != $0 })
                || groupRooms.contains(where: { normal($0.key) != $0.key || $0.value.contains { normal($0) != $0 } }) else { return }
        var seen = Set(devices.filter { normal($0.jid) == $0.jid }.map(\.id))
        devices = devices.compactMap { device in
            guard normal(device.jid) != device.jid else { return device }
            let moved = EncryptionDevice(jid: normal(device.jid), profile: device.profile, deviceID: device.deviceID, identityKey: device.identityKey,
                                         trust: device.trust, active: device.active, identityChanged: device.identityChanged)
            guard seen.insert(moved.id).inserted else { return nil }
            if bundles[moved.id] == nil { bundles[moved.id] = bundles[device.id] }
            bundles[device.id] = nil
            return moved
        }
        func rekeyed<Value>(_ map: [String: Value]) -> [String: Value] {
            map.filter { normal($0.key) == $0.key }.merging(map.map { (normal($0.key), $0.value) }) { kept, _ in kept }
        }
        profiles = rekeyed(profiles)
        incompatiblePeers = rekeyed(incompatiblePeers)
        groupRooms = rekeyed(groupRooms).mapValues { members in members.map(normal).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    }
}

extension XMPPOMEMOProfile {
    var crypto: CryptoProfile { self == .legacy ? .legacy : .modern }
}

/// Serializes one logical operation across awaits. SQLite revision checks additionally fence
/// another coordinator/process; no network operation is performed inside a SQL transaction.
actor OperationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        if held { await withCheckedContinuation { waiters.append($0) } }
        held = true
        defer {
            if waiters.isEmpty { held = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await work()
    }
}

public struct EncryptionPreparation: Sendable {
    /// Sealed and claimable now: messages, or every update kind (plain wire or envelope).
    public let messageIDs: Set<String>
    public let blockedChats: [String: String]
    let failure: OMEMOError?
    /// Files queued as a reply that were sealed without it, because their chat fell back to legacy OMEMO first.
    /// Their stored quote is gone too; the caller tells the user, whose composer no longer holds the reply.
    public var droppedReplies: Set<String> = []
}

/// What the transport must write for one claimed update, re-validated against current trust.
public enum PreparedUpdate: Sendable, Equatable {
    case encrypted(to: String, envelope: XMPPOMEMOEnvelope)
    case group(room: String, envelope: XMPPOMEMOEnvelope, members: [String])
    /// The exact plain stanza is the sealed wire; the serializer is deterministic for these inputs.
    case plainReaction(to: String, targetID: String, reactions: [String])
    case plainRetraction(to: String, targetID: String)
    case plainReceipt(to: String, targetID: String, kind: MessageContent.Receipt.Kind)
}
