import Foundation
import ImageIO
import UIKit

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

    static func save(_ data: Data, root: URL, account: String, hash: String) throws {
        let folder = directory(root: root, account: account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try data.write(to: folder.appending(path: hash), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A ≤256 px thumbnail decoded within the pixel budget; nil for anything ImageIO cannot bound.
    static func image(root: URL, account: String, hash: String) -> UIImage? {
        image(at: url(root: root, account: account, hash: hash))
    }

    static func image(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels, height <= maximumPixels else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}
