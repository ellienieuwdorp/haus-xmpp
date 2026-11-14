import Foundation
import OMEMO
import XMPPProtocol

public struct CatchUpProgress: Equatable, Sendable {
    public var archive: String?
    public var pages: Int
    public var messages: Int

    public init(archive: String?, pages: Int, messages: Int) {
        self.archive = archive; self.pages = pages; self.messages = messages
    }
}

/// The steps between a bound stream and a settled one. Upload discovery runs alongside and is joined last, so a slow
/// upload component never delays `.ready` or the walk. `.ready` follows `initialize`, so an identity mismatch fails
/// closed first. Every child is structured: joining the task running `run` joins every crypto operation it started.
public struct ConnectionSetup: Sendable {
    public struct Operations: Sendable {
        public var features: @Sendable () async throws -> Set<String>
        public var enableCarbons: @Sendable () async throws -> Void
        public var discoverUploads: @Sendable () async -> Void
        public var initializeEncryption: @Sendable () async throws -> Void
        public var rejoinGroups: @Sendable () async throws -> Void
        public var catchUp: @Sendable (_ progress: @escaping @Sendable (CatchUpProgress) async -> Void) async throws -> Void
        public var retryPending: @Sendable () async -> Void

        public init(features: @escaping @Sendable () async throws -> Set<String>,
                    enableCarbons: @escaping @Sendable () async throws -> Void,
                    discoverUploads: @escaping @Sendable () async -> Void,
                    initializeEncryption: @escaping @Sendable () async throws -> Void,
                    rejoinGroups: @escaping @Sendable () async throws -> Void,
                    catchUp: @escaping @Sendable (_ progress: @escaping @Sendable (CatchUpProgress) async -> Void) async throws -> Void,
                    retryPending: @escaping @Sendable () async -> Void) {
            self.features = features; self.enableCarbons = enableCarbons; self.discoverUploads = discoverUploads
            self.initializeEncryption = initializeEncryption; self.rejoinGroups = rejoinGroups; self.catchUp = catchUp
            self.retryPending = retryPending
        }
    }

    public enum Event: Equatable, Sendable {
        case step(String)
        case ready
        case catchingUp(CatchUpProgress?)
        case degraded(step: String, detail: String)
        case failed(step: String, detail: String)
        case settled
    }

    public struct Memory: Equatable, Sendable {
        public var features: Set<String>?
        public var featuresFresh = false
        // XEP-0280 state belongs to the server session, so it survives a resume; a stream another process bound has a
        // different ID.
        public var carbonsOnStream = false
        public var uploadsFresh = false

        public init(features: Set<String>? = nil, featuresFresh: Bool = false, carbonsOnStream: Bool = false, uploadsFresh: Bool = false) {
            self.features = features; self.featuresFresh = featuresFresh; self.carbonsOnStream = carbonsOnStream
            self.uploadsFresh = uploadsFresh
        }
    }

    public typealias Sink = @MainActor @Sendable (Event) async -> Void

    public static let carbonsFeature = "urn:xmpp:carbons:2"
    public static let archiveFeature = "urn:xmpp:mam:2"
    public static let featuresStep = "server features"
    public static let carbonsStep = "carbons"
    public static let keysStep = "publishing this phone’s keys"
    public static let rejoinStep = "rejoining groups"
    public static let archiveStep = "archive catch-up"

    // A refused archive query ends only that archive, and carbons stay off rather than fail.
    static let assumedFeatures: Set<String> = [archiveFeature]

    /// Prosody advertises XEP-0280 only on the domain and XEP-0313 on the bare JID, so both are asked. Only the
    /// account query decides; a refused domain query degrades to no carbons, and such a partial answer is not
    /// remembered.
    public static func discoverFeatures(server: @escaping @Sendable () async throws -> Set<String>,
                                        account: @escaping @Sendable () async throws -> Set<String>) async throws -> (features: Set<String>, complete: Bool) {
        async let domain: Set<String>? = {
            do { return try await server() } catch { return nil }
        }()
        async let own = account()
        let found = try await own
        guard let shared = await domain else { return (found, false) }
        return (found.union(shared), true)
    }

    let identityExists: Bool
    public var resumed = false
    public var memory = Memory()

    public init(identityExists: Bool, resumed: Bool = false, memory: Memory = Memory()) {
        self.identityExists = identityExists; self.resumed = resumed; self.memory = memory
    }

    // Identity publication, rejoins and the walk always run: the identity check is the fail-closed guard against
    // another device using our device ID, and the walk catches what a resumed extension run acked without storing.
    public var skipsFeatures: Bool { resumed && memory.featuresFresh && memory.features != nil }
    public var skipsCarbons: Bool { resumed && memory.carbonsOnStream }
    public var skipsUploads: Bool { resumed && memory.uploadsFresh }

    private struct StepFailure: Error {
        let step: String
        let error: any Error
    }

    /// Emits at most one `.failed` and nothing after it. The cancellation check runs on the main actor right before
    /// the owner applies an event, so a teardown that cancels setup there always wins over an event in flight.
    public func run(operations: Operations, sink deliver: @escaping Sink) async {
        let sink: Sink = { event in
            guard !Task.isCancelled else { return }
            await deliver(event)
        }
        // Off the critical path and joined last. Leaving early cancels and joins it with the rest of this scope.
        let discoversUploads = !skipsUploads
        async let uploads: Void = { if discoversUploads { await operations.discoverUploads() } }()

        guard let features = await negotiate(operations, sink: sink) else { return }
        let walks = features.contains(Self.archiveFeature)
        let held: StepFailure?
        do {
            held = try await Self.concurrently(operations, identityExists: identityExists, walks: walks, sink: sink)
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

    // Features, then carbons when offered. nil ends setup: cancelled, or carbons failed (already published).
    private func negotiate(_ operations: Operations, sink: @escaping Sink) async -> Set<String>? {
        var step = Self.featuresStep
        await sink(.step(step))
        let features: Set<String>
        if skipsFeatures, let known = memory.features {
            features = known
        } else {
            do { features = try await operations.features() } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return nil }
                await sink(.degraded(step: step, detail: Self.detail(error)))
                features = memory.features ?? Self.assumedFeatures
            }
        }
        guard features.contains(Self.carbonsFeature), !skipsCarbons else { return features }
        do {
            try Task.checkCancellation()
            step = Self.carbonsStep
            await sink(.step(step))
            try await operations.enableCarbons()
        } catch {
            await publishFailure(StepFailure(step: step, error: error), sink: sink)
            return nil
        }
        return features
    }

    // A thrown failure ends setup at once; a returned one waits for the walk.
    private static func concurrently(_ operations: Operations, identityExists: Bool, walks: Bool,
                                     sink: @escaping Sink) async throws -> StepFailure? {
        try await withThrowingTaskGroup(of: StepFailure?.self, returning: StepFailure?.self) { group in
            group.addTask { try await identityThenRooms(operations, identityExists: identityExists, sink: sink) }
            if walks { group.addTask { try await walk(operations, sink: sink) } }
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
    }

    private static func identityThenRooms(_ operations: Operations, identityExists: Bool, sink: @escaping Sink) async throws -> StepFailure? {
        var step = keysStep
        do {
            if identityExists {
                try Task.checkCancellation()
                await sink(.step(step))
                try await operations.initializeEncryption()
            }
            try Task.checkCancellation()
            await sink(.ready)
            step = rejoinStep
            try await operations.rejoinGroups()
            return nil
        } catch {
            // Encryption state that does not match the server fails closed at once, walk included. Anything else (a
            // timeout, a refused publish, a store read for the rooms) waits for the walk.
            if error is OMEMOError { throw StepFailure(step: step, error: error) }
            return StepFailure(step: step, error: error)
        }
    }

    private static func walk(_ operations: Operations, sink: @escaping Sink) async throws -> StepFailure? {
        do {
            try Task.checkCancellation()
            await sink(.catchingUp(CatchUpProgress(archive: nil, pages: 0, messages: 0)))
            try await operations.catchUp { await sink(.catchingUp($0)) }
            return nil
        } catch {
            throw StepFailure(step: archiveStep, error: error)
        }
    }

    private func publishFailure(_ failure: StepFailure, sink: Sink) async {
        // The connection is being torn down; its owner drops stale state through its own fences.
        guard !Task.isCancelled, !(failure.error is CancellationError) else { return }
        await sink(.failed(step: failure.step, detail: Self.detail(failure.error)))
    }

    public static func detail(_ error: any Error) -> String {
        if case .stanza(let condition)? = error as? XMPPIQError { return condition }
        return (error as? OMEMOError)?.errorDescription ?? String(String(describing: error).prefix(120))
    }
}
