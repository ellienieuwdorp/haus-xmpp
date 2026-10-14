import Foundation
import MessageStore
import Observation
import XMPPProtocol

/// Where the composer's preview comes from: the app model, through the same fetch center, cache and bounds as a
/// received link.
@MainActor protocol ComposerLinkPreviewSource: AnyObject {
    /// GET hosts of our upload slots, which never get a preview.
    var linkPreviewUploadHosts: Set<String> { get }
    /// The preview to show and send for `url`, its image already reduced to what we send; nil when there is none.
    func composerLinkPreview(for url: URL) async -> ComposerLinkPreview.Content?
}

/// The preview of the link being typed (docs/development/link-previews.md, Send). Shared by the iPhone composer
/// and, from Mac Phase 2, the Mac's; no UIKit or AppKit here.
///
/// About 400 ms after the draft stops changing, the first previewable link is fetched when the setting allows; the
/// card shows the host while it loads. Removing the card is remembered for that link until the draft is emptied.
/// Send freezes what is ready into the message (`frozen(for:suppressed:)`) and never waits for a fetch.
@MainActor @Observable
final class ComposerLinkPreview {
    /// What the card shows and the message carries.
    struct Content: Sendable, Equatable {
        /// The link as `LinkDetection` reports it: the XEP-0511 `about`.
        let url: URL
        /// `LinkDetection.displayHost(for: url)`.
        let host: String
        let title: String?
        let summary: String?
        /// `og:image:alt`, sent only with the image.
        var imageAlt: String? = nil
        /// The JPEG we send (`LinkPreviewImaging.sentThumbnail`), at most `LinkMetadata.maximumSentImageBytes`.
        var thumbnail: Data? = nil
    }

    enum State: Equatable {
        case none
        /// Fetching; the card shows the host and an activity indicator.
        case loading(URL)
        case ready(Content)
    }

    private(set) var state = State.none
    @ObservationIgnored private let debounce: Duration
    /// The link the current state or fetch is for.
    @ObservationIgnored private var target: URL?
    /// The wait for typing to pause; replaced on every change, so the draft is read only once it settles.
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Links whose card the user removed in this draft.
    @ObservationIgnored private var removed: Set<String> = []
    @ObservationIgnored private var uploadHosts: Set<String> = []

    init(debounce: Duration = .milliseconds(400)) { self.debounce = debounce }

    /// The draft or what it may carry changed. `enabled` is the Link Previews setting (and never in the sample
    /// conversations); `suppressed` is a message that carries no preview: files in the tray, or an edit.
    /// Runs on every keystroke, so it only schedules: links are detected once typing pauses. A card or fetch for the
    /// link still first stays meanwhile.
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

    /// The remove button: no card for this link until the draft is emptied.
    func remove() {
        if let target { removed.insert(target.absoluteString) }
        clear()
    }

    /// The own preview to store with the message sent as `text`: only a ready card whose link is still the first
    /// previewable one of the text, and never on a message with files or an edit. Never waits.
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
