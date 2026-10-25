import AVFoundation
import Foundation
import ImageIO
import MessageStore
import MessagingCore
import OMEMO
import Photos
import PhotosUI
import SwiftUI
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers
import XMPPProtocol

/// The app's own pickers: the photo library, recent photos and the camera. Files, shared items and the parts every
/// source shares are in `AttachmentPreparation.swift`.
extension AttachmentPreparer {
    /// A library pick: photos go through `prepareImage`, video is copied out as a file first.
    static func prepare(photo item: PhotosPickerItem, limit: Int) async throws -> PreparedAttachment {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw Failure.unreadable }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return try await prepareVideo(movie.url, name: "video", limit: limit)
        }
        guard let data = try await item.loadTransferable(type: Data.self) else { throw Failure.unreadable }
        return try prepareImage(data, name: "photo", limit: limit)
    }

    /// A recent-photos pick from the attachment panel. Originals kept only in iCloud download on demand.
    static func prepare(asset: PHAsset, limit: Int) async throws -> PreparedAttachment {
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            let video: LibraryVideo = try await withCheckedThrowingContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in
                    if let video { continuation.resume(returning: LibraryVideo(asset: video)) } else { continuation.resume(throwing: Failure.unreadable) }
                }
            }
            return try await prepareVideo(video.asset, name: "video", limit: limit)
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: Failure.unreadable) }
            }
        }
        return try prepareImage(data, name: "photo", limit: limit)
    }

    #if os(iOS)
    /// A camera capture from the attachment panel.
    static func prepare(capture: CameraCapture, limit: Int) async throws -> PreparedAttachment {
        switch capture {
        case .image(let data): return try prepareImage(data, name: "photo", limit: limit)
        case .movie(let url):
            defer { try? FileManager.default.removeItem(at: url) }
            return try await prepareVideo(url, name: "video", limit: limit)
        }
    }
    #endif
}

/// Photos hands the asset over on its own queue; nothing mutates it, and the export only reads it.
private struct LibraryVideo: @unchecked Sendable { let asset: AVAsset }

/// A picked video comes across as a file so a large clip never sits in memory twice.
private struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + (received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension))
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Refused slot requests and PUTs per queued file. A file that uses up its tries is failed, so a server that keeps
/// refusing it (quota, size, an expired service) cannot hold back the messages queued after it in its chat.
// ponytail: counts live in memory, so each launch gives a stuck file `limit` fresh tries; persist them if that matters.
struct UploadFailureBudget {
    static let limit = 3
    /// How long a refused file waits before its next try, so a pass that runs meanwhile does not use the tries up.
    static let backOff: Duration = .seconds(5)
    private var failures: [String: Int] = [:]
    private var waitUntil: [String: ContinuousClock.Instant] = [:]

    /// True when this failure used the file's last try.
    mutating func recordFailure(_ messageID: String, at now: ContinuousClock.Instant = .now) -> Bool {
        let count = failures[messageID, default: 0] + 1
        failures[messageID] = count < Self.limit ? count : nil
        waitUntil[messageID] = count < Self.limit ? now + Self.backOff : nil
        return count >= Self.limit
    }

    /// True while a refused file is inside its back-off.
    func isWaiting(_ messageID: String, at now: ContinuousClock.Instant = .now) -> Bool {
        waitUntil[messageID].map { now < $0 } ?? false
    }

    mutating func reset(_ messageID: String) { failures[messageID] = nil; waitUntil[messageID] = nil }
}

/// One pass at a time over work that each pass reads once when it starts. A request made while a pass runs is kept
/// and another pass starts when it ends, so work queued meanwhile (the next file of a multi-file send) is not left
/// waiting for some later event to start a pass.
@MainActor final class RerunningPass {
    private var requested = false
    private var running = false
    /// Returns the pass to run, or nil when it cannot run now; the request is then kept until the next one.
    private let makePass: @MainActor () -> (@MainActor () async -> Void)?

    init(_ makePass: @escaping @MainActor () -> (@MainActor () async -> Void)?) { self.makePass = makePass }

    func request() {
        requested = true
        guard !running, let pass = makePass() else { return }
        requested = false
        running = true
        Task { [weak self] in
            await pass()
            guard let self else { return }
            self.running = false
            if self.requested { self.request() }
        }
    }
}

/// Background PUTs: the ciphertext file is handed to the system so a suspended app still finishes.
/// Task identifiers are persisted on the attachment row; a relaunch asks which are still running.
final class AttachmentUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "haus.xmpp.ios.uploads." + scope)
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

#if os(iOS)
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
        // Not isEnabled: a disabled glass button dims the confirmation glyph to near invisible.
        saveButton.isUserInteractionEnabled = false
        let url = url
        Task {
            var saved = false
            if await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized {
                // The cache file's exact bytes, so a saved photo keeps its format and metadata.
                // PhotoKit runs the block on its own queue, so it must not inherit the main actor.
                saved = (try? await PHPhotoLibrary.shared().performChanges { @Sendable in
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
                }) != nil
            }
            UINotificationFeedbackGenerator().notificationOccurred(saved ? .success : .error)
            // Pinned white: the glass configuration renders a swapped-in template glyph dark.
            saveButton.configuration?.image = UIImage(systemName: saved ? "checkmark" : "exclamationmark.triangle")?.withTintColor(.white, renderingMode: .alwaysOriginal)
            saveButton.accessibilityLabel = saved ? "Saved to Photos" : "Could not save. Allow adding photos in Settings."
            UIAccessibility.post(notification: .announcement, argument: saveButton.accessibilityLabel)
            try? await Task.sleep(for: .seconds(2))
            saveButton.configuration?.image = UIImage(systemName: "square.and.arrow.down")
            saveButton.accessibilityLabel = "Save to Photos"
            saveButton.isUserInteractionEnabled = true
        }
    }
}
#endif
