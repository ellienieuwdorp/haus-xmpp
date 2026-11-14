import Foundation
import XMPPProtocol

/// The stream profile each account's next connection sends ahead with. Kept in the App Group's defaults, so the app,
/// both extensions and notification actions get the same quickstart, and an endpoint's refusal of early data, written
/// by whichever process met it, holds for all of them.
// Unchecked: `UserDefaults` is thread-safe, and processes share an App Group suite through it.
public struct StreamProfileMemory: XMPPStreamProfileStore, @unchecked Sendable {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private static func key(_ account: String) -> String { "streamProfile.\(account)" }

    public func streamProfile(account: String) -> XMPPStreamProfile? {
        guard !account.isEmpty, let data = defaults.data(forKey: Self.key(account)) else { return nil }
        return try? JSONDecoder().decode(XMPPStreamProfile.self, from: data)
    }

    public func saveStreamProfile(_ profile: XMPPStreamProfile?, account: String) {
        guard !account.isEmpty else { return }
        if let profile, let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: Self.key(account)) }
        else { defaults.removeObject(forKey: Self.key(account)) }
    }

    public func forget(account: String) { defaults.removeObject(forKey: Self.key(account)) }
}

/// What setup learned about the account's server, per account: its features for a day and the stream that has carbons
/// enabled, in the app's defaults, and the shared stream profile in `streams`.
// Unchecked: `UserDefaults` is thread-safe, and setup operations write it off the main actor.
public struct ServerProfileMemory: XMPPStreamProfileStore, @unchecked Sendable {
    public let defaults: UserDefaults
    public let streams: StreamProfileMemory
    public static let featuresLifetime: TimeInterval = 24 * 60 * 60

    /// `streamProfiles` is the App Group's defaults; without it the stream profile stays in `defaults`.
    public init(defaults: UserDefaults, streamProfiles: UserDefaults? = nil) {
        self.defaults = defaults
        streams = StreamProfileMemory(defaults: streamProfiles ?? defaults)
    }

    private static func featuresKey(_ account: String) -> String { "serverFeatures.\(account)" }
    private static func carbonsKey(_ account: String) -> String { "carbonsStream.\(account)" }

    public func streamProfile(account: String) -> XMPPStreamProfile? { streams.streamProfile(account: account) }

    public func saveStreamProfile(_ profile: XMPPStreamProfile?, account: String) { streams.saveStreamProfile(profile, account: account) }

    public func memory(account: String, stream: String?, uploadsFresh: Bool, now: Date = .now) -> ConnectionSetup.Memory {
        guard !account.isEmpty else { return ConnectionSetup.Memory() }
        var memory = ConnectionSetup.Memory(uploadsFresh: uploadsFresh)
        if let saved = defaults.dictionary(forKey: Self.featuresKey(account)), let features = saved["features"] as? [String],
           let at = saved["at"] as? Date {
            memory.features = Set(features)
            memory.featuresFresh = at <= now && now.timeIntervalSince(at) < Self.featuresLifetime
        }
        if let stream, !stream.isEmpty { memory.carbonsOnStream = defaults.string(forKey: Self.carbonsKey(account)) == stream }
        return memory
    }

    public func discovered(_ features: Set<String>, account: String, now: Date = .now) {
        guard !account.isEmpty else { return }
        defaults.set(["features": features.sorted(), "at": now], forKey: Self.featuresKey(account))
    }

    public func carbonsEnabled(account: String, stream: String?) {
        guard !account.isEmpty else { return }
        if let stream, !stream.isEmpty { defaults.set(stream, forKey: Self.carbonsKey(account)) }
        else { defaults.removeObject(forKey: Self.carbonsKey(account)) }
    }

    public func forget(account: String) {
        defaults.removeObject(forKey: Self.featuresKey(account))
        defaults.removeObject(forKey: Self.carbonsKey(account))
        streams.forget(account: account)
    }
}
