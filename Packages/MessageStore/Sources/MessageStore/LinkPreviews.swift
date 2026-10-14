import Foundation

/// The preview a message carries: the XEP-0511 metadata an authenticated sender attached (`sender`), or the preview we
/// froze into our own outgoing message when it was queued (`own`), so a retry re-seals the same bytes and our bubble
/// shows what the peer got. Kept with the message and never expires; a retraction removes it. Our own fetches for
/// links in other messages live in the fetch cache (`LinkPreviewCacheEntry`) instead.
public struct StoredLinkPreview: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable { case sender, own }

    /// The described link exactly as detected in the body (`rdf:about`): http or https.
    public var url: String
    public var title: String?
    /// `og:description`.
    public var summary: String?
    /// An embedded image only (never a remote URL). Bounds are the wire's (`MessageContent.LinkMetadata`).
    public var imageData: Data?
    /// The embedded image's media type, for example `image/jpeg`; set exactly when `imageData` is.
    public var imageType: String?
    /// `og:image:alt`.
    public var imageAlt: String?
    public var source: Source

    public init(url: String, title: String? = nil, summary: String? = nil, imageData: Data? = nil, imageType: String? = nil,
                imageAlt: String? = nil, source: Source) {
        self.url = url; self.title = title; self.summary = summary; self.imageData = imageData; self.imageType = imageType
        self.imageAlt = imageAlt; self.source = source
    }
}

/// One result of our own fetch, per account and link (`LinkDetection.cacheKey`). The image is a downsampled file the
/// app wrote under the account's attachment folder; the store keeps only its path.
public struct LinkPreviewCacheEntry: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The page gave a title or an image.
        case ok
        /// The fetch failed, was refused by policy after it started, or the page had nothing to show.
        case failed
    }

    public var accountID: String
    /// `LinkDetection.cacheKey(for:)` of the fetched link.
    public var url: String
    public var fetchedAt: Date
    public var status: Status
    public var title: String?
    public var summary: String?
    public var imageAlt: String?
    /// Relative to the account's attachment folder, under `link-previews/`; nil without an image.
    public var imagePath: String?
    /// Pixel size of the file at `imagePath`, so the card's layout is known before the image is read.
    public var imageWidth: Int?
    public var imageHeight: Int?

    /// How long a result is reused before a newly displayed message with the same link fetches again.
    public static let successLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let failureLifetime: TimeInterval = 24 * 60 * 60

    public init(accountID: String, url: String, fetchedAt: Date, status: Status, title: String? = nil, summary: String? = nil,
                imageAlt: String? = nil, imagePath: String? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil) {
        self.accountID = accountID; self.url = url; self.fetchedAt = fetchedAt; self.status = status; self.title = title
        self.summary = summary; self.imageAlt = imageAlt; self.imagePath = imagePath; self.imageWidth = imageWidth; self.imageHeight = imageHeight
    }

    /// Whether this result still stands at `date` instead of a new fetch.
    public func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(fetchedAt)
        return age >= 0 && age < (status == .ok ? Self.successLifetime : Self.failureLifetime)
    }
}

/// The fetch cache the app's preview center reads and writes. `MessageStore` implements it (schema 26,
/// `link_preview_cache`); the app alone writes it, never a notification extension. Image files are the caller's:
/// methods that remove rows return the image paths that were in them, for the caller to delete.
public protocol LinkPreviewCaching: Sendable {
    /// The entry for `url` (a `LinkDetection.cacheKey`), fresh or not; nil when there is none.
    func linkPreviewCacheEntry(accountID: String, url: String) async throws -> LinkPreviewCacheEntry?
    /// Inserts or replaces the entry for its account and URL. Returns the image path of the replaced entry when the
    /// new one no longer uses it.
    @discardableResult func saveLinkPreviewCacheEntry(_ entry: LinkPreviewCacheEntry) async throws -> String?
    /// Removes entries fetched before `date`, then the oldest beyond `keeping` for the account.
    func pruneLinkPreviewCache(accountID: String, fetchedBefore date: Date, keeping: Int) async throws -> [String]
    /// Removes every entry of the account (sign-out, account removal, "Clear cache").
    func deleteLinkPreviewCache(accountID: String) async throws -> [String]
}
