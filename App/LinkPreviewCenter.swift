import CryptoKit
import Foundation
import MessageStore
import OSLog
import XMPPProtocol

// One fetch in flight per link, at most `concurrentFetches`, only in the foreground. The policy (setting, contact,
// demo) is the caller's; this only fetches what it is asked for.
@MainActor @Observable
final class LinkPreviewCenter {
    private(set) var results: [String: FetchedLinkPreview] = [:]
    @ObservationIgnored private(set) var account = ""
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var cache: (any LinkPreviewCaching)?
    @ObservationIgnored private let fetcher: LinkPreviewFetcher
    @ObservationIgnored private var isForeground = true
    // An unresolved name while offline is asked again later instead of standing as a failure for a day.
    @ObservationIgnored var hasNetwork = true
    @ObservationIgnored private var settled: Set<String> = []
    @ObservationIgnored private var unreachable: Set<String> = []
    @ObservationIgnored private var inFlight: [String: Task<FetchedLinkPreview?, Never>] = [:]
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var waiting: [CheckedContinuation<Bool, Never>] = []
    // Replaced on an account change and on leaving the foreground: work started before records nothing.
    @ObservationIgnored private var epoch = UUID()

    static let cacheEntries = 2_000
    static let concurrentFetches = 2
    nonisolated static let folderName = "link-previews"

    init(fetcher: LinkPreviewFetcher = LinkPreviewFetcher()) {
        self.fetcher = fetcher
    }

    // Any change drops what was published and stops the fetches; a nil cache fetches nothing.
    func use(account: String, folder: URL?, cache: (any LinkPreviewCaching)?) {
        guard account != self.account || folder != self.folder || !Self.same(cache, self.cache) else { return }
        self.cache = cache
        interrupt()
        self.account = account
        self.folder = folder
        results = [:]
        settled = []
        unreachable = []
    }

    // Leaving cancels fetches without recording them, so a link displayed after the return asks again.
    func setForeground(_ inFront: Bool) {
        guard inFront != isForeground else { return }
        isForeground = inFront
        if inFront { unreachable = [] } else { interrupt() }
    }

    func request(_ url: URL) { _ = start(url) }

    func preview(for url: URL) async -> FetchedLinkPreview? {
        if let known = results[LinkDetection.cacheKey(for: url)] { return known }
        return await start(url)?.value
    }

    private func start(_ url: URL) -> Task<FetchedLinkPreview?, Never>? {
        let key = LinkDetection.cacheKey(for: url)
        guard !account.isEmpty, cache != nil, results[key] == nil, !settled.contains(key), !unreachable.contains(key), LinkDetection.isFetchable(url) else { return nil }
        if let task = inFlight[key] { return task }
        guard isForeground else { return nil }
        let epoch = epoch
        let task = Task { [weak self] () -> FetchedLinkPreview? in
            guard let self else { return nil }
            let outcome = await self.resolve(url, key: key, epoch: epoch)
            guard self.epoch == epoch else { return nil }
            self.inFlight[key] = nil
            switch outcome {
            case .preview(let preview): self.results[key] = preview; return preview
            case .nothing: self.settled.insert(key)
            case .unreachable: self.unreachable.insert(key)
            case .interrupted: break
            }
            return nil
        }
        inFlight[key] = task
        return task
    }

    private enum Outcome { case preview(FetchedLinkPreview), nothing, unreachable, interrupted }

    private func resolve(_ url: URL, key: String, epoch: UUID) async -> Outcome {
        let account = account, folder = folder
        guard let cache else { return .interrupted }
        if let entry = try? await cache.linkPreviewCacheEntry(accountID: account, url: key), entry.isFresh(at: .now) {
            return entry.status == .ok ? .preview(Self.fetched(entry, folder: folder)) : .nothing
        }
        guard await acquireSlot() else { return .interrupted }
        defer { releaseSlot() }
        guard self.epoch == epoch else { return .interrupted }
        let result: Result<LinkPreviewPage, LinkPreviewFetchFailure>
        do { result = .success(try await fetcher.fetch(url)) } catch { result = .failure(error) }
        guard self.epoch == epoch else { return .interrupted }
        var entry = LinkPreviewCacheEntry(accountID: account, url: key, fetchedAt: .now, status: .failed)
        switch result {
        case .failure(.cancelled): return .interrupted
        // No connection: asked again after the next return. A dead name, refused connection or bad certificate
        // stands for a day.
        case .failure(.network): return .unreachable
        case .failure(.unresolved) where !hasNetwork: return .unreachable
        case .failure(let failure):
            Logger(subsystem: "haus.xmpp.ios", category: "link-previews").info("No preview: \(String(describing: failure), privacy: .public)")
        case .success(let page):
            entry.status = .ok
            entry.title = page.title
            entry.summary = page.summary
            if let image = page.image, let folder, let path = await Self.write(image, key: key, folder: folder) {
                entry.imagePath = path
                entry.imageAlt = page.imageAlt
                entry.imageWidth = image.width
                entry.imageHeight = image.height
            }
        }
        if let replaced = try? await cache.saveLinkPreviewCacheEntry(entry) { Self.remove([replaced], folder: folder) }
        if let pruned = try? await cache.pruneLinkPreviewCache(accountID: account, fetchedBefore: .now - LinkPreviewCacheEntry.successLifetime,
                                                               keeping: Self.cacheEntries) {
            Self.remove(pruned, folder: folder)
        }
        return entry.status == .ok ? .preview(Self.fetched(entry, folder: folder)) : .nothing
    }

    private static func same(_ a: (any LinkPreviewCaching)?, _ b: (any LinkPreviewCaching)?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject) === (b as AnyObject)
        default: false
        }
    }

    private func acquireSlot() async -> Bool {
        if running < Self.concurrentFetches { running += 1; return true }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseSlot() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume(returning: true) }
    }

    private func interrupt() {
        epoch = UUID()
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        let queued = waiting
        waiting = []
        for continuation in queued { continuation.resume(returning: false) }
    }

    // An image whose file is gone (a cleared cache) leaves a text card.
    static func fetched(_ entry: LinkPreviewCacheEntry, folder: URL?) -> FetchedLinkPreview {
        let file = entry.imagePath.flatMap { path in folder.map { $0.appending(path: path) } }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return FetchedLinkPreview(title: entry.title, summary: entry.summary, imageAlt: file == nil ? nil : entry.imageAlt, imageFile: file,
                                  imageWidth: file == nil ? nil : entry.imageWidth, imageHeight: file == nil ? nil : entry.imageHeight)
    }

    // Named by link and image digest, so cards' decoded-image caches, keyed by path, never show an old picture
    // after a refetch.
    private static func write(_ image: LinkPreviewImage, key: String, folder: URL) async -> String? {
        func hex(_ data: Data, _ bytes: Int) -> String { SHA256.hash(data: data).prefix(bytes).map { String(format: "%02x", $0) }.joined() }
        let path = folderName + "/" + hex(Data(key.utf8), 16) + "-" + hex(image.data, 8) + "." + image.fileExtension
        return await Task.detached(priority: .utility) { () -> String? in
            let directory = folder.appending(path: folderName, directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try image.data.write(to: folder.appending(path: path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return path
            } catch { return nil }
        }.value
    }

    private static func remove(_ paths: [String], folder: URL?) {
        guard let folder else { return }
        for path in paths where path.hasPrefix(folderName + "/") && !path.contains("..") {
            try? FileManager.default.removeItem(at: folder.appending(path: path))
        }
    }
}
