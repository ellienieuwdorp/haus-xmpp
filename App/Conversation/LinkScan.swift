import CryptoKit
import Foundation
import ImageIO
import XMPPProtocol

// NSDataDetector costs about 150 µs per short message and the presenter rebuilds every row on each update, so
// results are cached per text.
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

    static func links(in text: String) -> [DetectedLink] {
        guard !text.isEmpty else { return [] }
        let key = text as NSString
        if let hit = links.object(forKey: key) { return hit.value }
        let found = LinkDetection.links(in: text)
        links.setObject(Links(found), forKey: key)
        return found
    }

    static func previewableURLs(in text: String, uploadHosts: Set<String>) -> [URL] {
        guard !text.isEmpty else { return [] }
        let key = (uploadHosts.sorted().joined(separator: " ") + "\u{0}" + text) as NSString
        if let hit = previewable.object(forKey: key) { return hit.value }
        let found = LinkDetection.previewableURLs(in: text, uploadHosts: uploadHosts)
        previewable.setObject(URLs(found), forKey: key)
        return found
    }

    // Decoding inflates the whole canvas, and a 48 KB 1-bit PNG can declare 20,000 x 20,000 px. Embedded thumbnails are
    // ≤64 KiB and fetched images are downsampled to 1024 px, so 4 MP (16 MB as RGBA) fits any honest image.
    static let imagePixelBudget = 4_000_000

    // Keyed by the bytes' digest: a correction can replace an image under the same message ID.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        let cacheKey = digest(of: data) as NSString
        if let hit = sizes.object(forKey: cacheKey) { return hit.width > 0 ? (hit.width, hit.height) : nil }
        let size = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap(boundedSize(of:))
        sizes.setObject(PixelSize(width: size?.width ?? 0, height: size?.height ?? 0), forKey: cacheKey)
        return size
    }

    static func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard boundedSize(of: source) != nil else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary)
    }

    static func digest(of data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func boundedSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, case let (pixels, overflow) = width.multipliedReportingOverflow(by: height),
              !overflow, pixels <= imagePixelBudget else { return nil }
        // Orientations 5-8 turn the image a quarter.
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return turned ? (height, width) : (width, height)
    }
}
