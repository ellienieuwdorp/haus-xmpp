#if os(iOS)
import CryptoKit
import ImageIO
import UIKit

/// The link preview card inside an iPhone bubble, above the text (docs/development/link-previews.md, UI). Styled like
/// the reply-quote panel, drawn from stored data only: the variant and the large image's height follow from the
/// stored pixel size, so the card's layout is settled before the image decodes and never changes on screen. Its bubble
/// handles taps and long presses, and its text speaks for it, so nothing here is an accessibility element.
@MainActor
final class LinkPreviewCardView: UIView {
    static let cornerRadius: CGFloat = 12
    static let thumbnailSide: CGFloat = 56
    static let largeImageHeights: ClosedRange<CGFloat> = 120...220
    /// Inside a bubble the card keeps the quote's 8 pt from the bubble's edges.
    static let bubbleInset: CGFloat = 8

    private let image = UIImageView()
    private let title = UILabel()
    private let summary = UILabel()
    private let host = UILabel()
    private let labels: UIStackView
    private var imageHeight: NSLayoutConstraint!
    private var large: [NSLayoutConstraint] = []
    private var small: [NSLayoutConstraint] = []
    private var text: [NSLayoutConstraint] = []
    private(set) var preview: TimelineLinkPreview?

    override init(frame: CGRect) {
        labels = UIStackView(arrangedSubviews: [title, summary, host])
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        image.translatesAutoresizingMaskIntoConstraints = false
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.backgroundColor = .quaternarySystemFill
        image.accessibilityIgnoresInvertColors = true
        addSubview(image)
        title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        title.numberOfLines = 2
        summary.font = .preferredFont(forTextStyle: .footnote)
        summary.numberOfLines = 2
        host.font = .preferredFont(forTextStyle: .caption1)
        host.numberOfLines = 1
        host.lineBreakMode = .byTruncatingMiddle
        for label in [title, summary, host] {
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 2
        addSubview(labels)
        imageHeight = image.heightAnchor.constraint(equalToConstant: Self.largeImageHeights.lowerBound)
        let labelsFill = labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        // Below the labels' hugging, so a short title sits at the top beside the thumbnail instead of stretching.
        labelsFill.priority = .defaultLow - 1
        large = [
            image.topAnchor.constraint(equalTo: topAnchor), image.leadingAnchor.constraint(equalTo: leadingAnchor),
            image.trailingAnchor.constraint(equalTo: trailingAnchor), imageHeight,
            labels.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 7),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ]
        // The thumbnail sits at the trailing edge, where the quote keeps its still.
        small = [
            image.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            image.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            image.widthAnchor.constraint(equalToConstant: Self.thumbnailSide), image.heightAnchor.constraint(equalToConstant: Self.thumbnailSide),
            bottomAnchor.constraint(greaterThanOrEqualTo: image.bottomAnchor, constant: 8),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: image.leadingAnchor, constant: -10),
            bottomAnchor.constraint(greaterThanOrEqualTo: labels.bottomAnchor, constant: 8), labelsFill,
        ]
        text = [
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `fill` is the quote panel's; `textColor` and `metaColor` the bubble's text and footer colours.
    func configure(_ preview: TimelineLinkPreview, fill: UIColor, textColor: UIColor, metaColor: UIColor) {
        let previous = self.preview
        self.preview = preview
        backgroundColor = fill
        title.text = preview.title
        title.isHidden = preview.title == nil
        summary.text = preview.summary
        summary.isHidden = preview.summary == nil
        host.text = preview.host
        title.textColor = textColor
        summary.textColor = textColor.withAlphaComponent(0.8)
        host.textColor = metaColor
        image.layer.cornerRadius = preview.variant == .small ? 8 : 0
        image.layer.cornerCurve = .continuous
        image.isHidden = preview.variant == .text
        NSLayoutConstraint.deactivate(large + small + text)
        NSLayoutConstraint.activate(preview.variant == .large ? large : preview.variant == .small ? small : text)
        guard previous?.image != preview.image || previous?.url != preview.url else { return }
        showImage(preview.image)
    }

    /// The card is `width` points wide: the large image takes the full width at its own aspect, between 120 and 220 pt.
    func fit(width: CGFloat) {
        guard let preview, preview.variant == .large else { return }
        let aspect = max(0.1, preview.imageAspectRatio ?? 1.91)
        imageHeight.constant = min(Self.largeImageHeights.upperBound, max(Self.largeImageHeights.lowerBound, (width / aspect).rounded()))
    }

    private func showImage(_ source: TimelineLinkPreview.Image?) {
        image.image = nil
        guard let source else { return }
        if let hit = Self.cached(source) { image.image = hit; return }
        Task { [weak self] in
            let decoded = await Self.decode(source)
            guard let self, self.preview?.image == source else { return }
            image.image = decoded
        }
    }

    // NSCache is thread-safe; the annotation only tells the compiler so.
    nonisolated(unsafe) private static let decoded = NSCache<NSString, UIImage>()

    private nonisolated static func key(_ source: TimelineLinkPreview.Image) -> NSString {
        switch source {
        case .file(let url): "file:" + url.path as NSString
        case .data(let data): "data:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() as NSString
        }
    }

    private static func cached(_ source: TimelineLinkPreview.Image) -> UIImage? { decoded.object(forKey: key(source)) }

    /// Bounded decoding: an embedded image is at most 64 KiB and a fetched one is already downsampled, but neither is
    /// ever inflated beyond what a 280 pt card can show.
    private static func decode(_ source: TimelineLinkPreview.Image) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            let imageSource: CGImageSource? = switch source {
            case .file(let url): CGImageSourceCreateWithURL(url as CFURL, options)
            case .data(let data): CGImageSourceCreateWithData(data as CFData, options)
            }
            guard let imageSource, let cg = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 840] as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cg)
            decoded.setObject(image, forKey: key(source))
            return image
        }.value
    }
}
#endif
