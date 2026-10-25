import AVFoundation
import Foundation
import ImageIO
import MessagingCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Bounded decoding for bubbles: the thumbnail pass never inflates the full image.
enum AttachmentThumbnails {
    // NSCache is thread-safe; the annotation only tells the compiler so.
    nonisolated(unsafe) private static let cache = NSCache<NSString, PlatformImage>()

    /// Synchronous hit, so a reconfigured cell never blanks an image it already showed.
    static func cached(for url: URL) -> PlatformImage? { cache.object(forKey: url.path as NSString) }

    static func image(for url: URL, mediaType: String, maxPixels: Int = 1024) async -> PlatformImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: PlatformImage? = await Task.detached(priority: .userInitiated) {
            if mediaType.hasPrefix("image/") {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
                return PlatformImage(cgImage: cg)
            }
            if mediaType.hasPrefix("video/") {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
                guard let cg = try? await generator.image(at: .zero).image else { return nil }
                return PlatformImage(cgImage: cg)
            }
            return nil
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// A small still for the composer tray. The decoder reads files, so the bytes pass through a temporary one.
    static func preview(of prepared: PreparedAttachment) async -> PlatformImage? {
        guard prepared.mediaType.hasPrefix("image/") || prepared.mediaType.hasPrefix("video/") else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + (prepared.name as NSString).pathExtension)
        guard (try? prepared.data.write(to: url, options: .completeFileProtection)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let image = await image(for: url, mediaType: prepared.mediaType, maxPixels: 240)
        cache.removeObject(forKey: url.path as NSString)
        return image
    }
}
