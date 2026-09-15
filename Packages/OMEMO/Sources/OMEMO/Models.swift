import Foundation
import XMPPProtocol
import OMEMOCrypto

public enum DeviceTrust: String, Codable, Sendable {
    case undecided, accepted, verified, rejected
    public var permitsEncryption: Bool { self == .accepted || self == .verified }
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
    public var fingerprint: String {
        guard let bytes = try? OMEMOEngine.fingerprintBytes(for: identityKey, profile: profile.crypto) else { return "Invalid identity" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct EncryptionOverview: Sendable {
    public let profile: XMPPOMEMOProfile
    public let localDeviceID: UInt32
    public let localFingerprint: String
    public let devices: [EncryptionDevice]
    public let hasIncompatibleDevices: Bool
    /// Advertised device IDs per owner whose bundle could not be fetched; they cannot be reviewed or messaged.
    public var unavailableDevices: [String: Int] = [:]
    /// Device IDs each owner advertised in this version, before bundle checks.
    public var advertisedDevices: [String: Int] = [:]
    public var needsTrust: Bool { devices.contains { $0.active && $0.trust == .undecided } }
}

public enum OMEMOError: Error, Equatable, Sendable, LocalizedError {
    case unavailable, noDevices, trustRequired, identityChanged, notForThisDevice
    case invalidContent, stateUnavailable, unsupportedProfile, concurrentChange, recipientSetChanged, cannotRetireCurrentDevice, unsupportedEncryptedReactions
    public var errorDescription: String? {
        switch self {
        case .unsupportedEncryptedReactions: "Private reactions require OMEMO 2 and an authenticated message reference. Nothing was sent unencrypted."
        case .cannotRetireCurrentDevice: "This device cannot be removed while it is in use."
        case .unavailable: "Encryption is not ready. Connect to finish setting it up."
        case .noDevices: "No compatible encryption devices were found. Your message is waiting safely on this device."
        case .trustRequired: "Review the encryption devices before sending or opening messages."
        case .identityChanged: "A device’s encryption identity changed. Compare its new fingerprint before continuing."
        case .notForThisDevice: "This message was not encrypted for this device."
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
    public let messageIDs: Set<String>
    public let blockedChats: [String: String]
    let failure: OMEMOError?
    /// Updates for legacy peers, sealed as the exact plain XEP-0444 stanza instead of an envelope.
    public var plaintextIDs: Set<String> = []
}
