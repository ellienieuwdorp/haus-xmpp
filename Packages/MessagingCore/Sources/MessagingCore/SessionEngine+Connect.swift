import Foundation
import MessageStore
import OMEMO
import os
import XMPPProtocol

extension SessionEngine {
    /// How `open` signs in. The resource and presence are read just before they are configured, after the lease.
    public struct Login: Sendable {
        public var account: String
        public var route: XMPPRoute
        public var domain: String
        public var username: String
        public var password: String
        public var requireSCRAM: Bool
        public var resource: @MainActor @Sendable () -> String
        public var presence: @MainActor @Sendable () -> (availability: XMPPAvailability, clientActive: Bool)

        public init(account: String, route: XMPPRoute, domain: String, username: String, password: String, requireSCRAM: Bool,
                    resource: @escaping @MainActor @Sendable () -> String,
                    presence: @escaping @MainActor @Sendable () -> (availability: XMPPAvailability, clientActive: Bool)) {
            self.account = account; self.route = route; self.domain = domain; self.username = username; self.password = password
            self.requireSCRAM = requireSCRAM; self.resource = resource; self.presence = presence
        }
    }

    /// A newer connection or a reset took over before the stream opened; nothing was sent.
    public struct Superseded: Error {}

    // What one connection's setup works with, captured when the stream came online.
    struct Connection: Sendable {
        let account: String
        let client: XMPPClient
        let encryption: OMEMOService
        let store: MessageStore
        let token: UUID
    }

    /// Takes the lease, recovers interrupted sends, then configures stream management, the resource and presence
    /// and signs in. `startEvents` runs first, so `.online` is handled as the stream binds.
    public func open(_ connection: XMPPClient, token: UUID, login: Login) async throws -> XMPPConnectedSession {
        guard let store, let encryption else { throw MessageStoreError.invalidValue }
        let account = login.account
        try await acquireOwnership(store, token: token)
        await delegate?.ownershipReady(store: store, account: account)
        try await store.recoverInterruptedSubmissions(accountID: account)
        guard generation == token else { throw Superseded() }
        try await connection.configureStreamManagement(persistence: StreamPersistence(store: store, accountID: account, encryption: encryption))
        try await connection.configureResource(login.resource())
        let presence = login.presence()
        try await connection.setAvailability(presence.availability, clientActive: presence.clientActive)
        guard generation == token else { throw Superseded() }
        return try await connection.connect(route: login.route, domain: login.domain, username: login.username,
                                            password: login.password, requireSCRAM: login.requireSCRAM)
    }

    /// The live consumer: one event at a time under `token`.
    public func startEvents(_ connection: XMPPClient, token: UUID) {
        eventTask = Task { [weak self] in
            for await event in connection.events {
                guard let self, self.generation == token else { break }
                await self.handle(event, token: token)
            }
            // A full buffer drops the client's disconnect event and finishes the stream instead; without this the
            // session would stay connected with nothing left to reconnect it.
            guard let self, self.generation == token else { return }
            await self.handle(.state(.disconnected("Event consumer could not keep up")), token: token)
        }
    }

    func handle(_ event: XMPPEvent, token: UUID) async {
        switch event {
        case .state(let state):
            await connectionChanged(state, token: token)
        case .reaction, .retraction, .receipt, .encryptedMessage, .encryptedGroupMessage, .streamManagementBarrier, .displayedSync, .messageError:
            await processInbound(event, token: token)
        default:
            await delegate?.received(event, token: token)
        }
    }

    private func connectionChanged(_ state: XMPPConnectionState, token: UUID) async {
        connectPhases.mark(state)
        isReady = false
        switch state {
        case .connecting, .authenticating, .binding:
            delegate?.connectionChanged(state)
        case .online:
            await streamOnline(state, token: token)
        case .disconnected(let reason):
            Self.syncLog.notice("disconnected: \(reason ?? "closed", privacy: .public)")
            // Its client calls fail with the connection anyway; cancelling makes the exit prompt.
            setupTask?.cancel()
            backfillTask?.cancel()
            archiveWalkFinished = false
            walking = false
            drainTask?.cancel()
            delegate?.connectionChanged(state)
        }
    }

    private func streamOnline(_ state: XMPPConnectionState, token: UUID) async {
        let account = account
        delegate?.connectionChanged(state)
        let online = ContinuousClock.now
        onlineAt = online
        timings = SyncPhaseTimings()
        milestones = Milestones()
        milestones.online = online
        firstMessageLogged = false
        liveStoredLogged = false
        catchUpByArchive = [:]
        let resumed = await client?.sessionResumed ?? false
        Self.syncLog.notice("online resumed=\(resumed, privacy: .public)\(self.connectPhases.summary(online: online), privacy: .public)")
        await delegate?.streamOnline(client: client, resumed: resumed)
        guard generation == token, let encryption, let client, let store else { return }
        let identityExists: Bool
        // The setup task's initialize reports the real problem.
        do { identityExists = try await store.encryptionState(accountID: account) != nil } catch { identityExists = true }
        guard generation == token else { return }
        if !identityExists {
            // The live consumer cannot persist anything without encryption state: publish a new account's identity
            // before setup runs concurrently.
            delegate?.setupStep(ConnectionSetup.keysStep)
            do { try await encryption.initialize(account: account, transport: client) } catch {
                guard generation == token else { return }
                await setupFailed(step: ConnectionSetup.keysStep, detail: ConnectionSetup.detail(error), client: client, token: token)
                return
            }
            guard generation == token else { return }
        }
        let connection = Connection(account: account, client: client, encryption: encryption, store: store, token: token)
        // The event loop keeps persisting and acknowledging live stanzas while setup runs; OMEMO's operation gate
        // serialises the two per crypto operation.
        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.runSetup(connection, identityExists: identityExists, resumed: resumed)
            if self.generation == token { self.setupTask = nil }
        }
    }

    // A half-alive session is a connection failure: end it and let the owner's reconciler retry.
    func setupFailed(step: String, detail: String, client: XMPPClient, token: UUID) async {
        isReady = false
        await delegate?.setupFailed(step: step, detail: detail)
        guard generation == token else { return }
        await client.disconnect()
    }

    // One processor per connection: it owns the "may acknowledge" rule for this stream.
    private func processInbound(_ event: XMPPEvent, token: UUID) async {
        guard let encryption, let client else { return }
        let account = account
        delegate?.inboundArrived(event, token: token)
        if inbound?.client !== client { inbound = InboundProcessor(encryption: encryption, client: client, account: account) }
        guard let inbound else { return }
        do {
            let outcome = try await inbound.process(event)
            guard generation == token else { return }
            delegate?.inboundProcessed(event, token: token)
            if outcome == .stored {
                await flushEncryptionControls(account: account, client: client)
                guard generation == token else { return }
            }
            await delegate?.inboundSettled(event, outcome: outcome, token: token)
        } catch {
            guard generation == token else { return }
            delegate?.inboundFailed(event, error: error)
        }
    }
}
