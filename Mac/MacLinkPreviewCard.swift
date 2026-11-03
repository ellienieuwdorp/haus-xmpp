import CoreGraphics
import ImageIO
import SwiftUI

// The large image's height follows its stored aspect, so the card is laid out before the image decodes. The row's
// accessibility label already speaks for it.
struct MacLinkPreviewCard: View {
    let preview: TimelineLinkPreview
    let fill: Color
    let textColor: Color
    let metaColor: Color

    nonisolated static let idealWidth: CGFloat = 300
    static let thumbnailSide: CGFloat = 56

    @Environment(\.openURL) private var openURL
    @State private var image: CGImage?

    var body: some View {
        Button { openURL(preview.url) } label: {
            content
                .frame(idealWidth: Self.idealWidth, maxWidth: .infinity, alignment: .leading)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        // Not a stop of its own in the window's keyboard focus: the keyboard opens the link from the message's menu.
        .focusable(false)
        .help(preview.url.absoluteString)
        .task(id: preview.image) { image = await Self.decode(preview.image) }
    }

    @ViewBuilder private var content: some View {
        switch preview.variant {
        case .large:
            VStack(alignment: .leading, spacing: 0) {
                ClampedAspectHeight(aspect: preview.imageAspectRatio ?? 1.91) { picture }
                labels.padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 8)
            }
        case .small:
            HStack(alignment: .top, spacing: 10) {
                labels.frame(maxWidth: .infinity, alignment: .leading)
                picture
                    .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.leading, 10).padding([.vertical, .trailing], 8)
        case .text:
            labels.padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = preview.title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(textColor).lineLimit(2)
            }
            if let summary = preview.summary {
                Text(summary).font(.footnote).foregroundStyle(textColor.opacity(0.8)).lineLimit(2)
            }
            Text(preview.host).font(.caption).foregroundStyle(metaColor).lineLimit(1).truncationMode(.middle)
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
    }

    private var picture: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
    }

    // NSCache is thread-safe; the annotation only tells the compiler so.
    nonisolated(unsafe) private static let decoded = NSCache<NSString, CGImage>()

    // Never inflated beyond what the widest card shows at 2x; a header declaring more than `LinkScan.imagePixelBudget`
    // pixels is never decoded.
    private static func decode(_ source: TimelineLinkPreview.Image?) async -> CGImage? {
        guard let source else { return nil }
        let key = switch source {
        case .file(let url): "file:" + url.path
        case .data(let data): "data:" + LinkScan.digest(of: data)
        }
        if let hit = decoded.object(forKey: key as NSString) { return hit }
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            let imageSource: CGImageSource? = switch source {
            case .file(let url): CGImageSourceCreateWithURL(url as CFURL, options)
            case .data(let data): CGImageSourceCreateWithData(data as CFData, options)
            }
            guard let imageSource, let image = LinkScan.thumbnail(of: imageSource, maxPixelSize: 1120) else { return nil }
            decoded.setObject(image, forKey: key as NSString)
            return image
        }.value
    }
}

// Its height clamped to 120-220 pt, as on the iPhone.
private struct ClampedAspectHeight: Layout {
    let aspect: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? MacLinkPreviewCard.idealWidth
        let width = proposed.isFinite ? proposed : MacLinkPreviewCard.idealWidth
        return CGSize(width: width, height: min(220, max(120, (width / max(0.1, aspect)).rounded())))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}
