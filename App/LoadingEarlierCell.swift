import UIKit

final class LoadingEarlierCell: UICollectionViewCell {
    static let label = "Loading earlier messages"
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let text = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.hidesWhenStopped = false
        spinner.color = .secondaryLabel
        text.text = Self.label + "…"
        text.font = .preferredFont(forTextStyle: .footnote)
        text.adjustsFontForContentSizeCategory = true
        text.textColor = .secondaryLabel
        text.numberOfLines = 0
        text.textAlignment = .center
        let row = UIStackView(arrangedSubviews: [spinner, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        let height = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        NSLayoutConstraint.activate([
            height,
            row.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            row.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
        ])
        isAccessibilityElement = true
        accessibilityLabel = Self.label
        accessibilityTraits = [.updatesFrequently]
        accessibilityIdentifier = "timeline.loadingEarlier"
        spinner.startAnimating()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func startAnimating() { spinner.startAnimating() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { spinner.startAnimating() }
    }
}
