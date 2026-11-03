import Foundation
import MessageStore
import XMPPProtocol

// Built from stored data only, so its layout is known before the first layout and never changes on screen.
struct TimelineLinkPreview: Sendable, Equatable {
    enum Variant: Sendable, Equatable {
        case large
        case small
        case text
    }

    enum Image: Sendable, Equatable {
        case data(Data)
        case file(URL)
    }

    // The link in the body, never a URL from page metadata.
    let url: URL
    let host: String
    let title: String?
    let summary: String?
    var image: Image? = nil
    var imageAlt: String? = nil
    let variant: Variant
    var imageAspectRatio: Double? = nil

    static func variant(imageWidth: Int?, imageHeight: Int?) -> Variant {
        guard let width = imageWidth, let height = imageHeight, width > 0, height > 0 else { return .text }
        let aspect = Double(width) / Double(height)
        return width >= 300 && aspect >= 1 && aspect <= 2.2 ? .large : .small
    }

    var accessibilityDescription: String {
        "Link preview: " + [title, host].compactMap { $0 }.joined(separator: ", ")
    }
}

struct FetchedLinkPreview: Sendable, Equatable {
    let title: String?
    let summary: String?
    var imageAlt: String? = nil
    var imageFile: URL? = nil
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
}

extension StoredMessage {
    func linkPreviewCandidate(uploadHosts: Set<String>) -> URL? {
        guard attachment == nil, !isRetracted, unreadableReason == nil else { return nil }
        return LinkScan.previewableURLs(in: body, uploadHosts: uploadHosts).first
    }
}
