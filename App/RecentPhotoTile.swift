import Photos
import UIKit

final class RecentPhotoTile: UIView {
    private let imageView = UIImageView()
    private let durationLabel = UILabel()
    private let scrim = CAGradientLayer()
    private let dimming = UIView()
    private let badge = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var assetID: String?
    private var request: PHImageRequestID?
    private weak var manager: PHImageManager?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .tertiarySystemFill
        clipsToBounds = true
        cornerConfiguration = .uniformCorners(radius: .fixed(36))
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        scrim.type = .radial
        scrim.colors = [UIColor.black.withAlphaComponent(0.4).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        scrim.startPoint = CGPoint(x: 1, y: 1)
        scrim.endPoint = CGPoint(x: 0.35, y: 0.55)
        layer.addSublayer(scrim)
        durationLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        durationLabel.textColor = .white
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(durationLabel)
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        dimming.frame = bounds
        dimming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(dimming)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        badge.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 13, weight: .bold))
        badge.textAlignment = .center
        badge.layer.cornerRadius = 12
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.borderWidth = 1.5
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            durationLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        // The rail's elements speak for the tiles.
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrim.frame = bounds
    }

    func prepareForReuse() {
        if let request { manager?.cancelImageRequest(request) }
        request = nil
        assetID = nil
        imageView.image = nil
    }

    static func describe(_ asset: PHAsset) -> (duration: String?, label: String) {
        let isVideo = asset.mediaType == .video
        // Int(_:) traps on a NaN or infinite value, and PhotoKit does not promise a finite duration.
        let seconds = asset.duration.isFinite ? Int(min(max(asset.duration, 0), 359_999).rounded()) : 0
        let duration = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        let date = asset.creationDate?.formatted(date: .abbreviated, time: .shortened)
        let label = ([isVideo ? "Video, \(duration)" : "Photo"] + [date].compactMap { $0 }).joined(separator: ", ")
        return (isVideo ? duration : nil, label)
    }

    func show(asset: PHAsset, manager: PHCachingImageManager, side: CGFloat, scale: CGFloat) {
        assetID = asset.localIdentifier
        self.manager = manager
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let id = asset.localIdentifier
        let target = CGSize(width: max(side, 1) * scale, height: max(side, 1) * scale)
        // `@Sendable` so the handler is not main-actor-isolated: Swift would trap on entry if PhotoKit answered on its
        // own queue, which its docs allow.
        request = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { @Sendable [weak self] image, _ in
            let apply = { @MainActor in
                guard let self, self.assetID == id else { return }
                self.imageView.image = image
            }
            if Thread.isMainThread { MainActor.assumeIsolated(apply) } else { DispatchQueue.main.async(execute: apply) }
        }
        let duration = Self.describe(asset).duration
        durationLabel.isHidden = duration == nil
        scrim.isHidden = duration == nil
        durationLabel.text = duration
    }

    func setState(selected position: Int?, loading: Bool, compact: Bool) {
        cornerConfiguration = .uniformCorners(radius: .fixed(compact ? 20 : 36))
        let selected = position != nil
        dimming.isHidden = !(selected || loading)
        badge.isHidden = !selected
        badge.text = position.map(String.init)
        badge.backgroundColor = AccentTheme.current.bubble
        badge.textColor = AccentTheme.current.bubbleText
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}
