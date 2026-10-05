import Foundation
import OMEMO
import XMPPProtocol

struct CatchUpProgress: Equatable, Sendable {
    /// nil for the direct archive, the room JID otherwise.
    var archive: String?
    var pages: Int
    var messages: Int
}

/// One connection's setup after `.online`: discovery, identity publication and the archive walk.
/// Sequencing only; AppModel supplies the operations and applies the events to its state.
///
/// Order: features, then carbons; then, concurrently, the archive walk and identity publication followed by the room
/// rejoins. Upload discovery runs alongside all of it and is joined last, so a slow or silent upload component never
/// delays `.ready` or the walk. `.ready` is published only after `initialize` returned, so an identity mismatch still
/// fails closed before anything can be sent.
///
/// Steps are independent: a failed account disco does not fail the setup, and a keys or rejoin failure never
/// cancels the walk; it is published once the walk has ended. Only an encryption-state failure (`OMEMOError`) or a
/// walk failure ends the setup at once. Every child is structured: cancelling `run` cancels and joins all of them,
/// so a caller that joins the task running `run` has joined every crypto operation it started.
struct ConnectionSetup: Sendable {
    struct Operations: Sendable {
        var features: @Sendable () async throws -> Set<String>
        var enableCarbons: @Sendable () async throws -> Void
        /// Never throws: AppModel settles a thrown discovery itself (`uploads.settle`).
        var discoverUploads: @Sendable () async -> Void
        var initializeEncryption: @Sendable () async throws -> Void
        var rejoinGroups: @Sendable () async throws -> Void
        var catchUp: @Sendable (_ progress: @escaping @Sendable (CatchUpProgress) async -> Void) async throws -> Void
        var retryPending: @Sendable () async -> Void
    }

    enum Event: Equatable, Sendable {
        /// `session = .connected(settingUp: step)`.
        case step(String)
        case ready
        /// `nil` when the walk finished.
        case catchingUp(CatchUpProgress?)
        /// An optional step failed and setup went on without its answer. Logged only.
        case degraded(step: String, detail: String)
        case failed(step: String, detail: String)
        /// Every step finished and none failed. With a minute of uptime, what makes a session count as healthy
        /// (`ReconnectPolicy`): `.ready` comes before the walk and the rejoins.
        case settled
    }

    static let carbonsFeature = "urn:xmpp:carbons:2"
    static let archiveFeature = "urn:xmpp:mam:2"
    static let featuresStep = "server features"
    static let carbonsStep = "carbons"
    static let keysStep = "publishing this phone’s keys"
    static let rejoinStep = "rejoining groups"
    static let archiveStep = "archive catch-up"

    /// What setup assumes when the account's features could not be read: try the walk, whose
    /// refused query ends only that archive (`ArchiveSynchronizer`), and leave carbons off rather than fail on them.
    static let assumedFeatures: Set<String> = [archiveFeature]

    /// The feature set setup decides on: the server domain's disco#info union the account's. Servers advertise
    /// XEP-0280 on the domain (Prosody lists `urn:xmpp:carbons:2` only there) and XEP-0313 for the user's own
    /// archive on the account's bare JID, so neither query alone sees both. Both run concurrently.
    /// The account query decides the step (it advertises the archive); the server-domain query only adds
    /// optional features such as carbons, so a server that refuses it degrades to "no carbons" instead of
    /// failing the connection.
    static func discoverFeatures(server: @escaping @Sendable () async throws -> Set<String>,
                                 account: @escaping @Sendable () async throws -> Set<String>) async throws -> Set<String> {
        async let domain: Set<String> = { (try? await server()) ?? [] }()
        async let own = account()
        return try await own.union(domain)
    }

    /// False when the `.online` handler already ran `initialize` inline (first connection of a new account).
    let identityExists: Bool

    private struct StepFailure: Error {
        let step: String
        let error: any Error
    }

    /// Returns after every child has finished, including after cancellation or a failure.
    /// Emits at most one `.failed` and never `.ready` or `.settled` after it. A walk that started ends with exactly one
    /// of `.catchingUp(nil)` or `.failed` (a keys or rejoin failure follows a finished walk's `.catchingUp(nil)`), unless
    /// `run` was cancelled: cancellation publishes nothing further.
    ///
    /// Nothing is delivered once the calling task is cancelled. The check runs on the main actor right before
    /// the owner applies the event, so a teardown that cancels the setup on the main actor (a `.disconnected`
    /// that arrived between an operation's return and its event) always wins over an event already in flight.
    func run(operations: Operations, sink deliver: @escaping @MainActor @Sendable (Event) async -> Void) async {
        let sink: @MainActor @Sendable (Event) async -> Void = { event in
            guard !Task.isCancelled else { return }
            await deliver(event)
        }
        // Off the critical path and joined last. Leaving early cancels and joins it with the rest of this scope.
        async let uploads: Void = operations.discoverUploads()

        var step = Self.featuresStep
        await sink(.step(step))
        let features: Set<String>
        do { features = try await operations.features() } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            await sink(.degraded(step: step, detail: Self.detail(error)))
            features = Self.assumedFeatures
        }
        if features.contains(Self.carbonsFeature) {
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
