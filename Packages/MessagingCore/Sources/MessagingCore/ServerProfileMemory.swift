import Foundation
import XMPPProtocol

/// What setup learned about the account's server, per account: its features for a day, the stream that has carbons
/// enabled, and the stream profile the next connection sends ahead with.
// Unchecked: `UserDefaults` is thread-safe, and setup operations write it off the main actor.
public struct ServerProfileMemory: XMPPStreamProfileStore, @unchecked Sendable {
    public let defaults: UserDefaults
    public static let featuresLifetime: TimeInterval = 24 * 60 * 60

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private static func featuresKey(_ account: String) -> String { "serverFeatures.\(account)" }
    private static func carbonsKey(_ account: String) -> String { "carbonsStream.\(account)" }
    private static func streamProfileKey(_ account: String) -> String { "streamProfile.\(account)" }

    public func streamProfile(account: String) -> XMPPStreamProfile? {
        guard !account.isEmpty, let data = defaults.data(forKey: Self.streamProfileKey(account)) else { return nil }
        return try? JSONDecoder().decode(XMPPStreamProfile.self, from: data)
    }

    public func saveStreamProfile(_ profile: XMPPStreamProfile?, account: String) {
        guard !account.isEmpty else { return }
        if let profile, let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: Self.streamProfileKey(account)) }
        else { defaults.removeObject(forKey: Self.streamProfileKey(account)) }
    }

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
        defaults.removeObject(forKey: Self.streamProfileKey(account))
    }
}
