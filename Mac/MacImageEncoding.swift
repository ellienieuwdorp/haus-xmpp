import AppKit
import ImageIO
import UniformTypeIdentifiers

/// JPEG encoding where iOS uses `UIImage.jpegData` and `UIGraphicsImageRenderer`.
enum MacImageEncoding {
    enum Failure: Error { case encoding }

    static func jpeg(_ image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.encoding }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        return data as Data
    }

    /// The sample photo of the demo data: a diagonal gradient, as the iPhone draws it.
    static func gradientJPEG(size: CGSize, colors: [CGColor]) throws -> Data {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil) else { throw Failure.encoding }
        // Bitmap contexts are y-up; start at the top left as UIKit's renderer does.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        guard let image = context.makeImage() else { throw Failure.encoding }
        return try jpeg(image, quality: 0.8)
    }
}
