import AVFoundation
import Foundation
import ImageIO
import MessagingCore
import OMEMO
import UniformTypeIdentifiers

/// Reduces a chosen file to what we are willing to upload: images are re-encoded as JPEG at ≤ 2048 px, video is exported
/// at 720p, everything else goes as is, each within `limit`. Shared by the apps and their share extensions, so nothing
/// here holds a whole file on the heap that it can read from disk instead: images are decoded from their file, and an
/// exported video or a plain file is memory-mapped, which keeps a large file out of an extension's memory budget until
/// it is sealed. The app's own pickers (photo library, camera) are in `Attachments.swift`.
enum AttachmentPreparer {
    enum Failure: LocalizedError {
        case tooLarge(limit: Int), unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge(let limit): "This file is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) this server accepts."
            case .unreadable: "This file could not be read."
            }
        }
    }
    static let maximumPixels = 2048
    static let jpegQuality = 0.85

    /// Images are re-encoded at ≤ 2048 px, video is exported at 720p, everything else goes as is.
    static func prepare(fileURL: URL, name: String, type: UTType?, limit: Int) async throws -> PreparedAttachment {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let type = type ?? UTType(filenameExtension: fileURL.pathExtension) ?? .data
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw Failure.unreadable }
            return try prepareImage(source, name: name, limit: limit)
        }
        if type.conforms(to: .movie) {
            return try await prepareVideo(fileURL, name: name, limit: limit)
        }
        // Mapped from a copy of our own: a file someone else keeps (a file provider, another app) could shrink while
        // mapped, which would crash the reader. The copy is usually an APFS clone, and its name goes at once.
        if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limit { throw Failure.tooLarge(limit: limit) }
        let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: fileURL, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let data = try mapped(copy, limit: limit)
        return PreparedAttachment(data: data, name: name, mediaType: type.preferredMIMEType ?? "application/octet-stream", width: nil, height: nil)
    }

    static func prepareImage(_ data: Data, name: String, limit: Int) throws -> PreparedAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.unreadable }
        return try prepareImage(source, name: name, limit: limit)
    }

    /// The first frame of `source` (a Live Photo's still, a HEIC's primary image) as a JPEG of at most `maximumPixels`.
    static func prepareImage(_ source: CGImageSource, name: String, limit: Int) throws -> PreparedAttachment {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let jpeg = jpegData(image, quality: jpegQuality) else { throw Failure.unreadable }
        guard jpeg.count <= limit else { throw Failure.tooLarge(limit: limit) }
        let base = (name as NSString).deletingPathExtension
        return PreparedAttachment(data: jpeg, name: (base.isEmpty ? "photo" : base) + ".jpg", mediaType: "image/jpeg", width: image.width, height: image.height)
    }

    /// ImageIO's encoder on both platforms, as `UIImage.jpegData` uses on iOS; UIKit drawing is avoided because it is
    /// unreliable inside an extension.
    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func prepareVideo(_ url: URL, name: String, limit: Int) async throws -> PreparedAttachment {
        try await prepareVideo(AVURLAsset(url: url), name: name, limit: limit)
    }

    /// Slow-motion library videos arrive as compositions rather than files, so the export takes any asset.
    static func prepareVideo(_ asset: AVAsset, name: String, limit: Int) async throws -> PreparedAttachment {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { throw Failure.unreadable }
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        // The mapping keeps the bytes readable after the name is gone.
        defer { try? FileManager.default.removeItem(at: output) }
        try await export.export(to: output, as: .mp4)
        let data = try mapped(output, limit: limit)
        var width: Int?, height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            width = Int(abs(bounds.width)); height = Int(abs(bounds.height))
        }
        return PreparedAttachment(data: data, name: (name as NSString).deletingPathExtension + ".mp4", mediaType: "video/mp4", width: width, height: height)
    }

    /// The file's bytes as clean, file-backed pages rather than a heap copy; refused before mapping when over `limit`.
    private static func mapped(_ url: URL, limit: Int) throws -> Data {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limit { throw Failure.tooLarge(limit: limit) }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count <= limit else { throw Failure.tooLarge(limit: limit) }
        return data
    }
}
