import CoreGraphics
import Foundation
import ImageIO

/// Verified avatar bytes as files under the shared Messaging directory, one folder per account,
/// named by their SHA-1. Nothing here trusts the bytes: decoding goes through ImageIO with a
/// pixel budget and produces a small thumbnail, never the full image.
enum AvatarStore {
    static let maximumPixels = 4_096
    static let thumbnailPixels = 256

    static func directory(root: URL, account: String) -> URL {
        // ponytail: the account JID is percent-escaped rather than hashed; readable in Files and unique enough.
        let safe = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "account"
        return root.appending(path: "avatars/\(safe)", directoryHint: .isDirectory)
    }

    static func url(root: URL, account: String, hash: String) -> URL {
        directory(root: root, account: account).appending(path: hash)
    }

    /// Every file kept for one stored image: the original and its pre-scaled copies. Whatever removes or leaves out an
    /// image names all of them.
    static func files(root: URL, account: String, hash: String) -> [URL] {
        [url(root: root, account: account, hash: hash), notificationImageURL(root: root, account: account, hash: hash),
         suggestionImageURL(root: root, account: account, hash: hash)]
    }

    static func save(_ data: Data, root: URL, account: String, hash: String) throws {
        let folder = directory(root: root, account: account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try data.write(to: folder.appending(path: hash), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The pre-scaled PNG a communication notification shows, beside the verified original. The app writes it; the
    /// notification extension only reads its bytes, so no image is decoded under the extension's memory limit (and no
    /// `UIScreen`, which the filtering sandbox reportedly zeroes, is involved).
    static func notificationImageURL(root: URL, account: String, hash: String) -> URL {
        directory(root: root, account: account).appending(path: hash + ".notification.png")
    }

    /// At most 256 px PNG: 256 × 256 × 4 bytes plus headers stays well under this.
    static let maximumNotificationImageBytes = 300_000

    /// The larger pre-scaled PNG an outgoing donation shows in share-sheet suggestions, which Apple asks to be at least
    /// 360 px. Read by the app and the share extension only, never by the notification extension.
    static func suggestionImageURL(root: URL, account: String, hash: String) -> URL {
        directory(root: root, account: account).appending(path: hash + ".suggestion.png")
    }

    static let suggestionPixels = 384
    /// At most 384 px PNG: 384 × 384 × 4 bytes plus headers stays under this.
    static let maximumSuggestionImageBytes = 700_000

    /// Writes the pre-scaled copies of a stored avatar once each; true when the notification copy exists afterwards.
    /// Called by the app only.
    @discardableResult
    static func saveNotificationImage(root: URL, account: String, hash: String) -> Bool {
        guard isHash(hash) else { return false }
        let original = url(root: root, account: account, hash: hash)
        saveScaledCopy(of: original, to: suggestionImageURL(root: root, account: account, hash: hash), pixels: suggestionPixels,
                       maximumBytes: maximumSuggestionImageBytes)
        return saveScaledCopy(of: original, to: notificationImageURL(root: root, account: account, hash: hash), pixels: thumbnailPixels,
                              maximumBytes: maximumNotificationImageBytes)
    }

    @discardableResult
    private static func saveScaledCopy(of original: URL, to target: URL, pixels: Int, maximumBytes: Int) -> Bool {
        if FileManager.default.fileExists(atPath: target.path) { return true }
        guard let image = image(at: original, pixels: pixels) else { return false }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= maximumBytes else { return false }
        return (try? (data as Data).write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    /// The suggestion copy's bytes, falling back to the notification copy for an avatar stored before it existed (or
    /// too large to keep at that size). Bounded and never decoded here.
    static func suggestionImageData(root: URL, account: String, hash: String) -> Data? {
        guard isHash(hash) else { return nil }
        let url = suggestionImageURL(root: root, account: account, hash: hash)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 0, size <= maximumSuggestionImageBytes, let data = try? Data(contentsOf: url) { return data }
        return notificationImageData(root: root, account: account, hash: hash)
    }

    /// The pre-scaled copy's bytes for the extension, or nil. Bounded and never decoded here.
    static func notificationImageData(root: URL, account: String, hash: String) -> Data? {
        guard isHash(hash) else { return nil }
        let url = notificationImageURL(root: root, account: account, hash: hash)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 0, size <= maximumNotificationImageBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Stored hashes are lowercase hex SHA-1; anything else never names a file.
    private static func isHash(_ hash: String) -> Bool {
        hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A ≤256 px thumbnail decoded within the pixel budget; nil for anything ImageIO cannot bound. A `CGImage` so this
    /// file builds without UIKit; callers wrap it in their platform's image type.
    static func image(root: URL, account: String, hash: String) -> CGImage? {
        image(at: url(root: root, account: account, hash: hash))
    }

    static func image(at url: URL, pixels: Int = thumbnailPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels, height <= maximumPixels else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
