import Foundation
import MessageStore
import OMEMO
import os
import XMPPProtocol

extension SessionEngine {
    func runSetup(_ connection: Connection, identityExists: Bool, resumed: Bool) async {
        let (account, store, encryption) = (connection.account, connection.store, connection.encryption)
        let profiles = profiles
        let streamID: @Sendable () async -> String? = {
            // An unreadable snapshot reads as no stream: carbons are then enabled again.
            try? await StreamPersistence(store: store, accountID: account, encryption: encryption).load()?.streamID
        }
        let memory = profiles.memory(account: account, stream: resumed ? await streamID() : nil,
                                     uploadsFresh: delegate?.uploadsFresh(account: account) ?? false)
        let setup = ConnectionSetup(identityExists: identityExists, resumed: resumed, memory: memory)
        // The stream ID is a store read; a newer connection may have started meanwhile.
        guard setupIsCurrent(connection.token) else { return }
        if resumed {
            let reused = "features=\(setup.skipsFeatures) carbons=\(setup.skipsCarbons) uploads=\(setup.skipsUploads)"
            Self.syncLog.notice("resume reuses \(reused, privacy: .public)")
        }
        delegate?.uploadDiscoveryStarted(discovers: !setup.skipsUploads)
        let operations = setupOperations(connection, streamID: streamID)
        let timings = timings
        await setup.run(operations: operations.timed(by: timings)) { [weak self] event in
            await self?.apply(event, connection)
        }
        if setupIsCurrent(connection.token) {
            let phases = timings.summary([.features, .carbons, .uploads, .keys, .rejoin, .walk, .retry])
            Self.syncLog.notice("setup finished +\(self.syncElapsed(), privacy: .public) ms \(phases, privacy: .public)")
        }
    }

    // Every operation runs inside the setup task under the generation fence; none spawns an unstructured task.
    private func setupOperations(_ connection: Connection, streamID: @escaping @Sendable () async -> String?) -> ConnectionSetup.Operations {
        let (account, client, encryption, store, token) = (connection.account, connection.client, connection.encryption, connection.store, connection.token)
        let profiles = profiles
        let domain = account.split(separator: "@", maxSplits: 1).last.map(String.init) ?? ""
        return ConnectionSetup.Operations(
            features: {
                let found = try await ConnectionSetup.discoverFeatures(server: { try await client.discoveryFeatures(for: domain) },
                                                                       account: { try await client.discoveryFeatures() })
                if found.complete { profiles.discovered(found.features, account: account) }
                return found.features
            },
            enableCarbons: {
                try await client.setCarbonsEnabled()
                profiles.carbonsEnabled(account: account, stream: await streamID())
            },
            discoverUploads: { [weak self] in
                // Optional XEP-0363: only a completed answer changes what the attach button remembers.
                let discovery: Result<XMPPUploadService?, any Error>
                do { discovery = .success(try await client.uploadService()) } catch { discovery = .failure(error) }
                await self?.uploadsDiscovered(discovery, account: account, token: token)
            },
            initializeEncryption: { try await encryption.initialize(account: account, transport: client) },
            rejoinGroups: { [weak self] in
                guard let self else { throw CancellationError() }
                // `.ready` has started the outbox; what follows it needs neither the rooms nor holds them back.
                async let afterReady: Void = self.afterReady(connection)
                do { try await self.rejoinKnownGroups(connection) } catch {
                    await afterReady
                    throw error
                }
                // Group messages queued offline waited for a joined room.
                await self.startOutbox()
                await afterReady
            },
            catchUp: { progress in
                let outcome = try await ArchiveSynchronizer(store: store).synchronize(account: account, client: client, encryption: encryption) {
                    await progress(CatchUpProgress(archive: $0.archive, pages: $0.pages, messages: $0.messages))
                }
                // A refused or unanswered archive query keeps the connection; the next connection walks that archive again.
                guard !outcome.isComplete else { return }
                let summary = "own=\(outcome.ownArchiveComplete) rooms=\(outcome.unfinishedRooms.count)"
                Logger(subsystem: "haus.xmpp.ios", category: "sync").notice("catch-up incomplete: \(summary, privacy: .public)")
            },
            retryPending: {
                // Rows that still fail stay pending for the next connection's retry.
                try? await encryption.retryPendingIncoming(account: account, transport: client)
            })
    }

    private func uploadsDiscovered(_ discovery: Result<XMPPUploadService?, any Error>, account: String, token: UUID) async {
        await delegate?.uploadsDiscovered(discovery, account: account, token: token)
    }

    // In the setup child's task, so a `.disconnected` handled first has already cancelled it.
    private func apply(_ event: ConnectionSetup.Event, _ connection: Connection) async {
        guard setupIsCurrent(connection.token) else { return }
        switch event {
        case .step(let step):
            delegate?.setupStep(step)
        case .ready:
            await ready(connection)
        case .catchingUp(let progress):
            catchingUp(progress, connection)
        case .degraded(let step, let detail):
            Self.syncLog.notice("setup went on without \(step, privacy: .public): \(detail, privacy: .public)")
        case .settled:
            milestones.settled = .now
            Self.syncLog.notice("settled +\(self.syncElapsed(), privacy: .public) ms")
            delegate?.setupSettled()
        case .failed(let step, let detail):
            walking = false
            delegate?.catchUpChanged(nil)
            if step == ConnectionSetup.archiveStep { Self.syncLog.notice("catch-up failed +\(self.syncElapsed(), privacy: .public) ms") }
            await setupFailed(step: step, detail: detail, client: connection.client, token: connection.token)
        }
    }

    private func ready(_ connection: Connection) async {
        let (account, client, token) = (connection.account, connection.client, connection.token)
        isReady = true
        milestones.ready = .now
        delegate?.setupReady()
        Self.syncLog.notice("ready +\(self.syncElapsed(), privacy: .public) ms")
        await flushEncryptionControls(account: account, client: client, logsLiveStore: false)
        await delegate?.readyRefresh()
        guard setupIsCurrent(token) else { return }
        startOutbox()
    }

    // Beside the rejoins, after the outbox started, so a server slow to answer holds back neither.
    private func afterReady(_ connection: Connection) async {
        let (account, client, token) = (connection.account, connection.client, connection.token)
        guard setupIsCurrent(token) else { return }
        // The result arrives as `.rosterItems` in stream order.
        async let roster: Void = fetchRoster(client)
        await delegate?.outboxStartedAtReady(account: account, client: client, token: token)
        await roster
    }

    // Roster pushes are answered only after a fetch on this stream.
    private func fetchRoster(_ client: XMPPClient) async {
        let start = ContinuousClock.now
        // A failed fetch leaves the roster unloaded; nothing else waits for it.
        _ = try? await client.fetchRoster()
        timings.add(.roster, since: start)
    }

    func catchingUp(_ progress: CatchUpProgress?, _ connection: Connection) {
        walking = progress != nil
        // First, before anything else reads it: a finished walk is `nil`.
        delegate?.catchUpChanged(progress)
        if let progress {
            catchUpByArchive[progress.archive ?? ""] = progress
            if progress.messages >= 1 { logFirstMessage() }
            return
        }
        let pages = catchUpByArchive.values.reduce(0) { $0 + $1.pages }
        let messages = catchUpByArchive.values.reduce(0) { $0 + $1.messages }
        let elapsed = syncElapsed(), rate = elapsed > 0 ? messages * 1000 / elapsed : 0
        let counts = "pages=\(pages) messages=\(messages) entries_per_s=\(rate) \(timings.summary([.reload, .notify]))"
        Self.syncLog.notice("catch-up finished +\(elapsed, privacy: .public) ms \(counts, privacy: .public)")
        milestones.caughtUp = .now
        archiveWalkFinished = true
        delegate?.walkFinished(account: connection.account, client: connection.client, token: connection.token)
        // Receipts the walk queued wait for a pass, and a quiet connection may start none.
        startOutbox()
    }

    private func rejoinKnownGroups(_ connection: Connection) async throws {
        let (account, client, token) = (connection.account, connection.client, connection.token)
        // However the pass ends, the owner rejoins a room that bounced meanwhile and was not just joined.
        var joined = Set<String>()
        defer { if setupIsCurrent(token) { delegate?.rejoinPassEnded(token: token, joined: joined) } }
        let rooms = try await connection.encryption.knownGroupRooms(account: account)
        for (room, members) in rooms.sorted(by: { $0.key < $1.key }) {
            guard setupIsCurrent(token), transportWorkAllowed else { throw CancellationError() }
            delegate?.roomRejoining(room, members: members)
            let nickname = delegate?.nickname(in: room, account: account) ?? String(account.prefix { $0 != "@" })
            // Mention detection is best effort.
            try? await store?.setGroupNickname(accountID: account, room: room, nickname: nickname)
            do {
                let snapshot = try await client.joinGroupRoom(room, nickname: nickname)
                guard setupIsCurrent(token) else { throw CancellationError() }
                joined.insert(room)
                delegate?.roomRejoined(room, joined: snapshot.joined)
            } catch {
                guard setupIsCurrent(token) else { throw CancellationError() }
                // No send until this room's own authenticated presence arrives; the walk fails closed without provenance.
                delegate?.roomRejoinFailed(room, error: error)
            }
        }
    }
}
