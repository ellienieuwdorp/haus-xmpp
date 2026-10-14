import MessageStore
import XCTest
@testable import HausXMPP

/// The shared link preview values both bubbles and the composer read.
@MainActor
final class LinkPreviewModelTests: XCTestCase {
    /// Owner decisions 2026-10-07: our own fetching is on by default and links open in the in-app browser by default;
    /// a changed choice is what the next launch reads.
    func testLinkSettingsDefaultToFetchingAndTheInAppBrowserAndPersist() throws {
        let suite = "LinkPreviewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LinkSettings(defaults: defaults)
        XCTAssertTrue(settings.fetchPreviews)
        XCTAssertFalse(settings.openInSafari)
        settings.fetchPreviews = false
        settings.openInSafari = true
        let relaunched = LinkSettings(defaults: defaults)
        XCTAssertFalse(relaunched.fetchPreviews)
        XCTAssertTrue(relaunched.openInSafari)
    }

    /// The card's layout follows from the image's pixel size alone, so it is known before first layout.
    func testCardVariantFollowsTheImageSize() {
        let cases: [(width: Int?, height: Int?, variant: TimelineLinkPreview.Variant, line: UInt)] = [
            (1200, 630, .large, #line),
            (300, 300, .large, #line),
            (660, 300, .large, #line),
            (661, 300, .small, #line),
            (299, 200, .small, #line),
            (600, 800, .small, #line),
            (nil, nil, .text, #line),
            (0, 0, .text, #line),
        ]
        for item in cases {
            XCTAssertEqual(TimelineLinkPreview.variant(imageWidth: item.width, imageHeight: item.height), item.variant, line: item.line)
        }
    }

    /// Version 1 shows no card on a message with a file, even for a link in its caption, nor on an unsent one.
    func testOnlyATextMessageHasAPreviewCandidate() {
        var message = StoredMessage(id: "m", accountID: "me@example.org", chatID: "alex@example.org", senderID: "alex@example.org",
                                    body: "> me\n> old https://quoted.example/x\nsee example.org/a and https://news.example/b")
        XCTAssertEqual(message.linkPreviewCandidate(uploadHosts: [])?.absoluteString, "https://example.org/a")
        XCTAssertEqual(message.linkPreviewCandidate(uploadHosts: ["example.org"])?.absoluteString, "https://news.example/b")

        var withFile = message
        withFile.attachment = StoredAttachment(name: "photo.jpg", mediaType: "image/jpeg", size: 1, hash: "", secret: Data())
        XCTAssertNil(withFile.linkPreviewCandidate(uploadHosts: []))
        message.isRetracted = true
        XCTAssertNil(message.linkPreviewCandidate(uploadHosts: []))
    }
}
