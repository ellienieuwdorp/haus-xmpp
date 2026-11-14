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

extension AttachmentPreparer {
    static func prepare(photo item: PhotosPickerItem, limit: Int, keepingFirst first: Int? = nil) async throws -> PreparedAttachment {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw Failure.unreadable }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return try await prepareVideo(movie.url, name: "video", limit: limit, keepingFirst: first)
        }
        guard let data = try await item.loadTransferable(type: Data.self) else { throw Failure.unreadable }
        return try prepareImage(data, name: "photo", limit: limit)
    }

    // Originals kept only in iCloud download on demand.
    static func prepare(asset: PHAsset, limit: Int, keepingFirst first: Int? = nil) async throws -> PreparedAttachment {
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
            return try await prepareVideo(video.asset, name: "video", limit: limit, keepingFirst: first)
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
}

#if os(iOS)
// Owns the camera's movie until nothing can prepare it again, so a clip too long to send whole keeps it for its start.
final class CameraJob: Sendable {
    let capture: CameraCapture
    init(_ capture: CameraCapture) { self.capture = capture }
    // The movie is in our temporary folder, which the system empties anyway; a failed delete loses nothing.
    deinit { if case .movie(let url) = capture { try? FileManager.default.removeItem(at: url) } }

    func prepare(limit: Int, keepingFirst first: Int?) async throws -> PreparedAttachment {
        switch capture {
        case .image(let data): try AttachmentPreparer.prepareImage(data, name: "photo", limit: limit)
        case .movie(let url): try await AttachmentPreparer.prepareVideo(url, name: "video", limit: limit, keepingFirst: first)
        }
    }
}
#endif

// Photos hands the asset over on its own queue; nothing mutates it, and the transcoder only reads it.
private struct LibraryVideo: @unchecked Sendable { let asset: AVAsset }

// A file, so a large clip never sits in memory twice.
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

// A file that uses up its tries is failed, so a server that keeps refusing it cannot hold back later messages in its
// chat. Counts live in memory: each launch gives a stuck file fresh tries.
struct UploadFailureBudget {
    static let limit = 3
    // Lets a pass that runs meanwhile skip the file instead of using its tries up.
    static let backOff: Duration = .seconds(5)
    private var failures: [String: Int] = [:]
    private var waitUntil: [String: ContinuousClock.Instant] = [:]

    mutating func recordFailure(_ messageID: String, at now: ContinuousClock.Instant = .now) -> Bool {
        let count = failures[messageID, default: 0] + 1
        failures[messageID] = count < Self.limit ? count : nil
        waitUntil[messageID] = count < Self.limit ? now + Self.backOff : nil
        return count >= Self.limit
    }

    func isWaiting(_ messageID: String, at now: ContinuousClock.Instant = .now) -> Bool {
        waitUntil[messageID].map { now < $0 } ?? false
    }

    mutating func reset(_ messageID: String) { failures[messageID] = nil; waitUntil[messageID] = nil }
}

// A request made while a pass runs starts another pass when it ends, so work queued meanwhile is not left waiting.
@MainActor final class RerunningPass {
    private var requested = false
    private var running = false
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

// The system finishes PUTs for a suspended or exited app. One per session identifier, made at launch (and on a
// relaunch for session events) so the system can deliver what finished while the app was away; each completion is
// journaled before the delegate returns and matched to its row by tag.
final class AttachmentUploader: UploadTasks, Sendable {
    static let identifierPrefix = "haus.xmpp.ios.uploads."
    private static let registry = Registry()

    let journal: UploadJournal
    private let events: UploadSessionEvents
    private let session: URLSession

    static func shared(scope: String) -> AttachmentUploader { registry.uploader(scope: scope) }

    // The app delegate's session-events callback. False for a session this app does not own.
    static func handleEvents(forSession identifier: String, completion: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard identifier.hasPrefix(identifierPrefix) else { return false }
        shared(scope: String(identifier.dropFirst(identifierPrefix.count))).events.awaitDelivery(completion)
        return true
    }

    private init(scope: String) {
        journal = UploadJournal(file: UploadJournal.file(scope: scope))
        events = UploadSessionEvents(journal: journal)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifierPrefix + scope)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: events, delegateQueue: nil)
    }

    // Called off the main thread after each completion is journaled.
    func onFinish(_ handler: @escaping @Sendable () -> Void) { events.onFinish(handler) }

    // Suspended until resumed, so the row names the attempt before any completion can arrive.
    func prepare(file: URL, slot: XMPPUploadSlot, size: Int, contentType: String, tag: UploadTag) -> URLSessionUploadTask {
        var request = URLRequest(url: slot.put)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        for (name, value) in slot.headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = tag.taskDescription
        return task
    }

    func states() async -> [UploadTaskState] {
        await session.allTasks.compactMap { task in
            let phase: UploadTaskState.Phase
            switch task.state {
            case .running, .suspended: phase = .live
            case .completed: phase = .finished(succeeded: UploadSessionEvents.succeeded(task, error: task.error), tooLarge: UploadSessionEvents.tooLarge(task))
            case .canceling: return nil
            @unknown default: return nil
            }
            return UploadTaskState(taskID: task.taskIdentifier, tag: UploadTag(taskDescription: task.taskDescription), phase: phase)
        }
    }

    func apply(resume: Set<Int>, cancel: Set<Int>) async {
        guard !resume.isEmpty || !cancel.isEmpty else { return }
        for task in await session.allTasks {
            if cancel.contains(task.taskIdentifier) { task.cancel() } else if resume.contains(task.taskIdentifier) { task.resume() }
        }
    }

    // `lock` serialises `uploaders`.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var uploaders: [String: AttachmentUploader] = [:]

        func uploader(scope: String) -> AttachmentUploader {
            lock.withLock {
                if let uploader = uploaders[scope] { return uploader }
                let uploader = AttachmentUploader(scope: scope)
                uploaders[scope] = uploader
                return uploader
            }
        }
    }
}

// `lock` serialises the two handlers; the journal locks itself.
private final class UploadSessionEvents: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let journal: UploadJournal
    private let lock = NSLock()
    private var finished: @Sendable () -> Void = {}
    private var delivered: (@MainActor @Sendable () -> Void)?

    init(journal: UploadJournal) { self.journal = journal }

    func onFinish(_ handler: @escaping @Sendable () -> Void) { lock.withLock { finished = handler } }
    func awaitDelivery(_ completion: @escaping @MainActor @Sendable () -> Void) { lock.withLock { delivered = completion } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let tag = UploadTag(taskDescription: task.taskDescription) else { return }
        journal.record(UploadOutcome(tag: tag, succeeded: Self.succeeded(task, error: error), tooLarge: Self.tooLarge(task), finishedAt: Date()))
        lock.withLock { finished }()
    }

    // Every completion of a relaunch was delivered, and journaled, before this.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { delivered = nil }
            return delivered
        }
        guard let completion else { return }
        Task { @MainActor in completion() }
    }

    static func succeeded(_ task: URLSessionTask, error: (any Error)?) -> Bool {
        error == nil && (200...299).contains((task.response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // A proxy in front of the upload service may cap bodies below the advertised `max-file-size`.
    static func tooLarge(_ task: URLSessionTask) -> Bool { (task.response as? HTTPURLResponse)?.statusCode == 413 }
}

#if os(iOS)
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
