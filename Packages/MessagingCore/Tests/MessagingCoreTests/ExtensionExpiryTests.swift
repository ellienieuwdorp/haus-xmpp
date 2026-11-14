import Foundation
import MessageStore
import Network
import OMEMO
import os
import Testing
import XMPPProtocol
@testable import MessagingCore

// Accepts TCP connections and never answers, as a server behind a dead path: a TLS handshake with it never finishes.
final class HungServer: Sendable {
    private let listener: NWListener
    private let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())
    let port: UInt16

    private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

    static func start() async throws -> HungServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let value: Result<UInt16, any Error>? = switch state {
                case .ready: listener.port.map { .success($0.rawValue) } ?? .failure(NWError.posix(.EADDRNOTAVAIL))
                case .failed(let error): .failure(error)
                default: nil
                }
                guard let value, resumed.withLock({ let first = !$0; $0 = true; return first }) else { return }
                continuation.resume(with: value)
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: DispatchQueue(label: "hung.listener"))
        }
        let server = HungServer(listener: listener, port: port)
        listener.newConnectionHandler = { [server] connection in
            connection.start(queue: DispatchQueue(label: "hung.connection"))
            server.connections.withLock { $0.append(connection) }
        }
        return server
    }

    var accepted: Int { connections.withLock { $0.count } }

    var account: BackgroundAccount {
        BackgroundAccount(route: .fixed(XMPPEndpoint(host: "127.0.0.1", port: port, security: .directTLS)), domain: "localhost",
                          username: "alice", password: "private")
    }

    func stop() {
        listener.cancel()
        connections.withLock { $0.forEach { $0.cancel() } }
    }
}

// `lock` guards `value`.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var value: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

// A store file with an identity, and a second store on it that stands for another process wanting the lease.
private func withStores(_ body: (_ url: URL, _ store: MessageStore, _ other: MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "expiry-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.saveEncryptionState(accountID: "alice@localhost", expectedRevision: nil, data: Data([0]))
    try await store.releaseTransportOwnership()
    let other = try MessageStore(url: url, schema: .currentOnly)
    try await body(url, store, other)
    try await other.close()
    try await store.close()
}

private func shareSession(store: MessageStore, at url: URL, server: HungServer) throws -> ShareSession {
    ShareSession(store: store, encryption: OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32))),
                 files: AttachmentFiles(directory: url.deletingLastPathComponent(), account: "alice@localhost"),
                 account: server.account, uploadService: nil)
}

struct ExtensionExpiryTests {
    // The notification extension's run dials a server that never answers. Expiry cancels it, which closes the socket,
    // and answers once the run closed its store: the clock never moved, so the bound did not end the wait.
    @Test func notificationExpiryClosesAHungConnectionAndAnswersAfterTheRelease() async throws {
        let server = try await HungServer.start()
        defer { server.stop() }
        try await withStores { url, _, other in
            let clock = TestClock(), account = server.account
            let coordinator = NotificationRunCoordinator(clock: clock) { progress in
                do {
                    try await BackgroundSynchronizer().synchronize(databaseURL: url, wrappingKey: Data(repeating: 1, count: 32), account: account,
                                                                   progress: progress)
                    return .settled(progress.report)
                } catch {
                    return .ended(by: error, progress: progress)
                }
            }
            let ticket = UUID()
            let delivery = Task { await coordinator.deliver(ticket: ticket) }
            try await eventually("the run to dial") { server.accepted > 0 }
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) { try await other.acquireTransportOwnership() }
            #expect(try await bounded { await coordinator.expire(ticket: ticket) } == .fallback(.expired))
            #expect(clock.elapsed == .zero)
            try await other.acquireTransportOwnership()
            try await other.releaseTransportOwnership()
            #expect(try await bounded { await delivery.value }.suppressesRemoteAlert == false)
        }
    }

    // The share's connection hangs in its handshake. Expiry closes it, skips the presentation and returns once the
    // lease is released; the delivery's own `end` afterwards joins that teardown.
    @Test func shareExpiryClosesAHungConnectionAndReturnsAfterTheRelease() async throws {
        let server = try await HungServer.start()
        defer { server.stop() }
        try await withStores { url, store, other in
            let session = try shareSession(store: store, at: url, server: server)
            #expect(await session.acquireLease(waitingUpTo: .zero))
            // Far past the test: only the expiry ends this send.
            let sending = Task { await session.send(messageIDs: [], rooms: [], until: .now + .seconds(3600)) }
            try await eventually("the share to dial") { server.accepted > 0 }
            let clock = TestClock()
            #expect(try await bounded { await session.expire(within: .milliseconds(1500), clock: clock) })
            #expect(clock.elapsed == .zero)
            try await other.acquireTransportOwnership()
            try await other.releaseTransportOwnership()
            _ = try await bounded { await sending.value }
            let presented = Flag()
            await session.end(presentation: { _ in presented.raise() })
            #expect(!presented.value)
        }
    }

    // A presentation that ignores cancellation keeps the expiry waiting only up to its bound. The lease then stays with
    // that work, never released under it, and goes once the work ends.
    @Test func shareExpiryPastItsBoundLeavesTheLeaseWithTheWorkStillRunning() async throws {
        let server = try await HungServer.start()
        defer { server.stop() }
        try await withStores { url, store, other in
            let session = try shareSession(store: store, at: url, server: server)
            #expect(await session.acquireLease(waitingUpTo: .zero))
            let sending = Task { await session.send(messageIDs: [], rooms: [], until: .now + .seconds(3600)) }
            try await eventually("the share to dial") { server.accepted > 0 }
            let presenting = Flag(), stuck = Hold()
            // The delivery's end closes the connection, then presents what it received.
            let ending = Task { await session.end(presentation: { _ in presenting.raise(); await stuck.wait() }) }
            try await eventually("the presentation to start") { presenting.value }
            let clock = TestClock()
            let expiry = Task { await session.expire(within: .milliseconds(1500), clock: clock) }
            try await clock.sleepers(1)
            clock.advance(by: .milliseconds(1500))
            #expect(try await bounded { await expiry.value } == false)
            await #expect(throws: MessageStoreError.transportOwnedElsewhere) { try await other.acquireTransportOwnership() }
            await stuck.release()
            _ = try await bounded { await ending.value }
            _ = try await bounded { await sending.value }
            try await other.acquireTransportOwnership()
            try await other.releaseTransportOwnership()
        }
    }
}

// Ignores cancellation until released, as a system call that has not returned.
actor Hold {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}
