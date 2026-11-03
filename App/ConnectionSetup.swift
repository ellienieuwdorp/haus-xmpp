import Foundation
import OMEMO
import XMPPProtocol

struct CatchUpProgress: Equatable, Sendable {
    var archive: String?
    var pages: Int
    var messages: Int
}

// Upload discovery runs alongside and is joined last, so a slow upload component never delays `.ready` or the walk.
// `.ready` follows `initialize`, so an identity mismatch fails closed first. Every child is structured: joining the
// task running `run` joins every crypto operation it started.
struct ConnectionSetup: Sendable {
    struct Operations: Sendable {
        var features: @Sendable () async throws -> Set<String>
        var enableCarbons: @Sendable () async throws -> Void
        var discoverUploads: @Sendable () async -> Void
        var initializeEncryption: @Sendable () async throws -> Void
        var rejoinGroups: @Sendable () async throws -> Void
        var catchUp: @Sendable (_ progress: @escaping @Sendable (CatchUpProgress) async -> Void) async throws -> Void
        var retryPending: @Sendable () async -> Void
    }

    enum Event: Equatable, Sendable {
        case step(String)
        case ready
        case catchingUp(CatchUpProgress?)
        case degraded(step: String, detail: String)
        case failed(step: String, detail: String)
        case settled
    }

    struct Memory: Equatable, Sendable {
        var features: Set<String>?
        var featuresFresh = false
        // XEP-0280 state belongs to the server session, so it survives a resume; a stream another process bound has a
        // different ID.
        var carbonsOnStream = false
        var uploadsFresh = false
    }

    static let carbonsFeature = "urn:xmpp:carbons:2"
    static let archiveFeature = "urn:xmpp:mam:2"
    static let featuresStep = "server features"
    static let carbonsStep = "carbons"
    static let keysStep = "publishing this phone’s keys"
    static let rejoinStep = "rejoining groups"
    static let archiveStep = "archive catch-up"

    // A refused archive query ends only that archive, and carbons stay off rather than fail.
    static let assumedFeatures: Set<String> = [archiveFeature]

    // Prosody advertises XEP-0280 only on the domain and XEP-0313 on the bare JID, so both are asked. Only the account
    // query decides; a refused domain query degrades to no carbons, and such a partial answer is not remembered.
    static func discoverFeatures(server: @escaping @Sendable () async throws -> Set<String>,
                                 account: @escaping @Sendable () async throws -> Set<String>) async throws -> (features: Set<String>, complete: Bool) {
        async let domain: Set<String>? = { try? await server() }()
        async let own = account()
        let found = try await own
        guard let shared = await domain else { return (found, false) }
        return (found.union(shared), true)
    }

    let identityExists: Bool
    var resumed = false
    var memory = Memory()

    // Identity publication, rejoins and the walk always run: the identity check is the fail-closed guard against
    // another device using our device ID, and the walk catches what a resumed extension run acked without storing.
    var skipsFeatures: Bool { resumed && memory.featuresFresh && memory.features != nil }
    var skipsCarbons: Bool { resumed && memory.carbonsOnStream }
    var skipsUploads: Bool { resumed && memory.uploadsFresh }

    private struct StepFailure: Error {
        let step: String
        let error: any Error
    }

    // Emits at most one `.failed` and nothing after it. The cancellation check runs on the main actor right before the
    // owner applies an event, so a teardown that cancels setup there always wins over an event in flight.
    func run(operations: Operations, sink deliver: @escaping @MainActor @Sendable (Event) async -> Void) async {
        let sink: @MainActor @Sendable (Event) async -> Void = { event in
            guard !Task.isCancelled else { return }
            await deliver(event)
        }
        // Off the critical path and joined last. Leaving early cancels and joins it with the rest of this scope.
        let discoversUploads = !skipsUploads
        async let uploads: Void = { if discoversUploads { await operations.discoverUploads() } }()

        var step = Self.featuresStep
        await sink(.step(step))
        let features: Set<String>
        if skipsFeatures, let known = memory.features {
            features = known
        } else {
            do { features = try await operations.features() } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await sink(.degraded(step: step, detail: Self.detail(error)))
                features = memory.features ?? Self.assumedFeatures
            }
        }
        if features.contains(Self.carbonsFeature), !skipsCarbons {
            do {
                try Task.checkCancellation()
                step = Self.carbonsStep
                await sink(.step(step))
                try await operations.enableCarbons()
            } catch {
                await publishFailure(StepFailure(step: step, error: error), sink: sink)
                return
            }
        }

        let walks = features.contains(Self.archiveFeature)
        let identityExists = identityExists
        let held: StepFailure?
        do {
            held = try await withThrowingTaskGroup(of: StepFailure?.self, returning: StepFailure?.self) { group in
                group.addTask {
                    var step = Self.keysStep
                    do {
                        if identityExists {
                            try Task.checkCancellation()
                            await sink(.step(step))
                            try await operations.initializeEncryption()
                        }
                        try Task.checkCancellation()
                        await sink(.ready)
                        step = Self.rejoinStep
                        try await operations.rejoinGroups()
                        return nil
                    } catch {
                        // Encryption state that does not match the server fails closed at once, walk included.
                        // Anything else (a timeout, a refused publish, a store read for the rooms) waits for the walk.
                        if error is OMEMOError { throw StepFailure(step: step, error: error) }
                        return StepFailure(step: step, error: error)
                    }
                }
                if walks {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            await sink(.catchingUp(CatchUpProgress(archive: nil, pages: 0, messages: 0)))
                            try await operations.catchUp { await sink(.catchingUp($0)) }
                            return nil
                        } catch {
                            throw StepFailure(step: Self.archiveStep, error: error)
                        }
                    }
                }
                var first: StepFailure?
                do {
                    for try await failure in group where first == nil { first = failure }
                } catch {
                    // The group scope joins the cancelled children before this rethrow leaves it.
                    group.cancelAll()
                    throw error
                }
                return first
            }
        } catch let failure as StepFailure {
            await publishFailure(failure, sink: sink)
            return
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        if walks { await sink(.catchingUp(nil)) }
        if let held {
            await publishFailure(held, sink: sink)
            return
        }
        // After the walk, so archived timestamps have already corrected retained rows.
        await operations.retryPending()
        guard !Task.isCancelled else { return }
        await sink(.settled)
        await uploads
    }

    private func publishFailure(_ failure: StepFailure, sink: @MainActor @Sendable (Event) async -> Void) async {
        // The connection is being torn down; its owner drops stale state through its own fences.
        guard !Task.isCancelled, !(failure.error is CancellationError) else { return }
        await sink(.failed(step: failure.step, detail: Self.detail(failure.error)))
    }

    static func detail(_ error: any Error) -> String {
        if case .stanza(let condition)? = error as? XMPPIQError { return condition }
        return (error as? OMEMOError)?.errorDescription ?? String(String(describing: error).prefix(120))
    }
}

// Unchecked: `UserDefaults` is thread-safe, and setup operations write it off the main actor.
struct ServerProfileMemory: @unchecked Sendable {
    let defaults: UserDefaults
    static let featuresLifetime: TimeInterval = 24 * 60 * 60

    private static func featuresKey(_ account: String) -> String { "serverFeatures.\(account)" }
    private static func carbonsKey(_ account: String) -> String { "carbonsStream.\(account)" }

    func memory(account: String, stream: String?, uploadsFresh: Bool, now: Date = .now) -> ConnectionSetup.Memory {
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

    func discovered(_ features: Set<String>, account: String, now: Date = .now) {
        guard !account.isEmpty else { return }
        defaults.set(["features": features.sorted(), "at": now], forKey: Self.featuresKey(account))
    }

    func carbonsEnabled(account: String, stream: String?) {
        guard !account.isEmpty else { return }
        if let stream, !stream.isEmpty { defaults.set(stream, forKey: Self.carbonsKey(account)) }
        else { defaults.removeObject(forKey: Self.carbonsKey(account)) }
    }

    func forget(account: String) {
        defaults.removeObject(forKey: Self.featuresKey(account))
        defaults.removeObject(forKey: Self.carbonsKey(account))
    }
}
