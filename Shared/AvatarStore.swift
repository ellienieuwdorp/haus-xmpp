import CoreGraphics
import Foundation
import ImageIO

// Nothing here trusts the bytes: ImageIO decodes within a pixel budget into a small thumbnail, never the full image.
enum AvatarStore {
    static let maximumPixels = 4_096
    static let thumbnailPixels = 256

    static func directory(root: URL, account: String) -> URL {
        // Percent-escaped rather than hashed: readable in Files and unique enough.
        let safe = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "account"
        return root.appending(path: "avatars/\(safe)", directoryHint: .isDirectory)
    }

    static func url(root: URL, account: String, hash: String) -> URL {
        directory(root: root, account: account).appending(path: hash)
    }

    // Whatever removes or leaves out an image names all of these files.
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

    // The app writes it; the notification extension only reads its bytes, so nothing decodes under the extension's
    // memory limit (nor uses `UIScreen`, which the filtering sandbox reportedly zeroes).
    static func notificationImageURL(root: URL, account: String, hash: String) -> URL {
        directory(root: root, account: account).appending(path: hash + ".notification.png")
    }

    static let maximumNotificationImageBytes = 300_000

    // Apple asks for share-sheet suggestion images of at least 360 px. Never read by the notification extension.
    static func suggestionImageURL(root: URL, account: String, hash: String) -> URL {
        directory(root: root, account: account).appending(path: hash + ".suggestion.png")
    }

    static let suggestionPixels = 384
    static let maximumSuggestionImageBytes = 700_000

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

    // Falls back to the notification copy for an avatar stored before the suggestion copy existed, or too large for it.
    static func suggestionImageData(root: URL, account: String, hash: String) -> Data? {
        guard isHash(hash) else { return nil }
        let url = suggestionImageURL(root: root, account: account, hash: hash)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 0, size <= maximumSuggestionImageBytes, let data = try? Data(contentsOf: url) { return data }
        return notificationImageData(root: root, account: account, hash: hash)
    }

    static func notificationImageData(root: URL, account: String, hash: String) -> Data? {
        guard isHash(hash) else { return nil }
        let url = notificationImageURL(root: root, account: account, hash: hash)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 0, size <= maximumNotificationImageBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func isHash(_ hash: String) -> Bool {
        hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // A `CGImage` so this file builds without UIKit.
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
