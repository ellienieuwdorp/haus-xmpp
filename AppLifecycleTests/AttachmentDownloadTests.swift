import CryptoKit
import MessageStore
import OMEMO
import XCTest
@testable import HausXMPP

/// Received files through the real downloader and URLSession, with the server replaced by an in-process
/// URLProtocol. The stub plays the system's part for Low Data Mode and expensive networks: it refuses a request
/// that opts out of them, the way the loader does on such a path.
final class AttachmentDownloadTests: XCTestCase {
    private var directory: URL!
    private var configuration: URLSessionConfiguration!
    private var downloader: AttachmentDownloader!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "AttachmentDownloadTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        downloader = AttachmentDownloader(configuration: configuration)
    }

    override func tearDownWithError() throws {
        StubServer.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testABodyLongerThanTheDeclaredSizeIsCancelledAndNotOfferedAgain() async throws {
        let plain = Data(repeating: 7, count: 1_000)
        let body = Data(repeating: 7, count: 8 * 1024 * 1024)
        for announces in [false, true] {
            let route = StubServer.serve(.init(body: body, announcesLength: announces))
            let destination = directory.appending(path: "file.bin")
            for automatic in [true, false] {
                let outcome = await downloader.download(attachment(declaring: plain.count, hash: Data.sha256(plain), url: route), secret: nil,
                                                        automatic: automatic, knownSender: true, to: destination)
                // A tap would fail the same way: the bubble offers no retry.
                XCTAssertEqual(outcome, .state(.mismatch), "announced length: \(announces), automatic: \(automatic)")
                XCTAssertFalse(AttachmentDownloadState.mismatch.canRequest)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertLessThan(StubServer.delivered(route), 2 * 1024 * 1024, "The transfers stop near the cap, not at the end of the body")
        }
    }

    func testAnAnnouncedLengthAboveTheHardLimitIsRefusedBeforeTheBody() async throws {
        let route = StubServer.serve(.init(body: Data(repeating: 1, count: 4 * 1024 * 1024), announcedLength: AttachmentDownloadPolicy.hardLimit + 1))
        let destination = directory.appending(path: "file.bin")
        // A tap on a file of unknown size: no HEAD, the GET's own Content-Length is checked against the hard limit.
        let outcome = await downloader.download(attachment(declaring: 0, hash: Data(), url: route), secret: secret(), automatic: false,
                                                knownSender: true, to: destination)
        XCTAssertEqual(outcome, .state(.tooLarge))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertLessThan(StubServer.delivered(route), 4 * 1024 * 1024)
    }

    func testAutomaticDownloadsWaitForATapOnConstrainedAndExpensiveNetworks() async throws {
        let small = Data(repeating: 2, count: 1024 * 1024), large = Data(repeating: 3, count: 8 * 1024 * 1024)
        for (plain, network, expected) in [(small, StubServer.Network.constrained, AttachmentDownloadOutcome.state(.tapToDownload(.network))),
                                           (large, .expensive, .state(.tapToDownload(.network))),
                                           (small, .expensive, .saved)] {
            let sealed = try AttachmentTransfer.seal(plain)
            let route = StubServer.serve(.init(body: sealed.ciphertext, network: network))
            let file = attachment(declaring: plain.count, hash: Data.sha256(plain), url: route)
            let destination = directory.appending(path: UUID().uuidString)
            let automatic = await downloader.download(file, secret: (sealed.key, sealed.iv), automatic: true, knownSender: true, to: destination)
            XCTAssertEqual(automatic, expected, "\(plain.count) bytes on a \(network) network")
            // A tap downloads on any network.
            let tapped = await downloader.download(file, secret: (sealed.key, sealed.iv), automatic: false, knownSender: true, to: destination)
            XCTAssertEqual(tapped, .saved)
            XCTAssertEqual(try Data(contentsOf: destination), plain)
        }
    }

    func testALinkWithoutASizeIsMeasuredWithAHeadFirst() async throws {
        let plain = Data(repeating: 4, count: 64 * 1024)
        let sealed = try AttachmentTransfer.seal(plain)
        let measured = StubServer.serve(.init(body: sealed.ciphertext))
        let destination = directory.appending(path: "legacy.jpg")
        let outcome = await downloader.download(attachment(declaring: 0, hash: Data(), url: measured), secret: (sealed.key, sealed.iv),
                                                automatic: true, knownSender: true, to: destination)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try Data(contentsOf: destination), plain)
        XCTAssertEqual(StubServer.methods(measured), ["HEAD", "GET"])

        let large = StubServer.serve(.init(body: Data(), announcedLength: AttachmentDownloadPolicy.automaticLimit + 1))
        let unannounced = StubServer.serve(.init(body: sealed.ciphertext, announcesLength: false))
        for route in [large, unannounced] {
            let held = await downloader.download(attachment(declaring: 0, hash: Data(), url: route), secret: (sealed.key, sealed.iv),
                                                 automatic: true, knownSender: true, to: directory.appending(path: UUID().uuidString))
            XCTAssertEqual(held, .state(.tapToDownload(.size)))
            XCTAssertEqual(StubServer.methods(route), ["HEAD"], "Only the HEAD reaches the server")
        }
    }

    func testAServerThatRefusesHeadStillServesSmallFilesOnSight() async throws {
        let plain = Data(repeating: 5, count: 64 * 1024)
        let sealed = try AttachmentTransfer.seal(plain)
        let cases: [(route: StubServer.Route, expected: AttachmentDownloadOutcome, methods: [String])] = [
            // A presigned GET URL refuses HEAD, and some servers do not implement it: the GET is capped instead.
            (.init(body: sealed.ciphertext, headStatus: 403), .saved, ["HEAD", "GET"]),
            (.init(body: sealed.ciphertext, headStatus: 405), .saved, ["HEAD", "GET"]),
            (.init(body: sealed.ciphertext, headStatus: 405, network: .expensive), .state(.tapToDownload(.network)), ["HEAD", "GET"]),
            (.init(body: Data(), announcedLength: AttachmentDownloadPolicy.automaticLimit + 1, headStatus: 501), .state(.tapToDownload(.size)), ["HEAD", "GET"]),
            (.init(body: Data(), announcedLength: AttachmentDownloadPolicy.hardLimit + 1, headStatus: 405), .state(.tooLarge), ["HEAD", "GET"]),
            // A missing file is not a refused HEAD.
            (.init(body: sealed.ciphertext, headStatus: 404), .state(.failed), ["HEAD"])
        ]
        for (index, item) in cases.enumerated() {
            let route = StubServer.serve(item.route)
            let destination = directory.appending(path: "\(index).jpg")
            let outcome = await downloader.download(attachment(declaring: 0, hash: Data(), url: route), secret: (sealed.key, sealed.iv),
                                                    automatic: true, knownSender: true, to: destination)
            XCTAssertEqual(outcome, item.expected, "case \(index)")
            XCTAssertEqual(StubServer.methods(route), item.methods, "case \(index)")
            XCTAssertEqual(try? Data(contentsOf: destination), item.expected == .saved ? plain : nil, "case \(index)")
            XCTAssertEqual(StubServer.delivered(route), item.expected == .saved ? sealed.ciphertext.count : 0, "case \(index)")
        }
    }

    func testAFileIsSavedOnlyOnceItAuthenticatesAndMatchesItsHash() async throws {
        let plain = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        let sealed = try AttachmentTransfer.seal(plain)
        var tampered = sealed.ciphertext
        tampered[100] ^= 1
        let cases: [(body: Data, secret: (key: Data, iv: Data)?, hash: Data, saved: Bool)] = [
            (sealed.ciphertext, (sealed.key, sealed.iv), Data.sha256(plain), true),
            (tampered, (sealed.key, sealed.iv), Data.sha256(plain), false),
            (sealed.ciphertext, (sealed.key, sealed.iv), Data.sha256(Data("other".utf8)), false),
            (plain, nil, Data.sha256(plain), true),
            (plain, nil, Data.sha256(Data("other".utf8)), false)
        ]
        for (index, item) in cases.enumerated() {
            let route = StubServer.serve(.init(body: item.body))
            let destination = directory.appending(path: "\(index).bin")
            let outcome = await downloader.download(attachment(declaring: plain.count, hash: item.hash, url: route), secret: item.secret,
                                                    automatic: true, knownSender: true, to: destination)
            XCTAssertEqual(outcome, item.saved ? .saved : .state(.failed), "case \(index)")
            XCTAssertEqual(try? Data(contentsOf: destination), item.saved ? plain : nil, "case \(index)")
        }
    }

    func testOversizedFilesAreNeverFetchedAndLargeOnesWaitForATap() {
        let oversized = AttachmentDownloadPolicy.bodyLength(declaredSize: AttachmentTransfer.maximumBytes + 1)
        XCTAssertEqual(AttachmentDownloadPolicy.decide(bodyLength: oversized, automatic: true, knownSender: false), .tooLarge)
        XCTAssertEqual(AttachmentDownloadPolicy.decide(bodyLength: oversized, automatic: false, knownSender: true), .tooLarge, "Not even on a tap")
        XCTAssertEqual(AttachmentDownloadPolicy.decide(bodyLength: AttachmentDownloadPolicy.automaticLimit + 1, automatic: true, knownSender: true), .hold(.size))
    }

    @MainActor
    func testAStrangersFilesWaitForATapUntilTheUserWrites() async throws {
        let (center, saved) = center()
        let sized = file(1), legacy = file(2, declaresSize: false)
        var messages = [incoming("m1", sized), incoming("m2", legacy)]
        center.load(messages, known: false, files: files, account: Self.account, onDisk: { saved.files[$0] != nil })
        XCTAssertEqual(center.states, ["m1": .tapToDownload(.sender), "m2": .tapToDownload(.sender)])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(StubServer.methods(sized.url) + StubServer.methods(legacy.url), [], "Nothing, not even a HEAD, reaches a stranger's host")

        messages.append(StoredMessage(id: "m3", accountID: Self.account, chatID: Self.peer, senderID: Self.account, body: "hi", isOutgoing: true))
        center.load(messages, known: false, files: files, account: Self.account, onDisk: { saved.files[$0] != nil })
        try await waitUntil { saved.files.count == 2 }
        XCTAssertEqual(center.states, [:])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.files["m1"])), sized.plain)
        XCTAssertEqual(StubServer.methods(legacy.url), ["HEAD", "GET"])
    }

    @MainActor
    func testAnOpenedChatDownloadsTwoAtATimeAndOlderFilesOnceSeen() async throws {
        let (center, saved) = center()
        let sent = Date()
        let items = (0..<12).map { index in (id: "m\(index)", file: file(index, pause: 20_000), sentAt: sent.addingTimeInterval(Double(index))) }
        let messages = items.map { incoming($0.id, $0.file, sentAt: $0.sentAt) } + [
            StoredMessage(id: "own", accountID: Self.account, chatID: Self.peer, senderID: Self.account, body: "hi", sentAt: sent, isOutgoing: true)
        ]
        center.load(messages, known: false, files: files, account: Self.account, onDisk: { saved.files[$0] != nil })
        // Leaving and reopening the chat joins the downloads already running instead of starting them again.
        center.reset()
        center.load(messages, known: false, files: files, account: Self.account, onDisk: { saved.files[$0] != nil })
        try await waitUntil { saved.files.count == 10 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Set(saved.files.keys), Set(items.suffix(10).map(\.id)), "The newest ten start on their own")
        XCTAssertEqual(StubServer.methods(items[0].file.url) + StubServer.methods(items[1].file.url), [], "Older files wait to be seen")
        XCTAssertEqual(center.states, ["m0": .loading, "m1": .loading])

        center.displayed("m1", attachment: messages[1].attachment, files: files)
        try await waitUntil { saved.files.count == 11 }
        XCTAssertEqual(center.states, ["m0": .loading])
        // At most two: whether the two slots overlapped in time depends on the load on the machine.
        XCTAssertLessThanOrEqual(StubServer.peakConcurrentBodies, 2)
        XCTAssertEqual(items.flatMap { StubServer.methods($0.file.url) }, Array(repeating: "GET", count: 11), "One request per file")
    }

    func testTheQueueRunsTwoAtATimeVisibleFirstThenNewestFirst() {
        var queue = AttachmentDownloadQueue(limit: 2)
        let now = Date()
        queue.add("old", messageID: "m1", order: now.addingTimeInterval(-300), visible: false)
        queue.add("older", messageID: "m0", order: now.addingTimeInterval(-600), visible: false)
        queue.add("new", messageID: "m3", order: now, visible: false)
        queue.add("shared", messageID: "m2", order: now.addingTimeInterval(-100), visible: false)
        queue.add("shared", messageID: "m2b", order: now.addingTimeInterval(-200), visible: false)
        queue.promote("older")
        XCTAssertEqual(queue.next(), "older", "A bubble on screen goes first")
        XCTAssertEqual(queue.next(), "new")
        XCTAssertNil(queue.next(), "Two at a time")
        queue.add("new", messageID: "m3b", order: now, visible: true)
        XCTAssertEqual(queue.finish("new"), ["m3", "m3b"], "A message with a running file joins its download")
        XCTAssertEqual(queue.next(), "shared")
        XCTAssertEqual(queue.finish("shared"), ["m2", "m2b"], "One download per file")
        queue.dropPending()
        XCTAssertNil(queue.next())
        XCTAssertEqual(queue.finish("older"), ["m0"])
    }

    private static let account = "me@localhost", peer = "peer@localhost"
    private var files: AttachmentFiles { AttachmentFiles(directory: directory, account: Self.account) }

    /// Files the center reported on disk, by message ID.
    @MainActor private final class Saved { var files: [String: URL] = [:] }

    @MainActor private func center() -> (AttachmentDownloadCenter, Saved) {
        let center = AttachmentDownloadCenter(configuration: configuration), saved = Saved()
        center.openSecret = { _ in nil }
        center.onFile = { _, ids, file in for id in ids { saved.files[id] = file } }
        return (center, saved)
    }

    /// A served, unencrypted file of 256 KiB whose bytes depend on `index`.
    private func file(_ index: Int, declaresSize: Bool = true, pause: useconds_t = 2_000) -> (plain: Data, url: URL, attachment: StoredAttachment) {
        let plain = Data(repeating: UInt8(index), count: 256 * 1024)
        let url = StubServer.serve(.init(body: plain, pause: pause))
        let stored = StoredAttachment(name: "\(index).bin", mediaType: "application/octet-stream", size: declaresSize ? plain.count : 0,
                                      hash: declaresSize ? Data.sha256(plain).hexString : "", secret: Data(), url: url.absoluteString)
        return (plain, url, stored)
    }

    private func incoming(_ id: String, _ file: (plain: Data, url: URL, attachment: StoredAttachment), sentAt: Date = Date()) -> StoredMessage {
        StoredMessage(id: id, accountID: Self.account, chatID: Self.peer, senderID: Self.peer, body: "", sentAt: sentAt, attachment: file.attachment)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func attachment(declaring size: Int, hash: Data, url: URL) -> StoredAttachment {
        StoredAttachment(name: "file.bin", mediaType: "application/octet-stream", size: size, hash: hash.hexString, secret: Data(), url: url.absoluteString)
    }

    private func secret() -> (key: Data, iv: Data) { (Data(repeating: 1, count: 32), Data(repeating: 2, count: 12)) }
}

/// An HTTPS server inside the test process. Each `serve` returns a fresh URL; the body is sent in 64 KiB chunks
/// with a pause between them, so a cancelled transfer visibly stops early and concurrent transfers overlap.
private final class StubServer: URLProtocol, @unchecked Sendable {
    enum Network: CustomStringConvertible {
        case unconstrained, constrained, expensive
        var description: String { "\(self == .unconstrained ? "normal" : self == .constrained ? "Low Data Mode" : "cellular")" }
    }
    struct Route {
        var body: Data
        var announcedLength: Int?
        var announcesLength = true
        var network = Network.unconstrained
        var headStatus = 200
        /// Microseconds before each chunk.
        var pause: useconds_t = 2_000
        init(body: Data, announcedLength: Int? = nil, announcesLength: Bool = true, headStatus: Int = 200, network: Network = .unconstrained,
             pause: useconds_t = 2_000) {
            self.body = body; self.announcedLength = announcedLength; self.announcesLength = announcesLength; self.network = network
            self.headStatus = headStatus; self.pause = pause
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var sent: [String: Int] = [:]
    nonisolated(unsafe) private static var requests: [String: [String]] = [:]
    nonisolated(unsafe) private static var sending = 0, peakSending = 0
    private let stopped = NSLock()
    nonisolated(unsafe) private var isStopped = false

    static func serve(_ route: Route) -> URL {
        let path = "/" + UUID().uuidString
        lock.withLock { routes[path] = route }
        return URL(string: "https://files.test" + path)!
    }
    static func delivered(_ url: URL) -> Int { lock.withLock { sent[url.path, default: 0] } }
    static func methods(_ url: URL) -> [String] { lock.withLock { requests[url.path, default: []] } }
    /// The most bodies that were being sent at once.
    static var peakConcurrentBodies: Int { lock.withLock { peakSending } }
    static func reset() { lock.withLock { routes = [:]; sent = [:]; requests = [:]; sending = 0; peakSending = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "files.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        guard let route = Self.lock.withLock({ () -> Route? in Self.requests[path, default: []].append(method); return Self.routes[path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        let refusal: URLError.NetworkUnavailableReason? = switch route.network {
        case .constrained where !request.allowsConstrainedNetworkAccess: .constrained
        case .expensive where !request.allowsExpensiveNetworkAccess: .expensive
        default: nil
        }
        if let refusal {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet, userInfo: [NSURLErrorNetworkUnavailableReasonKey: refusal.rawValue]))
            return
        }
        var headers = [String: String]()
        if route.announcesLength { headers["Content-Length"] = String(route.announcedLength ?? route.body.count) }
        let status = method == "HEAD" ? route.headStatus : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard method == "GET" else { client?.urlProtocolDidFinishLoading(self); return }
        Self.lock.withLock { Self.sending += 1; Self.peakSending = max(Self.peakSending, Self.sending) }
        DispatchQueue.global().async { [self] in
            defer { Self.lock.withLock { Self.sending -= 1 } }
            var offset = 0
            while offset < route.body.count {
                usleep(route.pause)
                guard !stopped.withLock({ isStopped }) else { return }
                let chunk = route.body.subdata(in: offset..<min(route.body.count, offset + 64 * 1024))
                offset += chunk.count
                Self.lock.withLock { Self.sent[path, default: 0] += chunk.count }
                client?.urlProtocol(self, didLoad: chunk)
            }
            guard !stopped.withLock({ isStopped }) else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { stopped.withLock { isStopped = true } }
}

