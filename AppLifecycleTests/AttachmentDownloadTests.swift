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
    private var downloader: AttachmentDownloader!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "AttachmentDownloadTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        downloader = AttachmentDownloader(configuration: configuration)
    }

    override func tearDownWithError() throws {
        StubServer.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testABodyLongerThanTheDeclaredSizeIsCancelledAndNothingIsSaved() async throws {
        let plain = Data(repeating: 7, count: 1_000)
        let route = StubServer.serve(.init(body: Data(repeating: 7, count: 8 * 1024 * 1024), announcesLength: false))
        let destination = directory.appending(path: "file.bin")
        let outcome = await downloader.download(attachment(declaring: plain.count, hash: Data.sha256(plain), url: route), secret: nil,
                                                automatic: true, knownSender: true, to: destination)
        XCTAssertEqual(outcome, .state(.failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertLessThan(StubServer.delivered(route), 1024 * 1024, "The transfer stops near the cap, not at the end of the body")
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

    func testStrangersAndOversizedFilesAreNeverFetchedOnSight() {
        let oversized = AttachmentDownloadPolicy.bodyLength(declaredSize: AttachmentTransfer.maximumBytes + 1)
        XCTAssertEqual(AttachmentDownloadPolicy.decide(bodyLength: oversized, automatic: true, knownSender: false), .tooLarge)
        XCTAssertEqual(AttachmentDownloadPolicy.decide(bodyLength: oversized, automatic: false, knownSender: true), .tooLarge, "Not even on a tap")
        XCTAssertEqual(AttachmentDownloadPolicy.decide(bodyLength: 1_000, automatic: true, knownSender: false), .hold(.sender))
        XCTAssertEqual(AttachmentDownloadPolicy.decide(bodyLength: nil, automatic: true, knownSender: false), .hold(.sender), "Not even a HEAD")
        XCTAssertEqual(AttachmentDownloadPolicy.decide(bodyLength: AttachmentDownloadPolicy.automaticLimit + 1, automatic: true, knownSender: true), .hold(.size))
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

    private func attachment(declaring size: Int, hash: Data, url: URL) -> StoredAttachment {
        StoredAttachment(name: "file.bin", mediaType: "application/octet-stream", size: size, hash: hash.hexString, secret: Data(), url: url.absoluteString)
    }

    private func secret() -> (key: Data, iv: Data) { (Data(repeating: 1, count: 32), Data(repeating: 2, count: 12)) }
}

/// An HTTPS server inside the test process. Each `serve` returns a fresh URL; the body is sent in 64 KiB chunks
/// with a pause between them, so a cancelled transfer visibly stops early.
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
        init(body: Data, announcedLength: Int? = nil, announcesLength: Bool = true, network: Network = .unconstrained) {
            self.body = body; self.announcedLength = announcedLength; self.announcesLength = announcesLength; self.network = network
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var sent: [String: Int] = [:]
    nonisolated(unsafe) private static var requests: [String: [String]] = [:]
    private let stopped = NSLock()
    nonisolated(unsafe) private var isStopped = false

    static func serve(_ route: Route) -> URL {
        let path = "/" + UUID().uuidString
        lock.withLock { routes[path] = route }
        return URL(string: "https://files.test" + path)!
    }
    static func delivered(_ url: URL) -> Int { lock.withLock { sent[url.path, default: 0] } }
    static func methods(_ url: URL) -> [String] { lock.withLock { requests[url.path, default: []] } }
    static func reset() { lock.withLock { routes = [:]; sent = [:]; requests = [:] } }

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
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard method == "GET" else { client?.urlProtocolDidFinishLoading(self); return }
        DispatchQueue.global().async { [self] in
            var offset = 0
            while offset < route.body.count {
                usleep(2_000)
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

