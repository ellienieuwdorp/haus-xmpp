import CryptoKit
import Foundation
import MessageStore
import Observation
import OMEMO
import os

/// Why a received file waits for a tap instead of downloading on sight.
enum AttachmentDownloadHold: Equatable, Sendable {
    /// A 1:1 chat we never wrote in: no request to the sender's host unasked.
    case sender
    /// Larger than the automatic limit, or of unknown size.
    case size
    /// Low Data Mode, or a cellular network for a file above the expensive limit.
    case network
}

/// A received file of the open chat that is not on disk yet.
enum AttachmentDownloadState: Equatable, Sendable {
    /// Waiting for a download slot or transferring.
    case loading
    case tapToDownload(AttachmentDownloadHold)
    /// The transfer or its verification failed; a tap tries again.
    case failed
    /// The body was longer than its message or the server said it would be. Fetching it again cannot succeed.
    case mismatch
    /// Larger than this app downloads at all; nothing is fetched.
    case tooLarge

    var canRequest: Bool {
        switch self {
        case .tapToDownload, .failed: true
        case .loading, .mismatch, .tooLarge: false
        }
    }
}

/// When a received file is fetched and how many bytes it may have. Every download has a cap set before it starts:
/// the declared size plus the 16-byte GCM tag, a HEAD Content-Length, or, for a tap on a file of unknown size, the
/// hard limit. Sizes here are body lengths, which for an encrypted file include the tag.
enum AttachmentDownloadPolicy {
    /// The largest body fetched at all: the largest file we decrypt, plus its tag.
    static let hardLimit = AttachmentTransfer.maximumBytes + 16
    /// Files up to this size download on sight on an unconstrained network.
    static let automaticLimit = 16 * 1024 * 1024
    /// Files up to this size also download on sight on cellular and other expensive networks.
    static let expensiveLimit = 5 * 1024 * 1024

    struct Fetch: Equatable, Sendable {
        let cap: Int
        let allowsExpensive: Bool
        let allowsConstrained: Bool
        /// What a body past the cap shows, when it is not past the hard limit too. A cap from a declared or announced
        /// size was a false promise; a cap of the hard limit was a file too large to fetch.
        var overrun = AttachmentDownloadState.mismatch
    }

    /// A file of unknown size whose server refused the HEAD (a presigned GET URL answers 403, some servers 405): its
    /// GET is capped at the automatic limit and kept off expensive networks, and a longer body waits for a tap.
    static let unmeasured = Fetch(cap: automaticLimit, allowsExpensive: false, allowsConstrained: false, overrun: .tapToDownload(.size))

    enum Decision: Equatable, Sendable {
        case fetch(Fetch)
        /// Size unknown: ask the server with a HEAD, then decide again.
        case probe
        case hold(AttachmentDownloadHold)
        case tooLarge
    }

    /// The body length expected for a file whose metadata declares `size` plaintext bytes; nil when it declares none
    /// (legacy `aesgcm://` links, or metadata without a size). A plain file's body is 16 bytes shorter: the margin.
    static func bodyLength(declaredSize size: Int) -> Int? { size > 0 ? size + 16 : nil }

    /// `automatic` is a fetch on sight rather than a tap; `knownSender` is false in a stranger's 1:1 chat.
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

/// Which received files download next: at most `limit` at once, those on screen before the rest, newer before older.
/// Keyed by cache file, so messages sharing one file share one download.
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

    /// Queues `key` for `messageID`, or adds the message to the download already queued or running for it.
    mutating func add(_ key: String, messageID: String, order: Date, visible: Bool) {
        if running[key] != nil { running[key]?.insert(messageID); return }
        var entry = pending[key] ?? Entry(messageIDs: [], visible: false, order: order)
        entry.messageIDs.insert(messageID)
        entry.visible = entry.visible || visible
        entry.order = max(entry.order, order)
        pending[key] = entry
    }

    func contains(_ key: String) -> Bool { pending[key] != nil || running[key] != nil }

    /// A queued file came on screen.
    mutating func promote(_ key: String) { pending[key]?.visible = true }

    /// The next key to start, counted as running from now; nil at the limit or when nothing waits.
    mutating func next() -> String? {
        guard running.count < limit,
              let key = pending.max(by: { ($0.value.visible ? 1 : 0, $0.value.order) < ($1.value.visible ? 1 : 0, $1.value.order) })?.key,
              let entry = pending.removeValue(forKey: key) else { return nil }
        running[key] = entry.messageIDs
        return key
    }

    /// Ends a running download; returns the messages that were waiting for it.
    mutating func finish(_ key: String) -> Set<String> { running.removeValue(forKey: key) ?? [] }

    /// The chat closed: nothing more starts. Running downloads finish and land in the cache.
    mutating func dropPending() { pending = [:] }
}

enum AttachmentDownloadOutcome: Equatable, Sendable {
    /// The verified plaintext is at the destination.
    case saved
    case state(AttachmentDownloadState)
    /// Cancelled before it finished; nothing was written.
    case cancelled
}

/// Fetches a shared file to disk and authenticates it. The body streams to a temporary file, and the transfer is
/// cancelled as soon as it passes its cap; a plain file is hashed on the way and moved into place. TLS trust is the
/// system store's (the simulator carries the lab CA); nothing here relaxes it.
final class AttachmentDownloader: Sendable {
    enum Failure: Error, Equatable {
        case badResponse
        /// The body passed its cap; `atLeast` is the announced length, or the bytes received when it passed.
        case tooLarge(atLeast: Int)
    }

    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    /// Never throws: every failure becomes the state the bubble shows.
    func download(_ attachment: StoredAttachment, secret: (key: Data, iv: Data)?, automatic: Bool, knownSender: Bool,
                  to destination: URL) async -> AttachmentDownloadOutcome {
        guard let remote = attachment.url, let url = URL(string: remote), url.scheme == "https" else { return .state(.failed) }
        do {
            var decision = AttachmentDownloadPolicy.decide(bodyLength: AttachmentDownloadPolicy.bodyLength(declaredSize: attachment.size),
                                                           automatic: automatic, knownSender: knownSender)
            if decision == .probe {
                switch try await bodyLength(of: url) {
                case .announced(let length): decision = AttachmentDownloadPolicy.decide(bodyLength: length, automatic: automatic, knownSender: knownSender)
                // The server gives no length either: wait for a tap, which downloads under the hard limit.
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

    /// The body length a HEAD announces. A server may refuse HEAD on a link that serves GET: a presigned URL is
    /// signed for GET only (403), and some servers do not implement it (405, 501). Like an automatic fetch, the probe
    /// never runs on a constrained network.
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

    /// Streams the body to `file`; returns the SHA-256 of what was written.
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
            // The system refused the request under Low Data Mode or on an expensive network: the user decides.
            if error.networkUnavailableReason != nil { return .state(.tapToDownload(.network)) }
            if error.code == .cancelled { return .cancelled }
        }
        return .state(.failed)
    }
}

/// One data task's body, written to disk as it arrives. The session's serial delegate queue runs the delegate
/// callbacks one at a time; only the continuation crosses from the starting task, under the lock.
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

/// Turns a downloaded body into the cached plaintext, one file at a time. CryptoKit's AES-GCM has no streaming
/// interface, so opening holds a copy of the ciphertext and the plaintext in memory (up to 32 MiB each); serialising
/// it keeps that peak to one file however many downloads run. The downloaded ciphertext itself is mapped from disk.
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

/// One received file to fetch for the open chat.
struct AttachmentDownloadJob: Sendable {
    let messageID: String
    let sentAt: Date
    let attachment: StoredAttachment
    let account: String
    let destination: URL
    /// On sight rather than on a tap.
    let automatic: Bool
    let knownSender: Bool
}

/// The open chat's received files: which download on sight and in which order, and what each bubble shows until its
/// file is on disk. A stranger's file, one above the automatic limit and one the network policy refuses wait for a
/// tap. At most `concurrent` downloads run at once; the newest `lookahead` files start when the chat opens, older
/// ones once their bubble comes on screen.
@MainActor @Observable
final class AttachmentDownloadCenter {
    /// Received files of the open chat that are not on disk, by message ID.
    private(set) var states: [String: AttachmentDownloadState] = [:]
    /// A verified file is on disk for these messages of the account: found in the cache or just downloaded.
    @ObservationIgnored var onFile: (_ account: String, _ messageIDs: [String], _ file: URL) -> Void = { _, _, _ in }
    /// A job's file key and IV; nil for a file shared without encryption. Throws while the account's keys cannot be
    /// opened, which fails that download.
    @ObservationIgnored var openSecret: (AttachmentDownloadJob) throws -> (key: Data, iv: Data)? = { _ in throw CancellationError() }
    @ObservationIgnored private let downloader: AttachmentDownloader
    @ObservationIgnored private let lookahead: Int
    @ObservationIgnored private var queue: AttachmentDownloadQueue
    /// What each queued or running download needs, by cache path.
    @ObservationIgnored private var jobs: [String: AttachmentDownloadJob] = [:]
    /// Older files that may download on sight, waiting until their bubble comes on screen, by message ID.
    @ObservationIgnored private var deferred: [String: AttachmentDownloadJob] = [:]

    init(configuration: URLSessionConfiguration, concurrent: Int = 2, lookahead: Int = 10) {
        downloader = AttachmentDownloader(configuration: configuration)
        queue = AttachmentDownloadQueue(limit: concurrent)
        self.lookahead = lookahead
    }

    /// The open chat's loaded messages, after every load. `known` is a group or a chat the user pinned; a 1:1 chat is
    /// also known once the window holds an own message. Messages `onDisk` already has a file for are skipped.
    func load(_ messages: [StoredMessage], known: Bool, files: AttachmentFiles, account: String, onDisk: (String) -> Bool) {
        // Approving a stranger's device lets their messages show; writing back is what lets their files download on
        // sight. The roster is no signal here: opening a chat asks for a subscription, and a direct chat's peer gets
        // one approved on request.
        let knownChat = known || messages.contains { $0.isOutgoing }
        // Written to since the chat opened: what waited for that is decided again.
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

    /// A bubble whose file is not on disk came on screen: its download goes before those of bubbles not seen.
    func displayed(_ messageID: String, attachment: StoredAttachment?, files: AttachmentFiles) {
        if let job = deferred.removeValue(forKey: messageID) {
            enqueue(job, visible: true)
        } else if let attachment {
            queue.promote(files.cacheURL(attachment, messageID: messageID).path)
        }
        start()
    }

    /// A tap on a file waiting for one, or on a failed one: fetched on any network, up to the hard limit.
    func request(_ message: StoredMessage, files: AttachmentFiles, account: String) {
        guard states[message.id]?.canRequest == true, let attachment = message.attachment else { return }
        states[message.id] = .loading
        deferred[message.id] = nil
        enqueue(AttachmentDownloadJob(messageID: message.id, sentAt: message.sentAt, attachment: attachment, account: account,
                                      destination: files.cacheURL(attachment, messageID: message.id), automatic: false, knownSender: true),
                visible: true)
        start()
    }

    /// The open chat changed: its states go, queued downloads are dropped, running ones finish into the cache.
    func reset() {
        states = [:]
        deferred = [:]
        queue.dropPending()
        jobs = jobs.filter { queue.contains($0.key) }
    }

    private func enqueue(_ job: AttachmentDownloadJob, visible: Bool) {
        let key = job.destination.path
        // A tap makes a queued automatic download of the same file a requested one; a running one is joined as it is.
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
        // Only messages of the chat still open have a state; the file stays cached for the others.
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
