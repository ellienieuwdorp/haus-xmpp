import Foundation
import ImageIO
import XMPPProtocol

/// `LinkDetection` results kept per text. The presenter rebuilds every row on each view update and the cells ask again
/// on every configure, while `NSDataDetector` costs about 150 µs for a short message (measured on a Mac, 2026-10-14):
/// a 200-message window would spend 30 ms per update without this.
enum LinkScan {
    private final class Links: NSObject {
        let value: [DetectedLink]
        init(_ value: [DetectedLink]) { self.value = value }
    }

    private final class URLs: NSObject {
        let value: [URL]
        init(_ value: [URL]) { self.value = value }
    }

    private final class PixelSize: NSObject {
        let width: Int
        let height: Int
        init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    // NSCache is thread-safe; the annotation only tells the compiler so.
    nonisolated(unsafe) private static let links: NSCache<NSString, Links> = {
        let cache = NSCache<NSString, Links>()
        cache.countLimit = 2_000
        return cache
    }()
    nonisolated(unsafe) private static let previewable: NSCache<NSString, URLs> = {
        let cache = NSCache<NSString, URLs>()
        cache.countLimit = 2_000
        return cache
    }()
    nonisolated(unsafe) private static let sizes: NSCache<NSString, PixelSize> = {
        let cache = NSCache<NSString, PixelSize>()
        cache.countLimit = 500
        return cache
    }()

    /// `LinkDetection.links(in:)`.
    static func links(in text: String) -> [DetectedLink] {
        guard !text.isEmpty else { return [] }
        let key = text as NSString
        if let hit = links.object(forKey: key) { return hit.value }
        let found = LinkDetection.links(in: text)
        links.setObject(Links(found), forKey: key)
        return found
    }

    /// `LinkDetection.previewableURLs(in:uploadHosts:)`.
    static func previewableURLs(in text: String, uploadHosts: Set<String>) -> [URL] {
        guard !text.isEmpty else { return [] }
        let key = (uploadHosts.sorted().joined(separator: " ") + "\u{0}" + text) as NSString
        if let hit = previewable.object(forKey: key) { return hit.value }
        let found = LinkDetection.previewableURLs(in: text, uploadHosts: uploadHosts)
        previewable.setObject(URLs(found), forKey: key)
        return found
    }

    /// Pixel size of an embedded preview image as it displays (EXIF orientation applied), read from its header without
    /// decoding it. `key` names the bytes (a message ID) so the header is read once.
    static func pixelSize(of data: Data, key: String) -> (width: Int, height: Int)? {
        let cacheKey = "\(key)\u{0}\(data.count)" as NSString
        if let hit = sizes.object(forKey: cacheKey) { return (hit.width, hit.height) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Orientations 5-8 turn the image a quarter.
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let size = turned ? (height, width) : (width, height)
        sizes.setObject(PixelSize(width: size.0, height: size.1), forKey: cacheKey)
        return size
    }
}
