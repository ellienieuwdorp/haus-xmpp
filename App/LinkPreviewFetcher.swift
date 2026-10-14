import Foundation
import XMPPProtocol

// Our own bounded OpenGraph fetcher (docs/development/link-previews.md, Fetcher). App only: neither notification
// extension compiles it, so a push never fetches. LinkPresentation is not used: measured, it reaches loopback and
// private hosts, follows redirects without a hook, downloads whole direct files and ignores its own timeout.

/// What a fetch found: card text already cleaned and shortened to what we may send, and the page's image
/// downsampled. Has a title or an image.
struct LinkPreviewPage: Sendable, Equatable {
    var title: String?
    /// `og:description`, else `<meta name=description>`.
    var summary: String?
    /// `og:image:alt`; nil without an image.
    var imageAlt: String?
    var image: LinkPreviewImage?
}

enum LinkPreviewFetchFailure: Error, Equatable {
    /// Not https on port 443, or a user name in it (`LinkDetection.isFetchable`).
    case notFetchable
    /// The host, or an address it resolved or connected to, is one a preview never reaches.
    case refusedDestination
    case tooManyRedirects
    /// Not a 2xx answer, or a body that is neither a page nor an image.
    case badResponse
    case tooLarge
    case timedOut
    /// The page had no title and no usable image.
    case nothingToShow
    case cancelled
    /// The transport failed (no network, TLS, DNS).
    case network
}

/// Resolves a host name to the addresses a connection could use. The fetcher checks every one before it connects.
protocol HostResolving: Sendable {
    /// Every address of `host`, IPv4 as 4 bytes and IPv6 as 16. Empty or throwing refuses the fetch.
    func addresses(of host: String) async throws -> [[UInt8]]
}

/// `getaddrinfo`, run off the caller's thread. The fetcher's own deadline bounds a slow resolver.
struct SystemHostResolver: HostResolving {
    func addresses(of host: String) async throws -> [[UInt8]] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else {
                    continuation.resume(throwing: LinkPreviewFetchFailure.network)
                    return
                }
                defer { freeaddrinfo(first) }
                var found: [[UInt8]] = []
                var next: UnsafeMutablePointer<addrinfo>? = first
                while let entry = next {
                    if let address = entry.pointee.ai_addr {
                        if entry.pointee.ai_family == AF_INET {
                            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                                var raw = $0.pointee.sin_addr
                                found.append(withUnsafeBytes(of: &raw) { Array($0) })
                            }
                        } else if entry.pointee.ai_family == AF_INET6 {
                            address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                                var raw = $0.pointee.sin6_addr
                                found.append(withUnsafeBytes(of: &raw) { Array($0) })
                            }
                        }
                    }
                    next = entry.pointee.ai_next
                }
                continuation.resume(returning: found)
            }
        }
    }
}

/// Which hosts and addresses a preview fetch may reach: public unicast only.
enum LinkPreviewDestination {
    /// Names refused before resolving: `localhost`, `.localhost`, `.local`, `.home.arpa` and single-label names.
    /// `host` is without brackets and may end in a dot.
    static func isAllowedName(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.contains("."), name != "localhost" else { return false }
        return ![".localhost", ".local", ".home.arpa"].contains { name.hasSuffix($0) }
    }

    /// The bytes of an IPv4 or IPv6 literal (`192.0.2.1`, `::1`, `[::1]`, `fe80::1%en0`); nil for a name.
    static func literal(_ text: String) -> [UInt8]? {
        var text = text
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// False for loopback, private, link-local, CGNAT, multicast, broadcast, unspecified, reserved, documentation and
    /// benchmarking addresses (cloud metadata at 169.254.169.254 among them), and for IPv6 forms that carry such an
    /// IPv4 address: IPv4-mapped, IPv4-compatible, NAT64 (`64:ff9b::/96`) and 6to4.
    static func isAllowed(_ address: [UInt8]) -> Bool {
        switch address.count {
        case 4: isAllowedV4(address)
        case 16: isAllowedV6(address)
        default: false
        }
    }

    private static func isAllowedV4(_ a: [UInt8]) -> Bool {
        switch (a[0], a[1], a[2]) {
        case (0, _, _), (10, _, _), (127, _, _): false
        case (100, 64...127, _): false // CGNAT
        case (169, 254, _): false // link-local, cloud metadata
        case (172, 16...31, _): false
        case (192, 0, 0), (192, 0, 2): false
        case (192, 88, 99): false // 6to4 relay anycast
        case (192, 168, _): false
        case (198, 18...19, _): false // benchmarking
        case (198, 51, 100), (203, 0, 113): false // documentation
        case (224..., _, _): false // multicast, reserved, broadcast
        default: true
        }
    }

    private static func isAllowedV6(_ a: [UInt8]) -> Bool {
        let prefix = a[0..<12]
        // ::/96: unspecified, loopback and the deprecated IPv4-compatible form.
        if prefix.allSatisfy({ $0 == 0 }) { return false }
        // ::ffff:0:0/96 IPv4-mapped and 64:ff9b::/96 NAT64: as reachable as the IPv4 address they carry.
        if prefix.elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]) || prefix.elementsEqual([0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) {
            return isAllowedV4(Array(a[12..<16]))
        }
        // 2002::/16 6to4 carries its IPv4 address in bytes 2-5.
        if a[0] == 0x20, a[1] == 0x02 { return isAllowedV4(Array(a[2..<6])) }
        if a[0] & 0xfe == 0xfc { return false } // fc00::/7 unique local
        if a[0] == 0xfe, a[1] & 0xc0 == 0x80 { return false } // fe80::/10 link-local
        if a[0] == 0xfe, a[1] & 0xc0 == 0xc0 { return false } // fec0::/10 deprecated site-local
        if a[0] == 0xff { return false } // multicast
        if a[0] == 0x20, a[1] == 0x01, a[2] == 0x0d, a[3] == 0xb8 { return false } // 2001:db8::/32 documentation
        return true
    }
}

/// Fetches a page's OpenGraph head, or a direct image, under fixed bounds: https on 443 only, every hop's host
/// resolved and checked before it is requested, at most 5 redirects, a page read only to `</head>`, `<body` or
/// 512 KiB, an image at most 5 MiB and 40 megapixels, 10 seconds in all. No cookies, cache or credentials.
final class LinkPreviewFetcher: Sendable {
    struct Limits: Sendable {
        var pageBytes = 512 * 1024
        var imageBytes = 5 * 1024 * 1024
        var imagePixels = 40_000_000
        /// The longest side of the image kept on disk.
        var imageSide = 1024
        var redirects = 5
        var total: Duration = .seconds(10)
    }

    /// Names no product and no version, so a page cannot tell which app (or which build) asked.
    static let userAgent = "Mozilla/5.0 (compatible; link preview)"

    private let session: URLSession
    private let resolver: any HostResolving
    let limits: Limits

    init(configuration: URLSessionConfiguration = .ephemeral, resolver: any HostResolving = SystemHostResolver(), limits: Limits = Limits()) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = limits.total.timeInterval
        configuration.timeoutIntervalForResource = limits.total.timeInterval
        session = URLSession(configuration: configuration)
        self.resolver = resolver
        self.limits = limits
    }

    /// The preview of `url`, a link exactly as `LinkDetection` reports it.
    func fetch(_ url: URL) async throws(LinkPreviewFetchFailure) -> LinkPreviewPage {
        let deadline = ContinuousClock.now + limits.total
        guard LinkDetection.isFetchable(url) else { throw .notFetchable }
        let first = try await load(url, imageOnly: false, deadline: deadline)
        var page: LinkPreviewPage
        switch first.kind {
        case .image:
            page = LinkPreviewPage(title: Self.fileTitle(of: url))
            page.image = LinkPreviewImaging.downsample(first.body, maximumPixels: limits.imagePixels, side: limits.imageSide)
        case .page:
            let head = LinkPreviewHead.parse(first.body, charset: first.charset)
            page = LinkPreviewPage(title: head.title.flatMap { Self.shorten($0, characters: 200, bytes: 512) },
                                   summary: head.description.flatMap { Self.shorten($0, characters: 300, bytes: 1_024) })
            // A missing, oversized or refused image leaves a text card.
            if let source = head.image, let imageURL = URL(string: source, relativeTo: first.finalURL)?.absoluteURL,
               LinkDetection.isFetchable(imageURL) {
                do {
                    let image = try await load(imageURL, imageOnly: true, deadline: deadline)
                    page.image = LinkPreviewImaging.downsample(image.body, maximumPixels: limits.imagePixels, side: limits.imageSide)
                } catch {
                    if error == .cancelled { throw .cancelled }
                }
                if page.image != nil { page.imageAlt = head.imageAlt.flatMap { Self.shorten($0, characters: 200, bytes: 512) } }
            }
        }
        guard page.title != nil || page.image != nil else { throw .nothingToShow }
        return page
    }

    // MARK: Loading

    struct Loaded: Sendable {
        enum Kind: Sendable { case page, image }
        let kind: Kind
        let body: Data
        let charset: String?
        let finalURL: URL
    }

    /// One GET under the destination rules, following checked redirects. `imageOnly` accepts only an image answer.
    private func load(_ url: URL, imageOnly: Bool, deadline: ContinuousClock.Instant) async throws(LinkPreviewFetchFailure) -> Loaded {
        try await checkDestination(url, deadline: deadline)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: max(0.1, (deadline - .now).timeInterval))
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(imageOnly ? "image/*" : "text/html,application/xhtml+xml,image/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(Bundle.main.preferredLocalizations.first ?? "en", forHTTPHeaderField: "Accept-Language")
        let task = session.dataTask(with: request)
        let load = BoundedLoad(fetcher: self, imageOnly: imageOnly, deadline: deadline)
        task.delegate = load
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in load.start(task, continuation: continuation) }
            } onCancel: {
                load.finish(.failure(.cancelled))
            }
        } catch let failure as LinkPreviewFetchFailure {
            throw failure
        } catch {
            throw .network
        }
    }

    /// The scheme, port and name rules, then every resolved address. Runs before the first request and every redirect.
    fileprivate func checkDestination(_ url: URL, deadline: ContinuousClock.Instant) async throws(LinkPreviewFetchFailure) {
        guard LinkDetection.isFetchable(url), let host = url.host(percentEncoded: true) else { throw .notFetchable }
        if let literal = LinkPreviewDestination.literal(host) {
            guard LinkPreviewDestination.isAllowed(literal) else { throw .refusedDestination }
            return
        }
        guard LinkPreviewDestination.isAllowedName(host) else { throw .refusedDestination }
        let resolver = resolver
        let addresses: [[UInt8]]
        do {
            addresses = try await withThrowingTaskGroup(of: [[UInt8]]?.self) { group in
                group.addTask { try await resolver.addresses(of: host) }
                group.addTask { try await Task.sleep(until: deadline); return nil }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let found = first else { throw LinkPreviewFetchFailure.timedOut }
                return found
            }
        } catch is CancellationError {
            throw .cancelled
        } catch let failure as LinkPreviewFetchFailure {
            throw failure
        } catch {
            throw .network
        }
        guard !addresses.isEmpty, addresses.allSatisfy(LinkPreviewDestination.isAllowed) else { throw .refusedDestination }
    }

    fileprivate func cap(image: Bool) -> Int { image ? limits.imageBytes : limits.pageBytes }

    // MARK: Text

    /// Plain text (`LinkMetadata.plainText`) of at most `characters` characters and `bytes` UTF-8 bytes, cut at a
    /// character with an ellipsis.
    static func shorten(_ text: String, characters: Int, bytes: Int) -> String? {
        guard let text = MessageContent.LinkMetadata.plainText(text) else { return nil }
        if text.count <= characters, text.utf8.count <= bytes { return text }
        var result = ""
        var count = 0, used = 3 // the ellipsis
        for character in text {
            let size = character.utf8.count
            guard count + 1 < characters, used + size <= bytes else { break }
            result.append(character)
            count += 1
            used += size
        }
        return result.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A direct image's card title: the last path component, percent-decoded.
    static func fileTitle(of url: URL) -> String? {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return shorten(name.removingPercentEncoding ?? name, characters: 200, bytes: 512)
    }
}

/// One request's delegate: checks each redirect hop, streams the body against its cap (a page stops at `</head>`
/// or `<body`), checks the addresses the connections actually used, and enforces the fetch's deadline by
/// cancelling. The session's serial delegate queue runs the callbacks one at a time; the outcome is under the lock.
private final class BoundedLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let fetcher: LinkPreviewFetcher
    private let imageOnly: Bool
    private let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LinkPreviewFetcher.Loaded, any Error>?
    private var outcome: Result<LinkPreviewFetcher.Loaded, LinkPreviewFetchFailure>?
    private var task: URLSessionDataTask?
    private var timer: Task<Void, Never>?
    // Delegate queue only.
    private var redirects = 0
    private var kind = LinkPreviewFetcher.Loaded.Kind.page
    private var charset: String?
    private var finalURL: URL?
    private var body = Data()
    /// Set once a page's head is in; the cancellation that follows is not a failure.
    private var complete = false
    private var failure: LinkPreviewFetchFailure?
    private var refusedAddress = false
    private var metricsArrived = false
    private var taskEnded = false

    init(fetcher: LinkPreviewFetcher, imageOnly: Bool, deadline: ContinuousClock.Instant) {
        self.fetcher = fetcher; self.imageOnly = imageOnly; self.deadline = deadline
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<LinkPreviewFetcher.Loaded, any Error>) {
        let early = lock.withLock { () -> Result<LinkPreviewFetcher.Loaded, LinkPreviewFetchFailure>? in
            if let outcome { return outcome }
            self.continuation = continuation
            self.task = task
            return nil
        }
        if let early {
            task.cancel()
            continuation.resume(with: early.mapError { $0 as any Error })
            return
        }
        let deadline = deadline
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(.timedOut))
        }
        lock.withLock { self.timer = timer }
        task.resume()
    }

    /// Resumes the caller once; cancels the transfer and the timer.
    func finish(_ result: Result<LinkPreviewFetcher.Loaded, LinkPreviewFetchFailure>) {
        let (continuation, task, timer) = lock.withLock {
            () -> (CheckedContinuation<LinkPreviewFetcher.Loaded, any Error>?, URLSessionDataTask?, Task<Void, Never>?) in
            guard outcome == nil else { return (nil, nil, nil) }
            outcome = result
            defer { self.continuation = nil; self.task = nil; self.timer = nil }
            return (self.continuation, self.task, self.timer)
        }
        timer?.cancel()
        task?.cancel()
        continuation?.resume(with: result.mapError { $0 as any Error })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= fetcher.limits.redirects, let url = request.url else {
            completionHandler(nil)
            finish(.failure(.tooManyRedirects))
            return
        }
        var next = request
        next.httpShouldHandleCookies = false
        let fetcher = fetcher, deadline = deadline
        Task { [weak self] in
            do throws(LinkPreviewFetchFailure) {
                try await fetcher.checkDestination(url, deadline: deadline)
                completionHandler(next)
            } catch {
                completionHandler(nil)
                self?.finish(.failure(error))
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            failure = .badResponse
            completionHandler(.cancel)
            return
        }
        let type = (http.mimeType ?? "").lowercased()
        if type.hasPrefix("image/") {
            kind = .image
        } else if !imageOnly, type == "text/html" || type == "application/xhtml+xml" {
            kind = .page
        } else {
            failure = .badResponse
            completionHandler(.cancel)
            return
        }
        // An image announced above its cap is refused before its body; a page is read only to its cap anyway.
        if kind == .image, http.expectedContentLength > fetcher.cap(image: true) {
            failure = .tooLarge
            completionHandler(.cancel)
            return
        }
        charset = http.textEncodingName
        finalURL = http.url
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, !complete else { return }
        let cap = fetcher.cap(image: kind == .image)
        if kind == .image {
            guard body.count + data.count <= cap else {
                failure = .tooLarge
                dataTask.cancel()
                return
            }
            body.append(data)
            return
        }
        let searchFrom = max(0, body.count - 6)
        body.append(data.prefix(cap - body.count))
        if body.count >= cap || LinkPreviewHead.endsHead(body, from: searchFrom) {
            complete = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // A name that resolved to public addresses for our check but connected elsewhere (a DNS rebinding): the
        // request went out, but nothing it returned is used. No address (a proxy, an in-process loader) passes.
        for transaction in metrics.transactionMetrics {
            guard let address = transaction.remoteAddress else { continue }
            if !(LinkPreviewDestination.literal(address).map(LinkPreviewDestination.isAllowed) ?? false) { refusedAddress = true }
        }
        metricsArrived = true
        settleIfDone()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error, !complete, failure == nil {
            switch (error as? URLError)?.code {
            case .timedOut?: failure = .timedOut
            case .cancelled?: failure = .cancelled
            default: failure = .network
            }
        }
        taskEnded = true
        settleIfDone()
    }

    /// Both the completion and the metrics are in (their order is not documented); the deadline covers a missing one.
    private func settleIfDone() {
        guard taskEnded, metricsArrived else { return }
        if refusedAddress { finish(.failure(.refusedDestination)); return }
        if let failure { finish(.failure(failure)); return }
        guard let finalURL else { finish(.failure(.badResponse)); return }
        finish(.success(LinkPreviewFetcher.Loaded(kind: kind, body: body, charset: charset, finalURL: finalURL)))
    }
}

private extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
