import MessageStore
import XCTest
import XMPPProtocol
@testable import HausXMPP

/// The composer's link preview (docs/development/link-previews.md, Send): what it fetches while the user types, and
/// what Send freezes into the message without waiting.
@MainActor
final class ComposerLinkPreviewTests: XCTestCase {
    private final class Source: ComposerLinkPreviewSource {
        var linkPreviewUploadHosts: Set<String> = []
        private(set) var asked: [URL] = []
        /// While set, fetches wait for `release()`.
        var holding = false
        private var held: [CheckedContinuation<Void, Never>] = []

        func composerLinkPreview(for url: URL) async -> ComposerLinkPreview.Content? {
            asked.append(url)
            if holding { await withCheckedContinuation { held.append($0) } }
            return ComposerLinkPreview.Content(url: url, host: LinkDetection.displayHost(for: url) ?? "", title: "Title of " + url.path(),
                                               summary: "Summary", imageAlt: "Alt", thumbnail: Data([0xFF, 0xD8, 0xFF]))
        }

        func release() { held.forEach { $0.resume() }; held = [] }
    }

    private let source = Source()
    private let preview = ComposerLinkPreview(debounce: .milliseconds(30))

    private func type(_ draft: String, enabled: Bool = true, suppressed: Bool = false) {
        preview.update(draft: draft, enabled: enabled, suppressed: suppressed, source: source)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    private var readyURL: URL? { if case .ready(let content) = preview.state { content.url } else { nil } }

    /// Typing a link fetches it once, after the typing pauses; only the first previewable link counts, and an http
    /// link there is never fetched (nor is the https link after it).
    func testFetchesTheFirstLinkOnceTypingPauses() async throws {
        for draft in ["Look https://ex", "Look https://example.org/a", "Look https://example.org/a and https://example.net/b"] { type(draft) }
        try await settle()
        XCTAssertEqual(source.asked, [URL(string: "https://example.org/a")!])
        XCTAssertEqual(readyURL, URL(string: "https://example.org/a"))

        type("http://plain.example/x then https://example.org/a")
        try await settle()
        XCTAssertEqual(preview.state, .none)
        XCTAssertEqual(source.asked.count, 1)
    }

    /// The remove button keeps that link's card away while the draft lasts; a new draft may show it again.
    func testARemovedCardStaysRemovedUntilTheDraftIsEmptied() async throws {
        type("https://example.org/a")
        try await settle()
        preview.remove()
        XCTAssertEqual(preview.state, .none)
        type("https://example.org/a is good")
        try await settle()
        XCTAssertEqual(preview.state, .none)
        XCTAssertEqual(source.asked.count, 1)

        type("")
        type("https://example.org/a")
        try await settle()
        XCTAssertEqual(readyURL, URL(string: "https://example.org/a"))
    }

    /// Files in the tray, an edit, or the setting off: no fetch and no card.
    func testNoPreviewWithFilesInAnEditOrWithTheSettingOff() async throws {
        type("https://example.org/a", suppressed: true)
        type("https://example.org/a", enabled: false)
        try await settle()
        XCTAssertEqual(source.asked, [])
        XCTAssertEqual(preview.state, .none)

        type("https://example.org/a")
        try await settle()
        type("https://example.org/a", suppressed: true)
        XCTAssertEqual(preview.state, .none, "Adding a file takes the card away")
        XCTAssertNil(preview.frozen(for: "https://example.org/a", suppressed: true))
    }

    /// Send stores the ready card as our own preview, only while its link is still the first one in the text, and
    /// never waits for a fetch that is still running.
    func testSendFreezesOnlyAReadyCardForTheSentLink() async throws {
        source.holding = true
        type("Read https://example.org/a")
        try await settle()
        XCTAssertEqual(preview.state, .loading(URL(string: "https://example.org/a")!))
        XCTAssertNil(preview.frozen(for: "Read https://example.org/a", suppressed: false), "Sending now goes without a preview")

        source.release()
        try await settle()
        let frozen = try XCTUnwrap(preview.frozen(for: "Read https://example.org/a", suppressed: false))
        XCTAssertEqual(frozen, StoredLinkPreview(url: "https://example.org/a", title: "Title of /a", summary: "Summary",
                                                 imageData: Data([0xFF, 0xD8, 0xFF]), imageType: "image/jpeg", imageAlt: "Alt", source: .own))
        XCTAssertNil(preview.frozen(for: "Read this instead", suppressed: false), "The link left the text")
        XCTAssertNil(preview.frozen(for: "https://example.net/b and https://example.org/a", suppressed: false), "No longer the first link")
    }
}
