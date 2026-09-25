import UIKit

/// The day of the messages at the top edge, floating on glass under the bars while the reader scrolls history.
/// The timeline controller places it and decides when it shows; it collapses into the inline day header it stands in
/// for, so both draw the same text in the same font at the same height.
///
/// Decorative: the inline day headers stay the accessible ones, so VoiceOver never reads a date twice.
@MainActor
final class DateChipView: UIView {
    /// Space around the text inside the capsule. The controller aligns the text, not the capsule, with the inline header.
    static let verticalPadding: CGFloat = 4
    static let horizontalPadding: CGFloat = 12

    /// Carries the fade as the next day's header pushes the chip away; the view's own alpha is shown or hidden.
    private let body = UIView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        alpha = 0
        body.frame = bounds
        body.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(body)
        glass.cornerConfiguration = .capsule()
        glass.clipsToBounds = true
        glass.frame = body.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        body.addSubview(glass)
        // The inline header's font (MessageBubbleCell.dateLabel), so the text does not change size as the two swap.
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        glass.contentView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            label.text = newValue
            setNeedsLayout()
        }
    }

    /// 1 at rest; falls to 0 as the next day's header pushes the chip up under the bars.
    var pushFade: CGFloat {
        get { body.alpha }
        set { body.alpha = newValue }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let insetX = Self.horizontalPadding * 2
        let available = CGSize(width: max(0, size.width - insetX), height: .greatestFiniteMagnitude)
        let fit = label.sizeThatFits(available)
        return CGSize(width: ceil(min(fit.width, available.width)) + insetX, height: ceil(fit.height) + Self.verticalPadding * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = glass.contentView.bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
    }
}
