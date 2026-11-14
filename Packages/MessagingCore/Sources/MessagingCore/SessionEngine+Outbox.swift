import Foundation
import MessageStore
import OMEMO
import os
import XMPPProtocol

extension SessionEngine {
    /// No pass runs or waits to run.
    public var outboxIdle: Bool { drainTask == nil && !outboxRequested }

    /// Starts an outbox pass, or asks for one after the pass in flight. Runs only on a ready session that holds the
    /// lease and wants its transport; a request made meanwhile is kept for the next ready connection.
    public func startOutbox() {
        outboxRequested = true
        guard hasTransportOwnership, wantsTransport, !quiescing, drainTask == nil, isReady, delegate?.mayDrainOutbox ?? true,
              let client, let outboxSender, let encryption, let store else { return }
        outboxRequested = false
        let joinedGroups = delegate?.joinedRooms ?? []
        let account = account
        let token = generation
        let endActivity = delegate?.backgroundActivity("Send the outbox")
        if milestones.outboxStarted == nil { milestones.outboxStarted = .now }
        let hooks = delegate?.outboxHooks(token: token) ?? OutboxDrain.Hooks()
        drainTask = Task { [weak self] in
            defer { endActivity?() }
            let result: Result<Set<String>, any Error>
            do {
                let drain = OutboxDrain(account: account, client: client, encryption: encryption, store: store,
                                        sender: outboxSender, joinedGroups: joinedGroups)
                result = .success(try await drain.run(hooks))
            } catch {
                result = .failure(error)
            }
            await self?.outboxPassEnded(result, token: token)
        }
    }

    private func outboxPassEnded(_ result: Result<Set<String>, any Error>, token: UUID) async {
        await delegate?.outboxPassEnded(result, token: token)
        drainTask = nil
        drainPasses += 1
        // A different account or session may have become ready while this attempt settled.
        if outboxRequested || generation != token { startOutbox() }
        if generation == token { delegate?.outboxIdle(token: token) }
    }

    /// Publishes pending bundle changes, then starts the outbox: key transports are ordinary durable updates the
    /// drain sends.
    public func flushEncryptionControls(account: String, client: XMPPClient, logsLiveStore: Bool = true) async {
        guard self.account == account, self.client === client else { return }
        if logsLiveStore, walking, !liveStoredLogged {
            liveStoredLogged = true
            logFirstMessage()
            Self.syncLog.notice("live stored +\(self.syncElapsed(), privacy: .public) ms")
        }
        // A failed publication stays pending in the stored state, and the next flush publishes it.
        try? await encryption?.flushBundlePublications(account: account, transport: client)
        startOutbox()
    }

    func logFirstMessage() {
        guard !firstMessageLogged else { return }
        firstMessageLogged = true
        Self.syncLog.notice("first message +\(self.syncElapsed(), privacy: .public) ms")
    }
}
