import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// Loaded from protected local account storage, never from an untrusted push payload.
public struct BackgroundAccount: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let host: String
    public let port: UInt16
    public let domain: String
    public let username: String
    public let password: String
    public let labCertificateAuthority: Data?
    public var accountID: String { username + "@" + domain }

    public init(host: String, port: UInt16 = 5223, domain: String, username: String,
                password: String, labCertificateAuthority: Data? = nil) {
        self.host = host; self.port = port; self.domain = domain
        self.username = username; self.password = password
        self.labCertificateAuthority = labCertificateAuthority
    }
    public var description: String { "BackgroundAccount(<redacted>)" }
    public var debugDescription: String { description }
}

public enum BackgroundSynchronizationError: Error, Sendable, Equatable {
    case identityUnavailable, deadlineExceeded, invalidTimeBudget, connectionEnded
}

/// An extension performs one bounded catch-up under the same kernel lease as the app.
/// Success means durable archive completion. It does not claim a particular notification
/// represents a new message; notification previews require a separate privacy-aware projection.
public struct BackgroundSynchronizer: Sendable {
    public init() {}

    /// `leaseWait` is spent inside `timeBudget`: the app or another run may briefly hold the lease (plan D2).
    public func synchronize(databaseURL: URL, wrappingKey: Data, account: BackgroundAccount,
                            timeBudget: Duration = .seconds(20), leaseWait: Duration = .seconds(6),
                            progress: NotificationRunProgress? = nil,
                            presentation: (@Sendable (MessageStore) async throws -> Void)? = nil) async throws {
        guard timeBudget > .zero, timeBudget <= .seconds(25), leaseWait >= .zero, leaseWait < timeBudget else {
            throw BackgroundSynchronizationError.invalidTimeBudget
        }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw BackgroundSynchronizationError.identityUnavailable
        }
        let store = try MessageStore(url: databaseURL)
        do {
            // Busy means wait a bounded time, then defer: never expire another process's lock or reset its attempts.
            progress?.enter(.leaseWait)
            let waited = try await acquireTransportOwnership(store, waitingUpTo: leaseWait)
            progress?.update { $0.leaseWaitMilliseconds = Int(waited / .milliseconds(1)) }
            progress?.enter(.syncing)
            guard try await store.encryptionState(accountID: account.accountID) != nil else {
                throw BackgroundSynchronizationError.identityUnavailable
            }
            let encryption = OMEMOService(store: store, protection: try StateProtection(key: wrappingKey))
            let client = XMPPClient(labCertificateAuthority: account.labCertificateAuthority)
            try await client.configureStreamManagement(persistence: StreamPersistence(
                store: store, accountID: account.accountID, encryption: encryption))
            try await store.recoverInterruptedSubmissions(accountID: account.accountID)
            try await runBackgroundWork(timeBudget: timeBudget - waited, operation: {
                try await client.connect(host: account.host, port: account.port, domain: account.domain,
                                         username: account.username, password: account.password)
                try Task.checkCancellation()
                // No identity initialization, trust acceptance, queued-message preparation or
                // outbox drain. Resumption may replay only previously authorized exact bytes.
                try await ArchiveSynchronizer(store: store).synchronize(
                    account: account.accountID, client: client, encryption: encryption)
            }, consume: {
                try await consumeBackgroundEvents(client.events, processor: InboundProcessor(encryption: encryption, client: client, account: account.accountID))
            }, stop: { await client.disconnectAndWait() })
            try Task.checkCancellation()
            // From here a new push starts the next run: this one's network work is over.
            progress?.enter(.presenting)
            try await finishBackgroundPresentation(store: store, presentation: presentation)
        } catch {
            // runBackgroundWork joins crypto, archive and reader work before reaching here.
            // close releases ownership only if this instance acquired it.
            try await store.close()
            throw error
        }
    }
}

/// Polls the non-blocking kernel lease until it is free or `limit` passes; cancellable. Returns the time spent waiting.
func acquireTransportOwnership(_ store: MessageStore, waitingUpTo limit: Duration,
                               interval: Duration = .milliseconds(250)) async throws -> Duration {
    let clock = ContinuousClock(), start = clock.now
    while true {
        do {
            try await store.acquireTransportOwnership()
            return clock.now - start
        } catch MessageStoreError.transportOwnedElsewhere {
            guard clock.now - start + interval <= limit else { throw MessageStoreError.transportOwnedElsewhere }
            try await Task.sleep(for: interval)
        }
    }
}

/// Keep the cross-process lease through authorization, posting and the candidate delete. The caller must still
/// revalidate its current protected credentials; this cannot make local state and the operating system's
/// presentation atomic, which is why posting replaces by stable identifier.
func finishBackgroundPresentation(store: MessageStore,
                                  presentation: (@Sendable (MessageStore) async throws -> Void)?) async throws {
    do {
        try Task.checkCancellation()
        try await presentation?(store)
        try await store.close()
    } catch {
        try await store.close()
        throw error
    }
}

/// The extension persists exactly what the app would: the processor decides, this loop only
/// ends on disconnect. No automatic trust changes, no outbox, no plaintext (the processor
/// ignores `.message`); a storage failure propagates so the sync stops before the next barrier.
func consumeBackgroundEvents(_ events: AsyncStream<XMPPEvent>, processor: InboundProcessor) async throws {
    for await event in events {
        try Task.checkCancellation()
        if case .state(.disconnected) = event { throw BackgroundSynchronizationError.connectionEnded }
        _ = try await processor.process(event)
    }
    try Task.checkCancellation()
    throw BackgroundSynchronizationError.connectionEnded
}

/// The seam tests lifetime ordering with suspended persistence instead of a fake crypto engine.
/// Structured children cannot outlive ownership, including when the deadline wins the race.
func runBackgroundWork(timeBudget: Duration,
                       operation: @escaping @Sendable () async throws -> Void,
                       consume: @escaping @Sendable () async throws -> Void,
                       stop: @escaping @Sendable () async -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await consume() }
        group.addTask {
            try await Task.sleep(for: timeBudget)
            throw BackgroundSynchronizationError.deadlineExceeded
        }
        do {
            try await group.next()
            group.cancelAll()
            await stop()
        } catch {
            group.cancelAll()
            await stop()
            throw error
        }
        // Group scope joins every child, even a durable commit that finishes after cancel.
    }
}
