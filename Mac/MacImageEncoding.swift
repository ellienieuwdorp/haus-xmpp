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
}
