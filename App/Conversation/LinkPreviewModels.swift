import Foundation
import MessageStore
import XMPPProtocol

// The link preview values the conversation shares between the iPhone bubble, the Mac bubble and the composer. Like
// the rest of TimelineModels, nothing here may import UIKit or AppKit. See docs/development/link-previews.md.

/// What a bubble's preview card draws. Built from stored data only, so its layout is known before the first layout
/// and never changes while the bubble is on screen.
struct TimelineLinkPreview: Sendable, Equatable {
    enum Variant: Sendable, Equatable {
        /// A full-width image above the text.
        case large
        /// A 56 pt thumbnail beside the text.
        case small
        /// No image.
        case text
    }

    enum Image: Sendable, Equatable {
        /// An image embedded in the message (sender or own preview), at most 64 KiB.
        case data(Data)
        /// A downsampled image our fetch wrote to disk.
        case file(URL)
    }

    /// The link the card opens: the one in the body, never a URL from page metadata.
    let url: URL
    /// `LinkDetection.displayHost(for: url)`.
    let host: String
    let title: String?
    let summary: String?
    var image: Image? = nil
    var imageAlt: String? = nil
    let variant: Variant
    /// The image's width over its height, which sizes the large variant's image; nil without an image.
    var imageAspectRatio: Double? = nil

    /// Large for an image at least 300 px wide whose aspect is between 1:1 and 2.2:1, small for any other image,
    /// text without one.
    static func variant(imageWidth: Int?, imageHeight: Int?) -> Variant {
        guard let width = imageWidth, let height = imageHeight, width > 0, height > 0 else { return .text }
        let aspect = Double(width) / Double(height)
        return width >= 300 && aspect >= 1 && aspect <= 2.2 ? .large : .small
    }

    /// The card's part of the bubble's VoiceOver label.
    var accessibilityDescription: String {
        "Link preview: " + [title, host].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One of our own fetch results as the app holds it: the store's cache entry with its image file resolved.
struct FetchedLinkPreview: Sendable, Equatable {
    let title: String?
    let summary: String?
    var imageAlt: String? = nil
    var imageFile: URL? = nil
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
}

extension StoredMessage {
    /// The link a preview card would be for: the first of `LinkDetection.previewableURLs` in the body, or nil for a
    /// message with a file (no card on attachments in version 1), an unsent or unreadable message, or one without a
    /// previewable link. `uploadHosts` are the GET hosts of our upload slots.
    func linkPreviewCandidate(uploadHosts: Set<String>) -> URL? {
        guard attachment == nil, !isRetracted, unreadableReason == nil else { return nil }
        return LinkScan.previewableURLs(in: body, uploadHosts: uploadHosts).first
    }
}
