import ImageIO
import MessageStore
import UniformTypeIdentifiers
import XCTest
import XMPPProtocol
@testable import HausXMPP

/// The bounded fetcher and the fetch center through the real URLSession, with web servers replaced by an in-process
/// URLProtocol and DNS by a fixed table (docs/development/link-previews.md, Fetcher). Nothing leaves the process.
final class LinkPreviewFetchTests: XCTestCase {
    /// Public addresses (never contacted: the stub answers first).
    private static let publicV4: [UInt8] = [93, 184, 216, 34]
    private static let publicV6: [UInt8] = [0x26, 0x06, 0x28, 0, 0x02, 0x20, 0, 0x01, 0x02, 0x48, 0x18, 0x93, 0x25, 0xc8, 0x19, 0x46]

    private var resolver: TableResolver!
    private var configuration: URLSessionConfiguration!

    override func setUp() {
        resolver = TableResolver()
        configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewStubServer.self]
    }

    override func tearDown() { PreviewStubServer.reset() }

    private func fetcher(total: Duration = .seconds(10)) -> LinkPreviewFetcher {
        var limits = LinkPreviewFetcher.Limits()
        limits.total = total
        return LinkPreviewFetcher(configuration: configuration, resolver: resolver, limits: limits)
    }

    private func fetch(_ url: String, with fetcher: LinkPreviewFetcher? = nil) async -> Result<LinkPreviewPage, LinkPreviewFetchFailure> {
        do { return .success(try await (fetcher ?? self.fetcher()).fetch(URL(string: url)!)) } catch { return .failure(error) }
    }

    private func page(_ head: String, after: Int = 0) -> Data {
        Data(("<!doctype html><html><head>" + head + "</head><body>").utf8) + Data(repeating: UInt8(ascii: "x"), count: after)
    }

    // MARK: Reading

    /// The card's text and image come from the page's OpenGraph head, and nothing after the head is downloaded.
    func testReadsOpenGraphFromTheHeadAndStopsReadingThere() async throws {
        resolver.set("news.example", Self.publicV4)
        resolver.set("cdn.example", Self.publicV6)
        PreviewStubServer.serve("https://news.example/story", .page(page("""
            <meta charset="utf-8"><title>Fallback</title>
            <meta property="og:title" content="Council approves &amp; funds the new bridge">
            <meta property="og:description" content="Construction&#x20;starts
              in spring.">
            <meta property='og:image' content="/img/bridge.png"><meta property="og:image:alt" content="The bridge at dusk">
            <meta property="og:image" content="https://cdn.example/second.png">
            """, after: 4 * 1024 * 1024), pause: 5_000))
        PreviewStubServer.serve("https://news.example/img/bridge.png", .image(Self.png(width: 2_400, height: 1_260)))

        let result = await fetch("https://news.example/story")
        let page = try result.get()
        XCTAssertEqual(page.title, "Council approves & funds the new bridge")
        XCTAssertEqual(page.summary, "Construction starts in spring.")
        XCTAssertEqual(page.imageAlt, "The bridge at dusk")
        let image = try XCTUnwrap(page.image)
        XCTAssertEqual([image.width, image.height], [1_024, 538], "Downsampled to 1024 px on the long side")
        XCTAssertLessThan(PreviewStubServer.delivered("news.example"), 512 * 1024, "The body after </head> is not read")
        XCTAssertEqual(PreviewStubServer.requests(to: "cdn.example"), 0, "Only the first og:image is fetched")
        let headers = try XCTUnwrap(PreviewStubServer.headers("news.example").first)
        let agent = try XCTUnwrap(headers["User-Agent"])
        for revealing in ["Haus", "XMPP", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"] {
            XCTAssertFalse(agent.contains(revealing), "The user agent names no product or version: \(agent)")
        }
    }

    /// Without OpenGraph, `<title>` and `<meta name=description>` stand in; a page with neither and no image has no card.
    func testFallsBackToTitleAndDescriptionAndRefusesAnEmptyPage() async throws {
        resolver.set("plain.example", Self.publicV4)
        PreviewStubServer.serve("https://plain.example/a", .page(page("""
            <script>var s = "<meta property='og:title' content='not this'>";</script>
            <title>Caf&eacute; &#233;t&#xE9; &bogus; menu</title><meta name="description" content="Open daily">
            """)))
        PreviewStubServer.serve("https://plain.example/latin", .page(Data("<html><head><title>Caf".utf8) + Data([0xE9]) + Data(" cr".utf8) + Data([0xE8]) + Data("me</title></head>".utf8), charset: "iso-8859-1"))
        PreviewStubServer.serve("https://plain.example/empty", .page(page("<meta name=viewport content=width=device-width>")))

        let fallback = try await fetch("https://plain.example/a").get()
        XCTAssertEqual(fallback.title, "Café été &bogus; menu", "Script contents are not tags; an unknown entity stays as written")
        XCTAssertEqual(fallback.summary, "Open daily")
        let latin = try await fetch("https://plain.example/latin").get()
        XCTAssertEqual(latin.title, "Café crème", "The Content-Type charset decodes the page")
        let empty = await fetch("https://plain.example/empty")
        XCTAssertEqual(empty, .failure(.nothingToShow))
    }

    /// A direct image link gets a card with the downsampled image and its file name as the title.
    func testADirectImageGetsItsFileNameAsTitle() async throws {
        resolver.set("photos.example", Self.publicV4)
        PreviewStubServer.serve("https://photos.example/2026/harbour%20view.png", .image(Self.png(width: 800, height: 600)))
        let page = try await fetch("https://photos.example/2026/harbour%20view.png").get()
        XCTAssertEqual(page.title, "harbour view.png")
        XCTAssertEqual(page.image.map { [$0.width, $0.height] }, [800, 600])
    }

    // MARK: Network rules

    /// Plain http and any port but 443 are never requested, whatever the host.
    func testOnlyHTTPSOnPort443IsFetched() async {
        resolver.set("site.example", Self.publicV4)
        for url in ["http://site.example/", "https://site.example:8443/", "https://user@site.example/"] {
            let result = await fetch(url)
            XCTAssertEqual(result, .failure(.notFetchable), url)
        }
        XCTAssertEqual(PreviewStubServer.requests(to: "site.example"), 0)
    }

    /// Loopback, private, link-local, CGNAT, metadata and unique-local destinations, by name, by literal and by any
    /// one resolved address (IPv4, IPv6, IPv4-mapped or NAT64), are refused before a request goes out.
    func testPrivateDestinationsAreRefusedBeforeAnyRequest() async {
        let cases: [(url: String, resolves: [[UInt8]]?, line: UInt)] = [
            ("https://localhost/", nil, #line),
            ("https://printer.local/", nil, #line),
            ("https://nas.home.arpa/", nil, #line),
            ("https://intranet/", nil, #line),
            ("https://127.0.0.1/", nil, #line),
            ("https://[::1]/", nil, #line),
            ("https://169.254.169.254/latest/meta-data/", nil, #line),
            ("https://[fd12:3456::1]/", nil, #line),
            ("https://lan.example/", [[192, 168, 1, 10]], #line),
            ("https://ten.example/", [[10, 0, 0, 5]], #line),
            ("https://cgnat.example/", [[100, 64, 1, 1]], #line),
            ("https://mixed.example/", [Self.publicV4, [172, 16, 0, 1]], #line),
            ("https://mapped.example/", [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1]], #line),
            ("https://nat64.example/", [[0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 169, 254, 169, 254]], #line),
            ("https://linklocal.example/", [[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]], #line),
            ("https://multicast.example/", [[239, 1, 1, 1]], #line),
            ("https://nowhere.example/", [], #line),
        ]
        for (url, resolves, line) in cases {
            let host = URL(string: url)!.host()!
            if let resolves { resolver.set(host, resolves) }
            PreviewStubServer.serve(url, .page(page("<title>Inside</title>")))
            let result = await fetch(url)
            XCTAssertEqual(result, .failure(.refusedDestination), url, line: line)
            XCTAssertEqual(PreviewStubServer.requests(to: host), 0, url, line: line)
        }
        // The control: the same page on a public address is fetched.
        resolver.set("public.example", Self.publicV4)
        PreviewStubServer.serve("https://public.example/", .page(page("<title>Outside</title>")))
        let control = await fetch("https://public.example/")
        XCTAssertEqual(control.map(\.title), .success("Outside"))
    }

    /// After the transfer, the addresses the connections used are checked again (a DNS rebinding between our check
    /// and the connection): one private address discards the result. The stub server reports none, so the table runs
    /// on the check itself.
    func testAConnectionToAPrivateAddressDiscardsTheResult() {
        let cases: [(addresses: [String?], allowed: Bool, line: UInt)] = [
            ([nil], true, #line),
            (["93.184.216.34"], true, #line),
            (["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"], true, #line),
            (["127.0.0.1"], false, #line),
            (["93.184.216.34", "192.168.1.10"], false, #line),
            ([nil, "::1"], false, #line),
            (["::ffff:10.0.0.1"], false, #line),
            (["not an address"], false, #line),
        ]
        for (addresses, allowed, line) in cases {
            XCTAssertEqual(LinkPreviewDestination.allowsConnections(to: addresses), allowed, "\(addresses)", line: line)
        }
    }

    /// Every redirect hop is checked like the first request, and a sixth hop is refused.
    func testRedirectsAreCheckedAtEveryHopAndLimitedToFive() async throws {
        resolver.set("short.example", Self.publicV4)
        resolver.set("final.example", Self.publicV4)
        resolver.set("inside.example", [[10, 1, 2, 3]])
        PreviewStubServer.serve("https://inside.example/admin", .page(page("<title>Router admin</title>")))
        PreviewStubServer.serve("https://short.example/private", .redirect("https://inside.example/admin"))
        PreviewStubServer.serve("https://short.example/loopback", .redirect("https://127.0.0.1/"))
        PreviewStubServer.serve("https://short.example/http", .redirect("http://final.example/page"))
        PreviewStubServer.serve("https://final.example/page", .page(page("<title>Arrived</title>")))
        for hop in 1...6 {
            PreviewStubServer.serve("https://short.example/hop\(hop)", .redirect(hop == 6 ? "https://final.example/page" : "https://short.example/hop\(hop + 1)"))
        }

        let toPrivate = await fetch("https://short.example/private")
        XCTAssertEqual(toPrivate, .failure(.refusedDestination))
        let toLoopback = await fetch("https://short.example/loopback")
        XCTAssertEqual(toLoopback, .failure(.refusedDestination))
        XCTAssertEqual(PreviewStubServer.requests(to: "inside.example"), 0)
        let toHTTP = await fetch("https://short.example/http")
        XCTAssertEqual(toHTTP, .failure(.notFetchable))
        XCTAssertEqual(PreviewStubServer.requests(to: "final.example"), 0, "An http hop is not followed")

        let fiveHops = await fetch("https://short.example/hop2")
        XCTAssertEqual(fiveHops.map(\.title), .success("Arrived"))
        let sixHops = await fetch("https://short.example/hop1")
        XCTAssertEqual(sixHops, .failure(.tooManyRedirects))
    }

    /// Images are capped at 5 MiB (announced or counted) and 40 megapixels; an oversized page image leaves a text card.
    func testImageSizeCaps() async throws {
        resolver.set("img.example", Self.publicV4)
        let big = Data(repeating: 0, count: 5 * 1024 * 1024 + 1)
        PreviewStubServer.serve("https://img.example/announced.jpg", .image(big))
        PreviewStubServer.serve("https://img.example/unannounced.jpg", .image(big, announcesLength: false))
        PreviewStubServer.serve("https://img.example/huge.png", .image(Self.png(width: 8_000, height: 5_001)))
        PreviewStubServer.serve("https://img.example/article", .page(page(#"<meta property="og:title" content="Story"><meta property="og:image" content="/announced.jpg">"#)))

        let announced = await fetch("https://img.example/announced.jpg")
        XCTAssertEqual(announced, .failure(.tooLarge))
        let unannounced = await fetch("https://img.example/unannounced.jpg")
        XCTAssertEqual(unannounced, .failure(.tooLarge))
        XCTAssertLessThan(PreviewStubServer.delivered("img.example"), 2 * big.count, "Both transfers stop at the cap")
        // Over 40 megapixels: refused from the header, so the direct link has nothing to show but its name.
        let huge = try await fetch("https://img.example/huge.png").get()
        XCTAssertNil(huge.image)
        let article = try await fetch("https://img.example/article").get()
        XCTAssertEqual(article.title, "Story")
        XCTAssertNil(article.image)
    }

    /// A server that never answers ends the fetch at its deadline.
    func testAStalledServerEndsAtTheDeadline() async {
        resolver.set("slow.example", Self.publicV4)
        PreviewStubServer.serve("https://slow.example/", .stall)
        let started = ContinuousClock.now
        let result = await fetch("https://slow.example/", with: fetcher(total: .milliseconds(300)))
        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    // MARK: Center

    /// Displays of the same link share one request; distinct links run at most two at a time; a result stands for
    /// later displays (from the cache) without a new request.
    @MainActor func testTheCenterCoalescesLinksAndRunsTwoAtATime() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "LinkPreviewFetchTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = InMemoryLinkPreviewCache()
        let center = LinkPreviewCenter(fetcher: fetcher(), cache: cache)
        center.use(account: "me@example.org", folder: folder)
        for index in 0..<5 {
            resolver.set("site\(index).example", Self.publicV4)
            PreviewStubServer.serve("https://site\(index).example/", .page(page("<title>Site \(index)</title>"), pause: 50_000))
        }
        for _ in 0..<3 { center.request(URL(string: "https://site0.example/#top")!) }
        for index in 1..<5 { center.request(URL(string: "https://site\(index).example/")!) }
        try await waitUntil { center.results.count == 5 }
        XCTAssertEqual(PreviewStubServer.requests(to: "site0.example"), 1, "Same cache key, one request")
        XCTAssertLessThanOrEqual(PreviewStubServer.peakConcurrent, 2)
        XCTAssertEqual(center.results[LinkDetection.cacheKey(for: URL(string: "https://site0.example/")!)]?.title, "Site 0")

        // A relaunch (a new center over the same cache) reuses the fresh entry.
        let relaunched = LinkPreviewCenter(fetcher: fetcher(), cache: cache)
        relaunched.use(account: "me@example.org", folder: folder)
        let reused = await relaunched.preview(for: URL(string: "https://site1.example/")!)
        XCTAssertEqual(reused?.title, "Site 1")
        XCTAssertEqual(PreviewStubServer.requests(to: "site1.example"), 1)
    }

    /// A failure stands for a day, a success for a week; an expired entry is fetched again.
    @MainActor func testCachedResultsExpire() async throws {
        let cache = InMemoryLinkPreviewCache()
        resolver.set("fresh.example", Self.publicV4)
        resolver.set("stale.example", Self.publicV4)
        PreviewStubServer.serve("https://fresh.example/", .page(page("<title>New</title>")))
        PreviewStubServer.serve("https://stale.example/", .page(page("<title>New</title>")))
        await cache.saveLinkPreviewCacheEntry(LinkPreviewCacheEntry(accountID: "me@example.org", url: "https://fresh.example/",
                                                                         fetchedAt: .now - 20 * 60 * 60, status: .failed))
        await cache.saveLinkPreviewCacheEntry(LinkPreviewCacheEntry(accountID: "me@example.org", url: "https://stale.example/",
                                                                         fetchedAt: .now - 8 * 24 * 60 * 60, status: .ok, title: "Old"))
        let center = LinkPreviewCenter(fetcher: fetcher(), cache: cache)
        center.use(account: "me@example.org", folder: nil)
        let fresh = await center.preview(for: URL(string: "https://fresh.example/")!)
        let stale = await center.preview(for: URL(string: "https://stale.example/")!)
        XCTAssertNil(fresh)
        XCTAssertEqual(PreviewStubServer.requests(to: "fresh.example"), 0)
        XCTAssertEqual(stale?.title, "New")
    }

    /// Away from the foreground nothing is fetched, and a fetch cut short by leaving is not recorded as a failure.
    @MainActor func testTheCenterFetchesOnlyInFront() async throws {
        resolver.set("away.example", Self.publicV4)
        PreviewStubServer.serve("https://away.example/", .page(page("<title>Back</title>"), pause: 200_000))
        let center = LinkPreviewCenter(fetcher: fetcher(), cache: InMemoryLinkPreviewCache())
        center.use(account: "me@example.org", folder: nil)
        let url = URL(string: "https://away.example/")!

        center.setForeground(false)
        center.request(url)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(PreviewStubServer.requests(to: "away.example"), 0)

        center.setForeground(true)
        center.request(url)
        try await waitUntil { PreviewStubServer.requests(to: "away.example") == 1 }
        center.setForeground(false)
        center.setForeground(true)
        let again = await center.preview(for: url)
        XCTAssertEqual(again?.title, "Back", "The interrupted fetch left nothing behind")
    }

    /// Only a missing connection is asked again after a return to the foreground. A name that does not resolve while
    /// the device has a network, or a certificate that is not trusted, stands as a failure and is not requested again.
    @MainActor func testOnlyAMissingConnectionIsAskedAgain() async throws {
        let center = LinkPreviewCenter(fetcher: fetcher(), cache: InMemoryLinkPreviewCache())
        center.use(account: "me@example.org", folder: nil)
        resolver.set("offline.example", Self.publicV4)
        resolver.set("untrusted.example", Self.publicV4)
        PreviewStubServer.serve("https://offline.example/", .fail(.notConnectedToInternet))
        PreviewStubServer.serve("https://untrusted.example/", .fail(.serverCertificateUntrusted))
        let links = ["offline", "untrusted", "dead"].map { URL(string: "https://\($0).example/")! }
        for url in links {
            let preview = await center.preview(for: url)
            XCTAssertNil(preview, url.absoluteString)
        }

        for url in links {
            resolver.set(url.host()!, Self.publicV4)
            PreviewStubServer.serve(url.absoluteString, .page(page("<title>Up</title>")))
        }
        center.setForeground(false)
        center.setForeground(true)
        let titles = await [center.preview(for: links[0]), center.preview(for: links[1]), center.preview(for: links[2])].map { $0?.title }
        XCTAssertEqual(titles, ["Up", nil, nil])
        XCTAssertEqual(PreviewStubServer.requests(to: "untrusted.example"), 1)
        XCTAssertEqual(PreviewStubServer.requests(to: "dead.example"), 0)

        // Without a network, a name that does not resolve says nothing about the name.
        let offline = LinkPreviewCenter(fetcher: fetcher(), cache: InMemoryLinkPreviewCache())
        offline.use(account: "me@example.org", folder: nil)
        offline.hasNetwork = false
        let unknown = URL(string: "https://later.example/")!
        let first = await offline.preview(for: unknown)
        XCTAssertNil(first)
        resolver.set("later.example", Self.publicV4)
        PreviewStubServer.serve("https://later.example/", .page(page("<title>Later</title>")))
        offline.hasNetwork = true
        offline.setForeground(false)
        offline.setForeground(true)
        let again = await offline.preview(for: unknown)
        XCTAssertEqual(again?.title, "Later")
    }

    // MARK: Sent thumbnail

    /// What we send: a JPEG within 400 px and 24 KiB, without the source's metadata.
    func testTheSentThumbnailIsASmallJPEGWithoutMetadata() throws {
        let source = Self.noisyJPEG(width: 2_000, height: 1_500, gps: true)
        let thumbnail = try XCTUnwrap(LinkPreviewImaging.sentThumbnail(from: source, maximumBytes: MessageContent.LinkMetadata.maximumSentImageBytes))
        XCTAssertLessThanOrEqual(thumbnail.count, 24 * 1024)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(max(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, properties[kCGImagePropertyPixelHeight] as? Int ?? .max), 400)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
    }

    // MARK: Helpers

    @MainActor private func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return encode(context.makeImage()!, type: .png, properties: [:])
    }

    static func noisyJPEG(width: Int, height: Int, gps: Bool) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator), blue: .random(in: 0...1, using: &generator), alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let metadata: [CFString: Any] = gps ? [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.37, kCGImagePropertyGPSLongitude: 4.89],
                                               kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:14 12:00:00"]] : [:]
        return encode(context.makeImage()!, type: .jpeg, properties: metadata)
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

/// DNS for the tests: a fixed table; an unknown name does not resolve.
private final class TableResolver: HostResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [[UInt8]]] = [:]
    func set(_ host: String, _ addresses: [UInt8]...) { set(host, addresses) }
    func set(_ host: String, _ addresses: [[UInt8]]) { lock.withLock { table[host] = addresses } }
    func addresses(of host: String) async throws -> [[UInt8]] {
        guard let found = lock.withLock({ table[host] }) else { throw URLError(.cannotFindHost) }
        return found
    }
}

/// Web servers inside the test process, by URL. Bodies go out in 64 KiB chunks with a pause between them, so a
/// transfer cut short visibly stops early and concurrent transfers overlap.
private final class PreviewStubServer: URLProtocol, @unchecked Sendable {
    enum Route {
        case page(Data, charset: String = "utf-8", pause: useconds_t = 1_000)
        case image(Data, announcesLength: Bool = true)
        case redirect(String)
        /// Answers nothing until cancelled.
        case stall
        /// The transfer fails as URLSession reports it.
        case fail(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var sent: [String: Int] = [:]
    nonisolated(unsafe) private static var received: [String: [[String: String]]] = [:]
    nonisolated(unsafe) private static var active = 0, peak = 0
    private let stopped = NSLock()
    nonisolated(unsafe) private var isStopped = false

    static func serve(_ url: String, _ route: Route) { lock.withLock { routes[url] = route } }
    static func delivered(_ host: String) -> Int { lock.withLock { sent[host, default: 0] } }
    static func requests(to host: String) -> Int { lock.withLock { received[host]?.count ?? 0 } }
    static func headers(_ host: String) -> [[String: String]] { lock.withLock { received[host] ?? [] } }
    static var peakConcurrent: Int { lock.withLock { peak } }
    static func reset() { lock.withLock { routes = [:]; sent = [:]; received = [:]; active = 0; peak = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host()!
        // A fragment never reaches a server.
        var served = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        served.fragment = nil
        let route = Self.lock.withLock { () -> Route? in
            Self.received[host, default: []].append(request.allHTTPHeaderFields ?? [:])
            return Self.routes[served.string!]
        }
        guard let route else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        switch route {
        case .redirect(let location):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .stall:
            break
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .page(let body, let charset, let pause):
            send(body, headers: ["Content-Type": "text/html; charset=\(charset)", "Content-Length": String(body.count)], host: host, pause: pause)
        case .image(let body, let announces):
            var headers = ["Content-Type": "image/png"]
            if announces { headers["Content-Length"] = String(body.count) }
            send(body, headers: headers, host: host, pause: 500)
        }
    }

    private func send(_ body: Data, headers: [String: String], host: String, pause: useconds_t) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.lock.withLock { Self.active += 1; Self.peak = max(Self.peak, Self.active) }
        DispatchQueue.global().async { [self] in
            defer { Self.lock.withLock { Self.active -= 1 } }
            var offset = 0
            repeat {
                usleep(pause)
                guard !stopped.withLock({ isStopped }) else { return }
                let chunk = body.subdata(in: offset..<min(body.count, offset + 64 * 1024))
                offset += chunk.count
                Self.lock.withLock { Self.sent[host, default: 0] += chunk.count }
                client?.urlProtocol(self, didLoad: chunk)
            } while offset < body.count
            guard !stopped.withLock({ isStopped }) else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { stopped.withLock { isStopped = true } }
}
