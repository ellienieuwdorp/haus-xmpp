import Foundation
import MessageStore
import OMEMO
import os
import XMPPProtocol
@testable import MessagingCore

// The notification extension's run for the peer, woken for one encrypted direct message from the sender. Only the run
// crosses the relay; the run stamps its points, and their round trips are read off the relay's timeline.
struct SyncBenchWake {
    let environment: SyncBenchEnvironment
    let proxy: SyncBenchProxy
    let bench: SyncBenchStore
    let streamProfiles: StreamProfileMemory

    private var peer: SyncBenchFixture.Account { environment.fixture.peer }

    func run(_ scenario: String, expectResumed: Bool) async throws -> SyncBenchResult {
        try await sendFromSender("syncbench wake \(UUID().uuidString.prefix(8))")
        let posting = FakePosting()
        let marks = OSAllocatedUnfairLock(initialState: [String: ContinuousClock.Instant]())
        let progress = NotificationRunProgress()
        let push = SyncBenchClock.now(), before = proxy.counts, cpu = SyncBenchClock.cpuMilliseconds()
        let account = BackgroundAccount(route: .fixed(XMPPEndpoint(host: "127.0.0.1", port: proxy.port, security: .directTLS)),
                                        domain: peer.domain, username: peer.localpart, password: peer.password,
                                        labCertificateAuthority: environment.authority, resource: environment.fixture.resource,
                                        streamProfiles: streamProfiles)
        let accountID = peer.jid
        try await BackgroundSynchronizer().synchronize(
            databaseURL: bench.url.appending(path: "messages.sqlite"), wrappingKey: SyncBenchFixture.key, account: account,
            progress: progress, presentation: { store, stage in
                let now = SyncBenchClock.now()
                marks.withLock { $0[stage.isFinal ? "presented" : "direct"] = now }
                try await NotificationPresenter(posting: posting).present(store: store, accountID: accountID, progress: progress, stage: stage)
            })
        let finished = SyncBenchClock.now()
        let report = progress.report
        var points = marks.withLock { $0 }
        points["total"] = finished
        points["connect"] = proxy.firstConnection(after: push)
        if let ms = report.onlineMilliseconds { points["online"] = push + .milliseconds(ms) }
        if let ms = report.ownArchiveMilliseconds { points["ownArchive"] = push + .milliseconds(ms) }

        var result = SyncBenchResult(scenario: scenario)
        let startTrips = proxy.roundTrips(through: push)
        for (point, at) in points {
            result.wallMs[point] = SyncBenchClock.milliseconds(push, at)
            result.roundTrips[point] = proxy.roundTrips(through: at) - startTrips
        }
        result.totals = proxy.counts - before
        result.roundTrips["total"] = result.totals.roundTrips
        result.cpuMs = SyncBenchClock.cpuMilliseconds() - cpu
        result.values["resumed"] = report.resumed == true ? 1 : 0
        result.values["posted"] = report.posted
        result.values["leaseWaitMs"] = report.leaseWaitMilliseconds
        result.passed = report.posted == 1 && points["direct"] != nil && report.resumed == expectResumed
        return result
    }

    // The server's session for the peer goes, as when its hibernation runs out: a bind under the same resource replaces
    // it, then ends without stream management. The store keeps the session it can no longer resume.
    func dropSession() async throws {
        let client = XMPPClient(labCertificateAuthority: environment.authority)
        try await client.configureResource(environment.fixture.resource)
        try await client.connect(host: "127.0.0.1", port: 5223, domain: peer.domain, username: peer.localpart, password: peer.password)
        await client.disconnectAndWait()
    }

    // One encrypted direct message from the sender's own store, taken by the server before this returns.
    private func sendFromSender(_ body: String) async throws {
        let sender = environment.fixture.sender
        let bench = try SyncBenchStore.open(environment.senderStore)
        do {
            try await bench.store.acquireTransportOwnership()
            let client = XMPPClient(labCertificateAuthority: environment.authority)
            try await client.connect(host: "127.0.0.1", port: 5223, domain: sender.domain, username: sender.localpart, password: sender.password)
            let processor = InboundProcessor(encryption: bench.encryption, client: client, account: sender.jid)
            // Without stream management a stanza that fails here is never acknowledged anyway.
            let consumer = Task { for await event in client.events { _ = try? await processor.process(event) } }
            _ = try await OutgoingEnqueue.text(body, account: sender.jid, chatID: peer.jid, store: bench.store)
            let held = try await OutboxDrain(account: sender.jid, client: client, encryption: bench.encryption, store: bench.store,
                                             sender: OutboxSender(store: bench.store), joinedGroups: []).run()
            // Answered after the send, so the server has taken it.
            _ = try await client.fetchRoster()
            await client.disconnectAndWait()
            consumer.cancel()
            await consumer.value
            guard held.isEmpty else { throw SyncBenchFailure.configuration("the sender held the wake message: \(held)") }
        } catch {
            try? await bench.close(removing: false)
            throw error
        }
        try await bench.close(removing: false)
    }
}
