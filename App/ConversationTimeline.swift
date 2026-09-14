import SwiftUI
import UIKit

struct TimelineMessage: Identifiable, Sendable, Equatable {
    let id: String
    let body: String
    let isOutgoing: Bool
    let isStarred: Bool
}

/// Native baseline for the first transport milestone. Composer and message state belong to the parent.
struct ConversationTimeline: UIViewControllerRepresentable {
    let messages: [TimelineMessage]
    var onToggleStar: (String) -> Void

    func makeUIViewController(context: Context) -> ConversationTimelineController {
        ConversationTimelineController()
    }

    func updateUIViewController(_ controller: ConversationTimelineController, context: Context) {
        controller.update(messages: messages, onToggleStar: onToggleStar)
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
            cell.configure(message: message) { [weak self] in self?.onToggleStar(id) }
            return cell
        }
    }

    func update(messages incoming: [TimelineMessage], onToggleStar: @escaping (String) -> Void) {
        loadViewIfNeeded()
        self.onToggleStar = onToggleStar
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

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let message = messagesByID[id] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: message.isStarred ? "Unstar message" : "Star message", image: UIImage(systemName: message.isStarred ? "star.slash" : "star")) { [weak self] _ in
                self?.onToggleStar(id)
            }])
        }
    }
}

@MainActor
private final class MessageBubbleCell: UICollectionViewCell, UITextViewDelegate {
    private var toggleStar: () -> Void = {}
    private var isStarred = false
    private let bubble = UIView()
    private let textView = UITextView()
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
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .init(top: 10, left: 12, bottom: 10, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        // Do not auto-fetch or auto-detect URLs in this initial text-only renderer.
        textView.dataDetectorTypes = []
        bubble.addSubview(textView)
        star.translatesAutoresizingMaskIntoConstraints = false
        star.tintColor = .secondaryLabel
        star.preferredSymbolConfiguration = .init(textStyle: .caption2)
        star.isAccessibilityElement = false
        contentView.addSubview(star)
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
            textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            star.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 12),
            star.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let maximumTextWidth = max(44, layoutAttributes.size.width * 0.84 - 24)
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let measured = (textView.text as NSString).boundingRect(
            with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil
        )
        bubbleWidth.constant = min(maximumTextWidth + 24, max(44, ceil(measured.width) + 25))
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    private var starPosition: NSLayoutConstraint?

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        // Native text selection may win the long press over the collection context menu.
        // Keep organization available in both paths without replacing Copy / Select All.
        let starAction = UIAction(title: isStarred ? "Unstar message" : "Star message", image: UIImage(systemName: isStarred ? "star.slash" : "star")) { [weak self] _ in
            self?.toggleStar()
        }
        return UIMenu(children: [starAction] + suggestedActions)
    }

    func configure(message: TimelineMessage, toggleStar: @escaping () -> Void) {
        self.toggleStar = toggleStar
        isStarred = message.isStarred
        leading.isActive = !message.isOutgoing
        trailing.isActive = message.isOutgoing
        bubble.backgroundColor = message.isOutgoing ? .secondarySystemFill : .tertiarySystemFill
        textView.textColor = .label
        textView.text = message.body
        textView.accessibilityLabel = "\(message.isOutgoing ? "You" : "Contact"): \(message.body)\(message.isStarred ? ", starred" : "")"
        textView.accessibilityCustomActions = [UIAccessibilityCustomAction(name: message.isStarred ? "Unstar message" : "Star message") { _ in
            toggleStar()
            return true
        }]
        star.isHidden = !message.isStarred
        starPosition?.isActive = false
        starPosition = message.isOutgoing
            ? star.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -3)
            : star.leadingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: 3)
        starPosition?.isActive = true
    }
}
