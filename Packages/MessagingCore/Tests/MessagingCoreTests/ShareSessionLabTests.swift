import Foundation
import MessageStore
import Network
import OMEMO
import Testing
import XMPPProtocol
@testable import MessagingCore

/// A share's send against the local lab Prosody, with a PUT whose server accepts the connection and never answers.
/// Runs only when configured:
///   HAUS_LAB_SHARE_ACCOUNT  credential JSON ({"jid", "password"}) of a disposable lab account
///   HAUS_LAB_CA             the lab CA (PEM)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAUS_LAB_SHARE_ACCOUNT"] != nil))
struct ShareSessionLabTests {
    private struct Credentials: Decodable { let jid: String; let password: String }

    private let env = ProcessInfo.processInfo.environment

    @Test func aStalledUploadEndsAtTheDeadlineAndTheLeaseGoesBack() async throws {
        let credentials = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env["HAUS_LAB_SHARE_ACCOUNT"]))))
        let pem = try String(contentsOfFile: try #require(env["HAUS_LAB_CA"]), encoding: .utf8)
        let authority = try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
        let parts = credentials.jid.split(separator: "@").map(String.init)
        let account = BackgroundAccount(route: .fixed(XMPPEndpoint(host: "localhost", port: 5223, security: .directTLS)), domain: parts[1],
                                        username: parts[0], password: credentials.password, labCertificateAuthority: authority)
        let hole = try await BlackHole.start()
        defer { hole.stop() }

        let directory = FileManager.default.temporaryDirectory.appending(path: "share-lab-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: url)
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 13, count: 32)))
        let files = AttachmentFiles(directory: directory, account: credentials.jid)
        let peer = "peer-\(UUID().uuidString.prefix(8).lowercased())@\(parts[1])"
        try await store.upsertChat(accountID: credentials.jid, chatID: peer, title: peer)
        let prepared = PreparedAttachment(data: Data(repeating: 1, count: 64 * 1024), name: "stall.bin", mediaType: "application/octet-stream",
                                          width: nil, height: nil)
        let message = try await OutgoingEnqueue.file(prepared, account: credentials.jid, chatID: peer, limit: 1 << 20, store: store,
                                                     files: files, encryption: encryption)

        // The server's real slot is requested; the PUT goes to a socket that never answers, through the same URLSession call.
        let began = Flag()
        let session = ShareSession(store: store, encryption: encryption, files: files, account: account,
                                   uploadService: XMPPUploadService(jid: "uploads.\(parts[1])", maximumFileSize: nil)) { file, _, size in
            began.set()
            var request = URLRequest(url: hole.url)
            request.httpMethod = "PUT"
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            _ = try await session.upload(for: request, fromFile: file)
            return true
        }
        #expect(await session.acquireLease(waitingUpTo: .zero))
        let start = ContinuousClock.now
        let states = await session.send(messageIDs: [message.id], rooms: [], until: start + .seconds(8))
        let took = ContinuousClock.now - start
        #expect(began.value, "the PUT started")
        #expect(took < .seconds(10), "the deadline cancels the PUT (took \(took))")
        #expect(states == [message.id: .queued])
        await session.end()
        #expect(ContinuousClock.now - start < .seconds(12))

        // Another process takes the lease at once, and the file is still pending for the app's next connection.
        let other = try MessageStore(url: url, schema: .currentOnly)
        try await other.acquireTransportOwnership()
        try await other.releaseTransportOwnership()
        try await other.close()
        #expect(try await store.attachmentsAwaitingUpload(accountID: credentials.jid).map(\.id) == [message.id])
        try await store.close()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}

/// An HTTP server on the loopback that accepts every connection and never reads or answers.
private final class BlackHole: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    let url: URL

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(port)/upload")!
    }

    static func start() async throws -> BlackHole {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "share-lab-black-hole")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let hole = BlackHole(listener: listener, port: port)
        listener.newConnectionHandler = { [weak hole] connection in
            hole?.lock.withLock { hole?.connections.append(connection) }
            connection.start(queue: queue)
        }
        return hole
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { body() }
    }
}
