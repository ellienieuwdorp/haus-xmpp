import Foundation
import MessageStore
import Observation
import XMPPProtocol

@MainActor protocol ComposerLinkPreviewSource: AnyObject {
    // Our upload slots' GET hosts, which never get a preview.
    var linkPreviewUploadHosts: Set<String> { get }
    func composerLinkPreview(for url: URL) async -> ComposerLinkPreview.Content?
}

// Fetches about 400 ms after the draft stops changing. A removed card stays removed for that link until the draft is
// emptied. Send freezes what is ready into the message and never waits for a fetch.
@MainActor @Observable
final class ComposerLinkPreview {
    struct Content: Sendable, Equatable {
        // The XEP-0511 `about`.
        let url: URL
        let host: String
        let title: String?
        let summary: String?
        // Sent only with the image.
        var imageAlt: String? = nil
        var thumbnail: Data? = nil
    }

    enum State: Equatable {
        case none
        case loading(URL)
        case ready(Content)
    }

    private(set) var state = State.none
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var target: URL?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var removed: Set<String> = []
    @ObservationIgnored private var uploadHosts: Set<String> = []

    init(debounce: Duration = .milliseconds(400)) { self.debounce = debounce }

    // Runs on every keystroke, so it only schedules; a card or fetch for the first link stays meanwhile.
    func update(draft: String, enabled: Bool, suppressed: Bool, source: any ComposerLinkPreviewSource) {
        pending?.cancel()
        pending = nil
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty { removed = [] }
        guard enabled, !suppressed, !empty else {
            clear()
            return
        }
        let debounce = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.settled(draft, source: source)
        }
    }

    private func settled(_ draft: String, source: any ComposerLinkPreviewSource) {
        uploadHosts = source.linkPreviewUploadHosts
        // Only the first previewable link may carry a preview: a later one would not be the card the bubble shows.
        let first = LinkDetection.previewableURLs(in: draft, uploadHosts: uploadHosts).first
        guard let url = first, LinkDetection.isFetchable(url), !removed.contains(url.absoluteString) else {
            clear()
            return
        }
        guard url != target else { return }
        clear()
        target = url
        state = .loading(url)
        work = Task { [weak self] in
            let content = await source.composerLinkPreview(for: url)
            guard !Task.isCancelled, let self, self.target == url else { return }
            self.state = content.flatMap { $0.title != nil || $0.thumbnail != nil ? .ready($0) : nil } ?? .none
        }
    }

    func remove() {
        if let target { removed.insert(target.absoluteString) }
        clear()
    }

    func frozen(for text: String, suppressed: Bool) -> StoredLinkPreview? {
        guard !suppressed, case .ready(let content) = state,
              LinkDetection.previewableURLs(in: text, uploadHosts: uploadHosts).first == content.url else { return nil }
        return StoredLinkPreview(url: content.url.absoluteString, title: content.title, summary: content.summary,
                                 imageData: content.thumbnail, imageType: content.thumbnail == nil ? nil : "image/jpeg",
                                 imageAlt: content.thumbnail == nil ? nil : content.imageAlt, source: .own)
    }

    private func clear() {
        work?.cancel()
        work = nil
        target = nil
        if state != .none { state = .none }
    }
}
