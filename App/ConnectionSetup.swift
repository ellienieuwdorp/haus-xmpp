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
/// Steps are independent: a failed account disco falls back to known features, and a keys or rejoin failure never
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

    /// What earlier connections left behind for this account (`ServerProfileMemory`, `UploadServiceMemory`). A fresh
    /// bind uses only `features`, as the fallback for a failed discovery; a resumed stream may skip work with it.
    struct Memory: Equatable, Sendable {
        /// The features of the account's last completed discovery; nil when there was none.
        var features: Set<String>?
        /// `features` is recent enough for a resumed stream to use instead of asking again.
        var featuresFresh = false
        /// Carbons were enabled on the very stream that was resumed (same stream ID). XEP-0280 state belongs to the
        /// server session, so it survives a resume; a session another process bound (the extension never enables
        /// carbons) has a different ID.
        var carbonsOnStream = false
        /// An upload discovery completed recently; the stored service (or its absence) stands.
        var uploadsFresh = false
    }

    static let carbonsFeature = "urn:xmpp:carbons:2"
    static let archiveFeature = "urn:xmpp:mam:2"
    static let featuresStep = "server features"
    static let carbonsStep = "carbons"
    static let keysStep = "publishing this phone’s keys"
    static let rejoinStep = "rejoining groups"
    static let archiveStep = "archive catch-up"

    /// What setup assumes when the account's features could not be read and none are known: try the walk, whose
    /// refused query ends only that archive (`ArchiveSynchronizer`), and leave carbons off rather than fail on them.
    static let assumedFeatures: Set<String> = [archiveFeature]

    /// The feature set setup decides on: the server domain's disco#info union the account's. Servers advertise
    /// XEP-0280 on the domain (Prosody lists `urn:xmpp:carbons:2` only there) and XEP-0313 for the user's own
    /// archive on the account's bare JID, so neither query alone sees both. Both run concurrently.
    /// The account query decides the step (it advertises the archive); the server-domain query only adds
    /// optional features such as carbons, so a server that refuses it degrades to "no carbons" instead of
    /// failing the connection. `complete` is false then, and such a partial answer is not worth remembering.
    static func discoverFeatures(server: @escaping @Sendable () async throws -> Set<String>,
                                 account: @escaping @Sendable () async throws -> Set<String>) async throws -> (features: Set<String>, complete: Bool) {
        async let domain: Set<String>? = { try? await server() }()
        async let own = account()
        let found = try await own
        guard let shared = await domain else { return (found, false) }
        return (found.union(shared), true)
    }

    /// False when the `.online` handler already ran `initialize` inline (first connection of a new account).
    let identityExists: Bool
    /// The stream was resumed (XEP-0198), not freshly bound.
    var resumed = false
    var memory = Memory()

    /// Which steps a resumed stream may skip, and why each is safe:
    /// - features: they change only when the operator reconfigures the server, so an answer under a day old is reused.
    ///   A wrong guess costs at most one connection's carbons, and a refused walk ends only its own archive.
    /// - carbons: enabled on this very stream, and XEP-0280 state belongs to the stream.
    /// - uploads: a discovery under a day old stands; the attach button already follows the stored service.
    /// A fresh bind skips nothing.
    /// Identity publication, the rejoins and the walk always run: the identity check is the fail-closed guard against
    /// another device publishing under our device ID, and the walk catches what a resumed extension run acknowledged
    /// without storing (live room messages) and what the server dropped from the hibernated queue.
    var skipsFeatures: Bool { resumed && memory.featuresFresh && memory.features != nil }
    var skipsCarbons: Bool { resumed && memory.carbonsOnStream }
    var skipsUploads: Bool { resumed && memory.uploadsFresh }

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

/// The account's server features and the stream carbons were last enabled on, in the account-keyed preferences, so a
/// resumed stream can skip asking again (`ConnectionSetup.Memory`). Only completed answers are kept.
/// Unchecked: `UserDefaults` is documented as thread-safe, and setup operations write it off the main actor.
struct ServerProfileMemory: @unchecked Sendable {
    let defaults: UserDefaults
    /// How long a feature discovery stands for a resumed stream. A fresh bind always asks again.
    static let featuresLifetime: TimeInterval = 24 * 60 * 60

    private static func featuresKey(_ account: String) -> String { "serverFeatures.\(account)" }
    private static func carbonsKey(_ account: String) -> String { "carbonsStream.\(account)" }

    /// `stream` is the resumed stream's ID; nil after a fresh bind.
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

    /// Carbons were enabled on `stream`; nil (a stream that cannot be resumed) forgets any earlier one.
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
