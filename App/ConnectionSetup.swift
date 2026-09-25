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
/// Order: features (upload discovery alongside), then carbons; then, concurrently, the archive walk and
/// identity publication. `.ready` is published only after `initialize` returned, so an identity mismatch
/// still fails closed before anything can be sent. Every child is structured: cancelling `run` cancels
/// and joins all of them, so a caller that joins the task running `run` has joined every crypto
/// operation it started.
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
        case failed(step: String, detail: String)
    }

    static let carbonsFeature = "urn:xmpp:carbons:2"
    static let archiveFeature = "urn:xmpp:mam:2"
    static let featuresStep = "server features"
    static let carbonsStep = "carbons"
    static let keysStep = "publishing this phone’s keys"
    static let rejoinStep = "rejoining groups"
    static let archiveStep = "archive catch-up"

    /// The feature set setup decides on: the server domain's disco#info union the account's. Servers advertise
    /// XEP-0280 on the domain (Prosody lists `urn:xmpp:carbons:2` only there) and XEP-0313 for the user's own
    /// archive on the account's bare JID, so neither query alone sees both. Both run concurrently; either
    /// failing fails the features step.
    static func discoverFeatures(server: @escaping @Sendable () async throws -> Set<String>,
                                 account: @escaping @Sendable () async throws -> Set<String>) async throws -> Set<String> {
        async let domain = server()
        async let own = account()
        return try await domain.union(own)
    }

    /// False when the `.online` handler already ran `initialize` inline (first connection of a new account).
    let identityExists: Bool

    private struct StepFailure: Error {
        let step: String
        let error: any Error
    }

    /// Returns after every child has finished, including after cancellation or a failure.
    /// Emits at most one `.failed` and never `.ready` after it. A walk that started ends with exactly one of
    /// `.catchingUp(nil)` or `.failed`, unless `run` was cancelled: cancellation publishes nothing further.
    ///
    /// Nothing is delivered once the calling task is cancelled. The check runs on the main actor right before
    /// the owner applies the event, so a teardown that cancels the setup on the main actor (a `.disconnected`
    /// that arrived between an operation's return and its event) always wins over an event already in flight.
    func run(operations: Operations, sink deliver: @escaping @MainActor @Sendable (Event) async -> Void) async {
        let sink: @MainActor @Sendable (Event) async -> Void = { event in
            guard !Task.isCancelled else { return }
            await deliver(event)
        }
        var step = Self.featuresStep
        await sink(.step(step))
        let features: Set<String>
        do {
            async let uploads: Void = operations.discoverUploads()
            do {
                features = try await operations.features()
                if features.contains(Self.carbonsFeature) {
                    try Task.checkCancellation()
                    step = Self.carbonsStep
                    await sink(.step(step))
                    try await operations.enableCarbons()
                }
            } catch {
                await uploads
                throw error
            }
            // Joined before the next phase, so whoever joins this setup has joined the discovery too.
            await uploads
        } catch {
            await publishFailure(StepFailure(step: step, error: error), sink: sink)
            return
        }

        let walks = features.contains(Self.archiveFeature)
        let identityExists = identityExists
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
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
                    } catch {
                        throw StepFailure(step: step, error: error)
                    }
                }
                if walks {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            await sink(.catchingUp(CatchUpProgress(archive: nil, pages: 0, messages: 0)))
                            try await operations.catchUp { await sink(.catchingUp($0)) }
                        } catch {
                            throw StepFailure(step: Self.archiveStep, error: error)
                        }
                    }
                }
                do {
                    for try await _ in group {}
                } catch {
                    // The group scope joins the cancelled children before this rethrow leaves it.
                    group.cancelAll()
                    throw error
                }
            }
        } catch let failure as StepFailure {
            await publishFailure(failure, sink: sink)
            return
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        if walks { await sink(.catchingUp(nil)) }
        // After the walk, so archived timestamps have already corrected retained rows.
        await operations.retryPending()
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
