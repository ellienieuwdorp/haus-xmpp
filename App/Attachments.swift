import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import MessageStore
import OMEMO
import Photos
import UIKit
import UniformTypeIdentifiers
import XMPPProtocol

/// Where shared files live on disk. Plaintext bytes are keyed by their hash in an account-scoped
/// cache; ciphertext waiting for a PUT is staged per message. Both are under the shared container
/// with complete-until-first-unlock protection, never inside SQLite.
struct AttachmentFiles {
    let root: URL

    init(directory: URL, account: String) {
        let scope = SHA256.hash(data: Data(account.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        root = directory.appending(path: "attachments/\(scope)", directoryHint: .isDirectory)
        for sub in ["cache", "staging"] {
            try? FileManager.default.createDirectory(at: root.appending(path: sub), withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
    }

    func cached(_ attachment: StoredAttachment, messageID: String) -> URL? {
        let url = cacheURL(attachment, messageID: messageID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Legacy links carry no hash, so the message ID keys the cache instead.
    func cacheURL(_ attachment: StoredAttachment, messageID: String) -> URL {
        let key = attachment.hash.isEmpty ? "m-" + messageID : attachment.hash
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return root.appending(path: "cache/" + key + (ext.isEmpty ? "" : "." + ext))
    }

    func stagingURL(messageID: String) -> URL { root.appending(path: "staging/\(messageID).enc") }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A file chosen for sending, already reduced to what we are willing to upload.
struct PreparedAttachment: Sendable {
    let data: Data
    let name: String
    let mediaType: String
    let width: Int?
    let height: Int?
}

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

    /// Images are re-encoded at ≤ 2048 px, video is exported at 720p, everything else goes as is.
    static func prepare(fileURL: URL, name: String, type: UTType?, limit: Int) async throws -> PreparedAttachment {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let type = type ?? UTType(filenameExtension: fileURL.pathExtension) ?? .data
        if type.conforms(to: .image) {
            return try prepareImage(try Data(contentsOf: fileURL), name: name, limit: limit)
        }
        if type.conforms(to: .movie) {
            return try await prepareVideo(fileURL, name: name, limit: limit)
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= limit else { throw Failure.tooLarge(limit: limit) }
        return PreparedAttachment(data: data, name: name, mediaType: type.preferredMIMEType ?? "application/octet-stream", width: nil, height: nil)
    }

    static func prepareImage(_ data: Data, name: String, limit: Int) throws -> PreparedAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { throw Failure.unreadable }
        guard jpeg.count <= limit else { throw Failure.tooLarge(limit: limit) }
        let base = (name as NSString).deletingPathExtension
        return PreparedAttachment(data: jpeg, name: (base.isEmpty ? "photo" : base) + ".jpg", mediaType: "image/jpeg", width: image.width, height: image.height)
    }

    static func prepareVideo(_ url: URL, name: String, limit: Int) async throws -> PreparedAttachment {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { throw Failure.unreadable }
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await export.export(to: output, as: .mp4)
        let data = try Data(contentsOf: output)
        guard data.count <= limit else { throw Failure.tooLarge(limit: limit) }
        var width: Int?, height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            width = Int(abs(bounds.width)); height = Int(abs(bounds.height))
        }
        return PreparedAttachment(data: data, name: (name as NSString).deletingPathExtension + ".mp4", mediaType: "video/mp4", width: width, height: height)
    }
}

/// Background PUTs: the ciphertext file is handed to the system so a suspended app still finishes.
/// Task identifiers are persisted on the attachment row; a relaunch asks which are still running.
final class AttachmentUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "dev.xmpplab.ios.uploads." + scope)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private let scope: String
    /// Called off the main thread when any task ends, including ones reattached after relaunch.
    var onFinish: @Sendable (_ taskID: Int, _ succeeded: Bool) -> Void = { _, _ in }

    init(scope: String) { self.scope = scope }

    func runningTaskIDs() async -> Set<Int> {
        Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }.map(\.taskIdentifier))
    }

    func start(file: URL, slot: XMPPUploadSlot, size: Int, contentType: String) -> Int {
        var request = URLRequest(url: slot.put)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        for (name, value) in slot.headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.uploadTask(with: request, fromFile: file)
        task.resume()
        return task.taskIdentifier
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        onFinish(task.taskIdentifier, error == nil && (200...299).contains(status))
    }
}

/// Fetches a shared file and authenticates it. TLS trust is the system store's (the simulator
/// carries the lab CA); nothing here relaxes it.
enum AttachmentDownloader {
    private static let session = URLSession(configuration: .ephemeral)

    static func fetch(_ attachment: StoredAttachment, secret: (key: Data, iv: Data)?) async throws -> Data {
        guard let remote = attachment.url, let url = URL(string: remote), url.scheme == "https" else { throw AttachmentTransfer.Failure.unencrypted }
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else { throw URLError(.badServerResponse) }
        guard let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size <= AttachmentTransfer.maximumBytes + 16 else { throw AttachmentTransfer.Failure.tooLarge }
        let bytes = try Data(contentsOf: file)
        guard let secret else {
            // An unencrypted source still has to match the hash the authenticated message promised.
            if let expected = Data(hex: attachment.hash), !expected.isEmpty, Data.sha256(bytes) != expected { throw AttachmentTransfer.Failure.plainHashMismatch }
            return bytes
        }
        return try AttachmentTransfer.open(bytes, key: secret.key, iv: secret.iv,
                                           expectedCipherHash: attachment.cipherHash.flatMap { Data(hex: $0) }, expectedPlainHash: Data(hex: attachment.hash))
    }
}

/// Bounded decoding for bubbles: the thumbnail pass never inflates the full image.
enum AttachmentThumbnails {
    // NSCache is thread-safe; the annotation only tells the compiler so.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    /// Synchronous hit, so a reconfigured cell never blanks an image it already showed.
    static func cached(for url: URL) -> UIImage? { cache.object(forKey: url.path as NSString) }

    static func image(for url: URL, mediaType: String, maxPixels: Int = 1024) async -> UIImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            if mediaType.hasPrefix("image/") {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }
            if mediaType.hasPrefix("video/") {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
                guard let cg = try? await generator.image(at: .zero).image else { return nil }
                return UIImage(cgImage: cg)
            }
            return nil
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// A sent or received photo, full screen: pinch to zoom, drag down to dismiss, share, save.
final class ImageViewer: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let url: URL
    private let scroll = UIScrollView()
    private let imageView: UIImageView
    private let saveButton = UIButton(configuration: .glass())

    init(image: UIImage, url: URL) {
        self.url = url
        imageView = UIImageView(image: image)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Photo"
        scroll.addSubview(imageView)
        view.addSubview(scroll)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        scroll.addGestureRecognizer(pan)

        let close = button("xmark", label: "Close", action: #selector(close))
        let share = button("square.and.arrow.up", label: "Share", action: #selector(share))
        configure(saveButton, "square.and.arrow.down", label: "Save to Photos", action: #selector(save))
        let trailing = UIStackView(arrangedSubviews: [saveButton, share])
        trailing.spacing = 12
        for item in [close, trailing] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
            item.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8).isActive = true
        }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            trailing.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
    }

    private func button(_ symbol: String, label: String, action: Selector) -> UIButton {
        let button = UIButton(configuration: .glass())
        configure(button, symbol, label: label, action: action)
        return button
    }

    private func configure(_ button: UIButton, _ symbol: String, label: String, action: Selector) {
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.cornerStyle = .capsule
        button.tintColor = .white
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    /// Only a mostly-downward drag on an unzoomed photo dismisses; zoomed panning stays with the scroll view.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, scroll.zoomScale == scroll.minimumZoomScale else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.y > abs(velocity.x)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let offset = max(0, pan.translation(in: view).y)
        let progress = min(1, offset / 300)
        switch pan.state {
        case .changed:
            imageView.transform = CGAffineTransform(translationX: pan.translation(in: view).x, y: offset).scaledBy(x: 1 - progress * 0.3, y: 1 - progress * 0.3)
            view.backgroundColor = UIColor.black.withAlphaComponent(1 - progress)
        case .ended, .cancelled:
            if pan.state == .ended, offset > 100 || pan.velocity(in: view).y > 800 { dismiss(animated: true); return }
            UIView.animate(springDuration: 0.3) { self.imageView.transform = .identity; self.view.backgroundColor = .black }
        default: break
        }
    }

    override func accessibilityPerformEscape() -> Bool { close(); return true }
    @objc private func close() { dismiss(animated: true) }

    @objc private func share(_ sender: UIButton) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = sender
        present(sheet, animated: true)
    }

    @objc private func save() {
        saveButton.isEnabled = false
        let url = url
        Task {
            var saved = false
            if await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized {
                // The cache file's exact bytes, so a saved photo keeps its format and metadata.
                saved = (try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
                }) != nil
            }
            UINotificationFeedbackGenerator().notificationOccurred(saved ? .success : .error)
            saveButton.configuration?.image = UIImage(systemName: saved ? "checkmark" : "exclamationmark.triangle")
            saveButton.accessibilityLabel = saved ? "Saved to Photos" : "Could not save. Allow adding photos in Settings."
            UIAccessibility.post(notification: .announcement, argument: saveButton.accessibilityLabel)
            try? await Task.sleep(for: .seconds(2))
            saveButton.configuration?.image = UIImage(systemName: "square.and.arrow.down")
            saveButton.accessibilityLabel = "Save to Photos"
            saveButton.isEnabled = true
        }
    }
}
