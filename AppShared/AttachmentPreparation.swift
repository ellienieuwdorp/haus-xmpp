import AVFoundation
import Foundation
import ImageIO
import MessagingCore
import OMEMO
import os
import UniformTypeIdentifiers

// Shared with the share extensions, so nothing here holds a whole file on the heap that it can read from disk: images
// decode from their file, and a transcoded video or a plain file is memory-mapped, outside the extension's memory budget.
enum AttachmentPreparer {
    enum Failure: LocalizedError, Equatable {
        case tooLarge(limit: Int), unreadable
        // Only the first `seconds` fit at an acceptable quality.
        case tooLong(seconds: Int)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let limit):
                "This file is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) that can be sent from this account."
            case .unreadable: "This file could not be read."
            case .tooLong: "This video is too long to send at an acceptable quality."
            }
        }
    }

    // What the too-long dialog offers, the same on every surface.
    struct Shortening: Identifiable, Equatable, Sendable {
        let id: UUID
        let seconds: Int
        init(id: UUID = UUID(), seconds: Int) { self.id = id; self.seconds = seconds }
        static let title = "Video Too Long"
        var length: String { Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)) }
        var message: String { "This video is too long to send at an acceptable quality. Send the first \(length)?" }
        var confirmation: String { "Send First \(length)" }
    }

    static let maximumPixels = 2048
    static let jpegQuality = 0.85
    // Tried in order until one fits; each decodes afresh from the source, so no full-size image outlives its step.
    static let photoSteps: [(pixels: Int, quality: Double)] = [(maximumPixels, jpegQuality), (maximumPixels, 0.7), (1600, 0.7), (1280, 0.7), (1024, 0.6)]
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "attachments")

    static func prepare(fileURL: URL, name: String, type: UTType?, limit: Int, keepingFirst first: Int? = nil) async throws -> PreparedAttachment {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let type = type ?? UTType(filenameExtension: fileURL.pathExtension) ?? .data
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw Failure.unreadable }
            return try prepareImage(source, name: name, limit: limit)
        }
        if type.conforms(to: .movie) {
            return try await prepareVideo(fileURL, name: name, limit: limit, keepingFirst: first)
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

    static func prepareImage(_ source: CGImageSource, name: String, limit: Int) throws -> PreparedAttachment {
        let base = (name as NSString).deletingPathExtension
        for step in photoSteps {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: step.pixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let jpeg = jpegData(image, quality: step.quality) else { throw Failure.unreadable }
            guard jpeg.count <= limit else { continue }
            return PreparedAttachment(data: jpeg, name: (base.isEmpty ? "photo" : base) + ".jpg", mediaType: "image/jpeg",
                                      width: image.width, height: image.height)
        }
        throw Failure.tooLarge(limit: limit)
    }

    // ImageIO on both platforms; UIKit drawing is unreliable inside an extension.
    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func prepareVideo(_ url: URL, name: String, limit: Int, keepingFirst first: Int? = nil,
                             clock: any Clock<Duration> = ContinuousClock()) async throws -> PreparedAttachment {
        try await prepareVideo(AVURLAsset(url: url), name: name, limit: limit, keepingFirst: first, clock: clock)
    }

    // Slow-motion library videos arrive as compositions rather than files, so this takes any asset. One encode at the
    // planned bitrate usually fits; an overshoot gets one more try at a bitrate scaled down by how far it missed.
    static func prepareVideo(_ asset: AVAsset, name: String, limit: Int, keepingFirst first: Int? = nil,
                             clock: any Clock<Duration> = ContinuousClock()) async throws -> PreparedAttachment {
        let source = try await VideoTranscoder.source(of: asset, keepingFirst: first)
        var plan: VideoSizePlan
        switch VideoSizePlan.plan(source, limit: limit) {
        case .encode(let planned): plan = planned
        case .tooLong(let seconds): throw Failure.tooLong(seconds: seconds)
        case .tooLarge: throw Failure.tooLarge(limit: limit)
        }
        let deadline = Duration.seconds(60) + .seconds(source.seconds * 2)
        for attempt in 1...2 {
            let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
            // The mapping keeps the bytes readable after the name is gone.
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try await VideoTranscoder.transcode(asset, plan: plan, keepingFirst: first, to: output, deadline: deadline, clock: clock)
            } catch is VideoTranscoder.TimedOut {
                throw Failure.unreadable
            }
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            log.debug("""
                video attempt \(attempt): planned \(plan.plannedBytes) bytes at \(plan.width)x\(plan.height), \(plan.frameRate) fps; \
                wrote \(size) of \(limit)
                """)
            if size > 0, size <= limit {
                let data = try mapped(output, limit: limit)
                return PreparedAttachment(data: data, name: (name as NSString).deletingPathExtension + ".mp4", mediaType: "video/mp4",
                                          width: plan.width, height: plan.height)
            }
            guard attempt == 1, size > 0, let retry = VideoSizePlan.retry(plan, source: source, limit: limit, actualBytes: size) else { break }
            plan = retry
        }
        throw Failure.tooLarge(limit: limit)
    }

    private static func mapped(_ url: URL, limit: Int) throws -> Data {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limit { throw Failure.tooLarge(limit: limit) }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count <= limit else { throw Failure.tooLarge(limit: limit) }
        return data
    }
}
