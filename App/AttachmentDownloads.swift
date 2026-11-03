import CryptoKit
import Foundation
import MessageStore
import MessagingCore
import Observation
import OMEMO
import XMPPProtocol
import os

// Every download has a cap set before it starts: the declared size plus the 16-byte GCM tag, a HEAD
// Content-Length, or the hard limit for a tap on a file of unknown size.
enum AttachmentDownloadPolicy {
    static let hardLimit = AttachmentTransfer.maximumBytes + 16
    static let automaticLimit = 16 * 1024 * 1024
    static let expensiveLimit = 5 * 1024 * 1024

    struct Fetch: Equatable, Sendable {
        let cap: Int
        let allowsExpensive: Bool
        let allowsConstrained: Bool
        var overrun = AttachmentDownloadState.mismatch
    }

    // For servers that refuse HEAD (presigned GET URLs answer 403, some 405): capped at the automatic limit, kept
    // off expensive networks, and a longer body waits for a tap.
    static let unmeasured = Fetch(cap: automaticLimit, allowsExpensive: false, allowsConstrained: false, overrun: .tapToDownload(.size))

    enum Decision: Equatable, Sendable {
        case fetch(Fetch)
        case probe
        case hold(AttachmentDownloadHold)
        case tooLarge
    }

    // Nil for legacy `aesgcm://` links or metadata without a size. A plain file's body is 16 bytes shorter: the margin.
    static func bodyLength(declaredSize size: Int) -> Int? { size > 0 ? size + 16 : nil }

    static func decide(bodyLength: Int?, automatic: Bool, knownSender: Bool) -> Decision {
        if let bodyLength, bodyLength > hardLimit { return .tooLarge }
        guard automatic else {
            return .fetch(Fetch(cap: bodyLength ?? hardLimit, allowsExpensive: true, allowsConstrained: true, overrun: bodyLength == nil ? .tooLarge : .mismatch))
        }
        guard knownSender else { return .hold(.sender) }
        guard let bodyLength else { return .probe }
        guard bodyLength <= automaticLimit else { return .hold(.size) }
        return .fetch(Fetch(cap: bodyLength, allowsExpensive: bodyLength <= expensiveLimit, allowsConstrained: false))
    }
}

// Keyed by cache file, so messages sharing one file share one download.
struct AttachmentDownloadQueue {
    private struct Entry {
        var messageIDs: Set<String>
        var visible: Bool
        var order: Date
    }
    let limit: Int
    private var pending: [String: Entry] = [:]
    private var running: [String: Set<String>] = [:]

    init(limit: Int) { self.limit = limit }

    mutating func add(_ key: String, messageID: String, order: Date, visible: Bool) {
        if running[key] != nil { running[key]?.insert(messageID); return }
        var entry = pending[key] ?? Entry(messageIDs: [], visible: false, order: order)
        entry.messageIDs.insert(messageID)
        entry.visible = entry.visible || visible
        entry.order = max(entry.order, order)
        pending[key] = entry
    }

    func contains(_ key: String) -> Bool { pending[key] != nil || running[key] != nil }

    mutating func promote(_ key: String) { pending[key]?.visible = true }

    mutating func next() -> String? {
        guard running.count < limit,
              let key = pending.max(by: { ($0.value.visible ? 1 : 0, $0.value.order) < ($1.value.visible ? 1 : 0, $1.value.order) })?.key,
              let entry = pending.removeValue(forKey: key) else { return nil }
        running[key] = entry.messageIDs
        return key
    }

    mutating func finish(_ key: String) -> Set<String> { running.removeValue(forKey: key) ?? [] }

    mutating func dropPending() { pending = [:] }
}

enum AttachmentDownloadOutcome: Equatable, Sendable {
    case saved
    case state(AttachmentDownloadState)
    case cancelled
}

// The body streams to a temporary file and is cancelled once past its cap. TLS trust is the system store's.
final class AttachmentDownloader: Sendable {
    enum Failure: Error, Equatable {
        case badResponse
        case tooLarge(atLeast: Int)
    }

    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    func download(_ attachment: StoredAttachment, secret: (key: Data, iv: Data)?, automatic: Bool, knownSender: Bool,
                  to destination: URL) async -> AttachmentDownloadOutcome {
        guard let remote = attachment.url, let url = URL(string: remote), url.scheme == "https" else { return .state(.failed) }
        do {
            var decision = AttachmentDownloadPolicy.decide(bodyLength: AttachmentDownloadPolicy.bodyLength(declaredSize: attachment.size),
                                                           automatic: automatic, knownSender: knownSender)
            if decision == .probe {
                switch try await bodyLength(of: url) {
                case .announced(let length): decision = AttachmentDownloadPolicy.decide(bodyLength: length, automatic: automatic, knownSender: knownSender)
                case .unannounced: return .state(.tapToDownload(.size))
                case .refused: decision = .fetch(AttachmentDownloadPolicy.unmeasured)
                }
            }
            let fetch: AttachmentDownloadPolicy.Fetch
            switch decision {
            case .fetch(let value): fetch = value
            case .hold(let reason): return .state(.tapToDownload(reason))
            case .tooLarge: return .state(.tooLarge)
            case .probe: return .state(.tapToDownload(.size))
            }
            let partial = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".download")
            defer { try? FileManager.default.removeItem(at: partial) }
            let digest: Data
            do { digest = try await body(of: url, fetch, to: partial) }
            catch Failure.tooLarge(let atLeast) { return .state(atLeast > AttachmentDownloadPolicy.hardLimit ? .tooLarge : fetch.overrun) }
            try await AttachmentOpener.shared.place(partial, digest: digest, attachment: attachment, secret: secret, at: destination)
            return .saved
        } catch {
            return Self.outcome(for: error)
        }
    }

    private enum Measured { case announced(Int), unannounced, refused }

    // Some servers refuse HEAD on a link that serves GET (presigned URLs: 403; 405, 501). Never runs on a
    // constrained network.
    private func bodyLength(of url: URL) async throws -> Measured {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.allowsConstrainedNetworkAccess = false
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        if [403, 405, 501].contains(http.statusCode) { return .refused }
        guard (200...299).contains(http.statusCode) else { throw Failure.badResponse }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
        return length.map(Measured.announced) ?? .unannounced
    }

    private func body(of url: URL, _ fetch: AttachmentDownloadPolicy.Fetch, to file: URL) async throws -> Data {
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw CocoaError(.fileWriteUnknown) }
        let body = BoundedBody(cap: fetch.cap, handle: try FileHandle(forWritingTo: file))
        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = fetch.allowsExpensive
        request.allowsConstrainedNetworkAccess = fetch.allowsConstrained
        let task = session.dataTask(with: request)
        task.delegate = body
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in body.start(task, continuation: continuation) }
        } onCancel: { task.cancel() }
    }

    private static func outcome(for error: any Error) -> AttachmentDownloadOutcome {
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.networkUnavailableReason != nil { return .state(.tapToDownload(.network)) }
            if error.code == .cancelled { return .cancelled }
        }
        return .state(.failed)
    }
}

// The serial delegate queue runs callbacks one at a time; only the continuation crosses threads, under the lock.
private final class BoundedBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let cap: Int
    private let handle: FileHandle
    private var hasher = SHA256()
    private var received = 0
    private var failure: (any Error)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(cap: Int, handle: FileHandle) { self.cap = cap; self.handle = handle }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Data, any Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            failure = AttachmentDownloader.Failure.badResponse
            completionHandler(.cancel)
            return
        }
        // A server that announces more than the cap is refused before any of the body arrives.
        if http.expectedContentLength > cap {
            failure = AttachmentDownloader.Failure.tooLarge(atLeast: Int(http.expectedContentLength))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += data.count
        guard received <= cap else {
            failure = AttachmentDownloader.Failure.tooLarge(atLeast: received)
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
            hasher.update(data: data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let closed = Result { try handle.close() }
        let continuation = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else if case .failure(let error) = closed { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: Data(hasher.finalize())) }
    }
}

// Serialised: CryptoKit's AES-GCM has no streaming API, so opening holds ciphertext and plaintext in memory
// (up to 32 MiB each); one file at a time bounds the peak.
private actor AttachmentOpener {
    static let shared = AttachmentOpener()

    func place(_ partial: URL, digest: Data, attachment: StoredAttachment, secret: (key: Data, iv: Data)?, at destination: URL) throws {
        guard let secret else {
            // An unencrypted source still has to match the hash the authenticated message promised.
            if let expected = Data(hex: attachment.hash), !expected.isEmpty, digest != expected { throw AttachmentTransfer.Failure.plainHashMismatch }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: partial, to: destination)
            return
        }
        let ciphertext = try Data(contentsOf: partial, options: .alwaysMapped)
        let plaintext = try AttachmentTransfer.open(ciphertext, key: secret.key, iv: secret.iv,
                                                    expectedCipherHash: attachment.cipherHash.flatMap { Data(hex: $0) },
                                                    expectedPlainHash: Data(hex: attachment.hash))
        try plaintext.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct AttachmentDownloadJob: Sendable {
    let messageID: String
    let sentAt: Date
    let attachment: StoredAttachment
    let account: String
    let destination: URL
    let automatic: Bool
    let knownSender: Bool
}

@MainActor @Observable
final class AttachmentDownloadCenter {
    private(set) var states: [String: AttachmentDownloadState] = [:]
    @ObservationIgnored var onFile: (_ account: String, _ messageIDs: [String], _ file: URL) -> Void = { _, _, _ in }
    @ObservationIgnored var openSecret: (AttachmentDownloadJob) throws -> (key: Data, iv: Data)? = { _ in throw CancellationError() }
    @ObservationIgnored private let downloader: AttachmentDownloader
    @ObservationIgnored private let lookahead: Int
    @ObservationIgnored private var queue: AttachmentDownloadQueue
    @ObservationIgnored private var jobs: [String: AttachmentDownloadJob] = [:]
    @ObservationIgnored private var deferred: [String: AttachmentDownloadJob] = [:]

    init(configuration: URLSessionConfiguration, concurrent: Int = 2, lookahead: Int = 10) {
        downloader = AttachmentDownloader(configuration: configuration)
        queue = AttachmentDownloadQueue(limit: concurrent)
        self.lookahead = lookahead
    }

    // `known` is a group or a pinned chat; a 1:1 chat is also known once the window holds an own message.
    func load(_ messages: [StoredMessage], known: Bool, files: AttachmentFiles, account: String, onDisk: (String) -> Bool) {
        // Writing back is what lets a stranger's files download on sight. The roster is no signal: opening a chat
        // asks for a subscription.
        let knownChat = known || messages.contains { $0.isOutgoing }
        if knownChat, states.values.contains(.tapToDownload(.sender)) {
            states = states.filter { $0.value != .tapToDownload(.sender) }
        }
        var ahead = lookahead
        for message in messages.reversed() {
            guard let attachment = message.attachment, !onDisk(message.id) else { continue }
            if let cached = files.cached(attachment, messageID: message.id) {
                states[message.id] = nil
                onFile(account, [message.id], cached)
                continue
            }
            guard attachment.url != nil, attachment.uploadState == nil, states[message.id] == nil else { continue }
            let job = AttachmentDownloadJob(messageID: message.id, sentAt: message.sentAt, attachment: attachment, account: account,
                                            destination: files.cacheURL(attachment, messageID: message.id),
                                            automatic: true, knownSender: knownChat || message.isOutgoing)
            switch AttachmentDownloadPolicy.decide(bodyLength: AttachmentDownloadPolicy.bodyLength(declaredSize: attachment.size),
                                                   automatic: true, knownSender: job.knownSender) {
            case .tooLarge: states[message.id] = .tooLarge
            case .hold(let reason): states[message.id] = .tapToDownload(reason)
            case .fetch, .probe:
                states[message.id] = .loading
                if ahead > 0 { ahead -= 1; enqueue(job, visible: false) } else { deferred[message.id] = job }
            }
        }
        start()
    }

    func displayed(_ messageID: String, attachment: StoredAttachment?, files: AttachmentFiles) {
        if let job = deferred.removeValue(forKey: messageID) {
            enqueue(job, visible: true)
        } else if let attachment {
            queue.promote(files.cacheURL(attachment, messageID: messageID).path)
        }
        start()
    }

    func request(_ message: StoredMessage, files: AttachmentFiles, account: String) {
        guard states[message.id]?.canRequest == true, let attachment = message.attachment else { return }
        states[message.id] = .loading
        deferred[message.id] = nil
        enqueue(AttachmentDownloadJob(messageID: message.id, sentAt: message.sentAt, attachment: attachment, account: account,
                                      destination: files.cacheURL(attachment, messageID: message.id), automatic: false, knownSender: true),
                visible: true)
        start()
    }

    func reset() {
        states = [:]
        deferred = [:]
        queue.dropPending()
        jobs = jobs.filter { queue.contains($0.key) }
    }

    private func enqueue(_ job: AttachmentDownloadJob, visible: Bool) {
        let key = job.destination.path
        if jobs[key] == nil || !job.automatic { jobs[key] = job }
        queue.add(key, messageID: job.messageID, order: job.sentAt, visible: visible)
    }

    private func start() {
        while let key = queue.next() {
            guard let job = jobs[key] else { _ = queue.finish(key); continue }
            let downloader = downloader
            let secret = Result { try openSecret(job) }
            Task { [weak self] in
                let outcome: AttachmentDownloadOutcome = switch secret {
                case .success(let secret):
                    await downloader.download(job.attachment, secret: secret, automatic: job.automatic, knownSender: job.knownSender, to: job.destination)
                case .failure: .state(.failed)
                }
                self?.finish(key, job: job, outcome: outcome)
            }
        }
    }

    private func finish(_ key: String, job: AttachmentDownloadJob, outcome: AttachmentDownloadOutcome) {
        let waiting = queue.finish(key).filter { states[$0] != nil }
        jobs[key] = nil
        if outcome == .state(.failed) || outcome == .state(.mismatch) {
            Logger(subsystem: "haus.xmpp.ios", category: "attachments").error("Download of \(job.attachment.name, privacy: .private) failed: \(String(describing: outcome), privacy: .public)")
        }
        switch outcome {
        case .saved:
            for id in waiting { states[id] = nil }
            if !waiting.isEmpty { onFile(job.account, Array(waiting), job.destination) }
        case .state(let state): for id in waiting { states[id] = state }
        case .cancelled: for id in waiting { states[id] = .failed }
        }
        start()
    }
}
