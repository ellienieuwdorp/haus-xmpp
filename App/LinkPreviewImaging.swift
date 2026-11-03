import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Downsampled and re-encoded, so nothing of the original file (metadata, extra frames, size) is kept.
struct LinkPreviewImage: Sendable, Equatable {
    let data: Data
    let type: String
    let width: Int
    let height: Int

    var fileExtension: String { type == UTType.png.identifier ? "png" : "jpg" }
}

// ImageIO only: no UIKit or AppKit decoding of untrusted bytes at full size.
enum LinkPreviewImaging {
    static func downsample(_ data: Data, maximumPixels: Int, side: Int) -> LinkPreviewImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width.multipliedReportingOverflow(by: height).partialValue <= maximumPixels,
              !width.multipliedReportingOverflow(by: height).overflow,
              let image = thumbnail(source, side: side) else { return nil }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = opaque ? UTType.jpeg : UTType.png
        guard let encoded = encode(image, type: type, quality: 0.8) else { return nil }
        return LinkPreviewImage(data: encoded, type: type.identifier, width: image.width, height: image.height)
    }

    // Sent in the message as XEP-0511 `og:image`, a JPEG `data:` URI without metadata or transparency.
    static func sentThumbnail(from data: Data, maximumBytes: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        for side in [400, 256] {
            guard let fitted = thumbnail(source, side: side), let flat = flattened(fitted) else { continue }
            for quality in [0.7, 0.6, 0.5, 0.4] {
                if let jpeg = encode(flat, type: .jpeg, quality: quality), jpeg.count <= maximumBytes { return jpeg }
            }
        }
        return nil
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    private static func thumbnail(_ source: CGImageSource, side: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    // Transparency would turn black in a JPEG.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    // No properties are given, so no EXIF, GPS or other metadata is written.
    static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
