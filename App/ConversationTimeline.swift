import SwiftUI
import UIKit

struct TimelineMessage: Identifiable, Sendable, Equatable {
    let id: String
    let body: String
    let isOutgoing: Bool
    let isStarred: Bool
    var sentAt: Date? = nil
    var status: Status? = nil

    enum Status: String, Sendable, Equatable {
        case queued, submitting, unconfirmed, failed

        var accessibilityDescription: String {
            switch self {
            case .queued: "Waiting to send"
            case .submitting: "Sending"
            case .unconfirmed: "Delivery unconfirmed"
            case .failed: "Not sent"
            }
        }

        var canRetry: Bool { self == .unconfirmed || self == .failed }
    }
}

/// Native baseline for the first transport milestone. Composer and message state belong to the parent.
struct ConversationTimeline: UIViewControllerRepresentable {
    let messages: [TimelineMessage]
    var onToggleStar: (String) -> Void
    var onRetryMessage: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> ConversationTimelineController {
        ConversationTimelineController()
    }

    func updateUIViewController(_ controller: ConversationTimelineController, context: Context) {
        controller.update(messages: messages, onToggleStar: onToggleStar, onRetryMessage: onRetryMessage)
    }
}

@MainActor
final class ConversationTimelineController: UIViewController, UICollectionViewDelegate {
    private struct Anchor {
        let id: String
        let distanceFromTop: CGFloat
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var messages: [TimelineMessage] = []
    private var messagesByID: [String: TimelineMessage] = [:]
    private var onToggleStar: (String) -> Void = { _ in }
    private var onRetryMessage: (String) -> Void = { _ in }
    private var previousSize: CGSize = .zero
    private var revision = 0
    private var followsBottom = true

    override func loadView() {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64)))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64)),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = .init(top: 12, leading: 0, bottom: 12, trailing: 0)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "conversation.timeline"
        collectionView.register(MessageBubbleCell.self, forCellWithReuseIdentifier: "message")
        view = collectionView
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collection, indexPath, id in
            guard let self, let message = messagesByID[id],
                  let cell = collection.dequeueReusableCell(withReuseIdentifier: "message", for: indexPath) as? MessageBubbleCell else { return nil }
            cell.configure(message: message, toggleStar: { [weak self] in self?.onToggleStar(id) }, retry: { [weak self] in self?.onRetryMessage(id) })
            return cell
        }
    }

    func update(messages incoming: [TimelineMessage], onToggleStar: @escaping (String) -> Void, onRetryMessage: @escaping (String) -> Void = { _ in }) {
        loadViewIfNeeded()
        self.onToggleStar = onToggleStar
        self.onRetryMessage = onRetryMessage
        // The durable store supplies unique IDs. Avoid a diffable crash if a caller repeats an ID.
        var seen = Set<String>()
        let uniqueMessages = incoming.filter { seen.insert($0.id).inserted }
        guard uniqueMessages != messages else { return }
        let shouldFollow = messages.isEmpty || isNearBottom
        let anchor = visibleAnchor()
        let previous = messagesByID
        messages = uniqueMessages
        messagesByID = Dictionary(uniqueKeysWithValues: uniqueMessages.map { ($0.id, $0) })
        revision += 1
        let currentRevision = revision
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(uniqueMessages.map(\.id))
        snapshot.reconfigureItems(uniqueMessages.compactMap { message in
            guard let old = previous[message.id], old != message else { return nil }
            return message.id
        })
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, revision == currentRevision else { return }
            collectionView.layoutIfNeeded()
            if shouldFollow {
                scrollToBottom()
            } else if let anchor, let indexPath = dataSource.indexPath(for: anchor.id),
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                collectionView.contentOffset.y = clampedOffset(attributes.frame.minY - anchor.distanceFromTop)
            }
            followsBottom = isNearBottom
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        if previousSize != size {
            previousSize = size
            if followsBottom { scrollToBottom() }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Layout changes during a keyboard transition are not a user's scroll intent.
        if scrollView.isDragging || scrollView.isDecelerating { followsBottom = isNearBottom }
    }

    private var isNearBottom: Bool {
        collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
            - collectionView.contentOffset.y - collectionView.bounds.height < 80
    }

    private func visibleAnchor() -> Anchor? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        guard let path = visible.first,
              let id = dataSource.itemIdentifier(for: path),
              let attributes = collectionView.layoutAttributesForItem(at: path) else { return nil }
        return Anchor(id: id, distanceFromTop: attributes.frame.minY - collectionView.contentOffset.y)
    }

    private func clampedOffset(_ value: CGFloat) -> CGFloat {
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(minimum, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        return min(maximum, max(minimum, value))
    }

    private func scrollToBottom() {
        collectionView.contentOffset.y = clampedOffset(.greatestFiniteMagnitude)
    }

}

@MainActor
private final class MessageBubbleCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    private var message: TimelineMessage?
    private var toggleStar: () -> Void = {}
    private var retry: () -> Void = {}
    private var selectAfterDismissal = false
    private let bubble = UIView()
    private let textView = MessageTextView()
    private var messageID: String?
    private let footer = UIStackView()
    private let time = UILabel()
    private let status = UIImageView()
    private let star = UIImageView(image: UIImage(systemName: "star.fill"))
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var bubbleWidth: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 20
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)
        bubble.addInteraction(UIContextMenuInteraction(delegate: self))
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isAccessibilityElement = true
        textView.isSelectable = false
        textView.isUserInteractionEnabled = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .init(top: 10, left: 12, bottom: 3, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        // Preview fetching is a separate, explicit feature, never a text rendering side effect.
        textView.dataDetectorTypes = []
        bubble.addSubview(textView)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.axis = .horizontal
        footer.alignment = .center
        footer.spacing = 5
        footer.isAccessibilityElement = false
        bubble.addSubview(footer)
        for symbol in [star, status] {
            symbol.tintColor = .secondaryLabel
            symbol.preferredSymbolConfiguration = .init(textStyle: .caption2, scale: .small)
            symbol.contentMode = .scaleAspectFit
            symbol.isAccessibilityElement = false
            symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        time.font = .preferredFont(forTextStyle: .caption2)
        time.adjustsFontForContentSizeCategory = true
        time.textColor = .secondaryLabel
        time.isAccessibilityElement = false
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        footer.addArrangedSubview(star)
        footer.addArrangedSubview(time)
        footer.addArrangedSubview(status)
        leading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        trailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        bubbleWidth = bubble.widthAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bubbleWidth,
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: bubble.topAnchor),
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            footer.topAnchor.constraint(equalTo: textView.bottomAnchor),
            footer.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: bubble.leadingAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let maximumTextWidth = max(44, min(layoutAttributes.size.width * 0.84, layoutAttributes.size.width - 32) - 24)
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let measured = (textView.text as NSString).boundingRect(
            with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil
        )
        // Reserve the same star space for every message so starring never changes bubble width.
        let metadataWidth = footer.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 24
        bubbleWidth.constant = min(maximumTextWidth + 24, max(metadataWidth, max(44, ceil(measured.width) + 25)))
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !isSelectingText, let message,
              UIBezierPath(roundedRect: bubble.bounds, cornerRadius: 20).contains(location) else { return nil }
        let starAction = toggleStar
        let retryAction = retry
        return UIContextMenuConfiguration(identifier: message.id as NSString, previewProvider: nil) { [weak self] _ in
            guard self != nil else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = message.body
                },
                UIAction(title: "Select text", image: UIImage(systemName: "text.cursor")) { [weak self] _ in
                    self?.selectAfterDismissal = true
                },
                UIAction(title: message.isStarred ? "Unstar message" : "Star message", image: UIImage(systemName: message.isStarred ? "star.slash" : "star")) { _ in starAction() }
            ]
            if message.isOutgoing, message.status?.canRetry == true {
                actions.append(UIAction(title: "Retry message", image: UIImage(systemName: "arrow.clockwise")) { _ in retryAction() })
            }
            return UIMenu(children: actions)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        bubblePreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        bubblePreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        guard selectAfterDismissal else { return }
        selectAfterDismissal = false
        let id = configuration.identifier as? String
        let select = { [weak self] in
            guard let self, messageID == id else { return }
            beginTextSelection()
        }
        if let animator { animator.addCompletion(select) } else { select() }
    }

    private func bubblePreview() -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = bubble.backgroundColor
        parameters.visiblePath = UIBezierPath(roundedRect: bubble.bounds, cornerRadius: 20)
        return UITargetedPreview(view: bubble, parameters: parameters)
    }

    var isSelectingText: Bool { textView.isSelectable }

    func beginTextSelection() {
        guard let window else { return }
        window.endEditing(true)
        textView.isUserInteractionEnabled = true
        textView.isSelectable = true
        textView.becomeFirstResponder()
        textView.selectAll(nil)
        textView.presentSelectionMenu()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        _ = textView.resignFirstResponder()
        textView.isSelectable = false
        textView.isUserInteractionEnabled = false
        textView.selectedRange = NSRange(location: 0, length: 0)
        messageID = nil
        message = nil
        selectAfterDismissal = false
    }

    func configure(message: TimelineMessage, toggleStar: @escaping () -> Void, retry: @escaping () -> Void) {
        self.message = message
        self.toggleStar = toggleStar
        self.retry = retry
        if messageID != message.id {
            _ = textView.resignFirstResponder()
            textView.isSelectable = false
            textView.isUserInteractionEnabled = false
            messageID = message.id
        }
        let canRetry = message.isOutgoing && message.status?.canRetry == true
        leading.isActive = !message.isOutgoing
        trailing.isActive = message.isOutgoing
        bubble.backgroundColor = message.isOutgoing ? .systemGray5 : .secondarySystemBackground
        textView.textColor = .label
        if textView.text != message.body { textView.text = message.body }
        var descriptions = ["\(message.isOutgoing ? "You" : "Contact"): \(message.body)"]
        if message.isStarred { descriptions.append("starred") }
        if let date = message.sentAt { descriptions.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if message.isOutgoing, let state = message.status { descriptions.append(state.accessibilityDescription) }
        textView.accessibilityLabel = descriptions.joined(separator: ", ")
        textView.accessibilityCustomActions = [UIAccessibilityCustomAction(name: message.isStarred ? "Unstar message" : "Star message") { _ in
            toggleStar()
            return true
        }]
        textView.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "Select text") { [weak self] _ in
            self?.beginTextSelection()
            return true
        })
        textView.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "Copy") { _ in
            UIPasteboard.general.string = message.body
            return true
        })
        if canRetry {
            textView.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "Retry message") { _ in retry(); return true })
        }
        star.alpha = message.isStarred ? 1 : 0
        time.text = message.sentAt?.formatted(date: .omitted, time: .shortened)
        time.isHidden = message.sentAt == nil
        status.isHidden = !message.isOutgoing || message.status == nil
        status.tintColor = message.status == .failed ? .systemRed : .secondaryLabel
        switch message.status {
        case .queued: status.image = UIImage(systemName: "clock")
        case .submitting: status.image = UIImage(systemName: "arrow.up.circle")
        case .unconfirmed: status.image = UIImage(systemName: "questionmark.circle")
        case .failed: status.image = UIImage(systemName: "exclamationmark.circle")
        case nil: status.image = nil
        }
    }
}

/// Returning to ordinary reading restores the bubble's single context-menu interaction.
@MainActor
private final class MessageTextView: UITextView {
    private lazy var selectionMenu: UIEditMenuInteraction = {
        let interaction = UIEditMenuInteraction(delegate: nil)
        addInteraction(interaction)
        return interaction
    }()

    func presentSelectionMenu() {
        guard let selectedTextRange else { return }
        let rect = firstRect(for: selectedTextRange)
        selectionMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            selectionMenu.dismissMenu()
            selectedRange = NSRange(location: 0, length: 0)
            isSelectable = false
            isUserInteractionEnabled = false
        }
        return resigned
    }
}
