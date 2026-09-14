import SwiftUI
import UIKit

struct TimelineReply: Sendable, Equatable {
    let author: String
    let body: String
}

struct TimelineMessage: Identifiable, Sendable, Equatable {
    let id: String
    let body: String
    let isOutgoing: Bool
    let isStarred: Bool
    var sentAt: Date? = nil
    var status: Status? = nil
    var reply: TimelineReply? = nil
    var securityNotice: String? = nil

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
    var onReply: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> ConversationTimelineController {
        ConversationTimelineController()
    }

    func updateUIViewController(_ controller: ConversationTimelineController, context: Context) {
        controller.update(messages: messages, onToggleStar: onToggleStar, onRetryMessage: onRetryMessage, onReply: onReply)
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
    private var onReply: (String) -> Void = { _ in }
    private var previousSize: CGSize = .zero
    private var revision = 0
    private var followsBottom = true
    private weak var contentPopGesture: UIGestureRecognizer?
    private var contentPopWasEnabled = false

    override func loadView() {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64)))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64)),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = .init(top: 12, leading: 0, bottom: 12, trailing: 0)
        collectionView = ConversationCollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
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
            cell.configure(message: message, toggleStar: { [weak self] in self?.onToggleStar(id) }, retry: { [weak self] in self?.onRetryMessage(id) }, reply: { [weak self] in self?.onReply(id) })
            return cell
        }
    }

    func update(messages incoming: [TimelineMessage], onToggleStar: @escaping (String) -> Void, onRetryMessage: @escaping (String) -> Void = { _ in }, onReply: @escaping (String) -> Void = { _ in }) {
        loadViewIfNeeded()
        self.onToggleStar = onToggleStar
        self.onRetryMessage = onRetryMessage
        self.onReply = onReply
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reserveContentSwipeForReply()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reserveContentSwipeForReply()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let contentPopGesture { contentPopGesture.isEnabled = contentPopWasEnabled }
        contentPopGesture = nil
    }

    private func reserveContentSwipeForReply() {
        guard contentPopGesture == nil else { return }
        guard let gesture = navigationController?.interactiveContentPopGestureRecognizer else {
            return
        }
        contentPopWasEnabled = gesture.isEnabled
        contentPopGesture = gesture
        gesture.isEnabled = false
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
private final class MessageBubbleCell: UICollectionViewCell, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    private var message: TimelineMessage?
    private var toggleStar: () -> Void = {}
    private var retry: () -> Void = {}
    private var replyAction: () -> Void = {}
    private var swipeReplyAction: (() -> Void)?
    private var crossedReplyThreshold = false
    private let replyFeedback = UIImpactFeedbackGenerator(style: .light)
    private let quote = UIView()
    private let quoteAuthor = UILabel()
    private let quoteBody = UILabel()
    private var plainTextTop: NSLayoutConstraint!
    private var replyTextTop: NSLayoutConstraint!
    private var selectAfterDismissal = false
    private let bubble = UIView()
    private let replyIndicator = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private var replyIndicatorLeading: NSLayoutConstraint!
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
        replyIndicator.translatesAutoresizingMaskIntoConstraints = false
        replyIndicator.tintColor = .systemIndigo
        replyIndicator.contentMode = .scaleAspectFit
        replyIndicator.alpha = 0
        replyIndicator.isAccessibilityElement = false
        contentView.addSubview(replyIndicator)
        contentView.addSubview(bubble)
        replyIndicatorLeading = replyIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28)
        NSLayoutConstraint.activate([
            replyIndicatorLeading,
            replyIndicator.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            replyIndicator.widthAnchor.constraint(equalToConstant: 24),
            replyIndicator.heightAnchor.constraint(equalToConstant: 24)
        ])
        bubble.addInteraction(UIContextMenuInteraction(delegate: self))
        let replyPan = UIPanGestureRecognizer(target: self, action: #selector(handleReplyPan(_:)))
        replyPan.maximumNumberOfTouches = 1
        replyPan.delegate = self
        bubble.addGestureRecognizer(replyPan)
        quote.translatesAutoresizingMaskIntoConstraints = false
        quote.isUserInteractionEnabled = false
        quote.isAccessibilityElement = false
        bubble.addSubview(quote)
        let quoteBar = UIView()
        quoteBar.translatesAutoresizingMaskIntoConstraints = false
        quoteBar.backgroundColor = .systemIndigo
        quoteBar.layer.cornerRadius = 1.5
        quote.addSubview(quoteBar)
        let quoteLabels = UIStackView(arrangedSubviews: [quoteAuthor, quoteBody])
        quoteLabels.translatesAutoresizingMaskIntoConstraints = false
        quoteLabels.axis = .vertical
        quoteLabels.spacing = 2
        quote.addSubview(quoteLabels)
        quoteAuthor.font = .preferredFont(forTextStyle: .caption1)
        quoteAuthor.textColor = .label
        quoteAuthor.numberOfLines = 1
        quoteBody.font = .preferredFont(forTextStyle: .subheadline)
        quoteBody.textColor = .secondaryLabel
        quoteBody.numberOfLines = 2
        for label in [quoteAuthor, quoteBody] {
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
        }
        NSLayoutConstraint.activate([
            quote.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            quote.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            quote.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            quoteBar.leadingAnchor.constraint(equalTo: quote.leadingAnchor),
            quoteBar.topAnchor.constraint(equalTo: quote.topAnchor),
            quoteBar.bottomAnchor.constraint(equalTo: quote.bottomAnchor),
            quoteBar.widthAnchor.constraint(equalToConstant: 3),
            quoteLabels.leadingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: 7),
            quoteLabels.trailingAnchor.constraint(equalTo: quote.trailingAnchor),
            quoteLabels.topAnchor.constraint(equalTo: quote.topAnchor),
            quoteLabels.bottomAnchor.constraint(equalTo: quote.bottomAnchor)
        ])
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
        plainTextTop = textView.topAnchor.constraint(equalTo: bubble.topAnchor)
        replyTextTop = textView.topAnchor.constraint(equalTo: quote.bottomAnchor)
        plainTextTop.isActive = true
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bubbleWidth,
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
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
        var quoteWidth: CGFloat = 0
        if let reply = message?.reply {
            let limit = min(220, maximumTextWidth - 10)
            let bodyWidth = (reply.body as NSString).boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: quoteBody.font!], context: nil).width
            let authorWidth = (reply.author as NSString).size(withAttributes: [.font: quoteAuthor.font!]).width
            quoteWidth = min(limit, max(bodyWidth, authorWidth)) + 34
        }
        bubbleWidth.constant = min(maximumTextWidth + 24, max(quoteWidth, max(metadataWidth, max(44, ceil(measured.width) + 25))))
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !isSelectingText, let message,
              UIBezierPath(roundedRect: bubble.bounds, cornerRadius: 20).contains(location) else { return nil }
        let starAction = toggleStar
        let retryAction = retry
        let reply = replyAction
        return UIContextMenuConfiguration(identifier: message.id as NSString, previewProvider: nil) { [weak self] _ in
            guard self != nil else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in reply() },
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

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: contentView)
        return !isSelectingText && messageID != nil && pan.location(in: window).x > 24
            && UIBezierPath(roundedRect: bubble.bounds, cornerRadius: 20).contains(pan.location(in: bubble))
            && velocity.x > 0 && velocity.x > abs(velocity.y) * 1.5
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
    }


    @objc private func handleReplyPan(_ pan: UIPanGestureRecognizer) {
        let distance = max(0, pan.translation(in: contentView).x)
        switch pan.state {
        case .began:
            replyIndicatorLeading.constant = bubble.frame.minX + 12
            swipeReplyAction = replyAction
            crossedReplyThreshold = false
            replyFeedback.prepare()
        case .changed:
            bubble.transform = CGAffineTransform(translationX: min(80, distance), y: 0)
            replyIndicator.alpha = min(1, distance / 56)
            if distance >= 56, !crossedReplyThreshold {
                crossedReplyThreshold = true
                replyFeedback.impactOccurred()
            }
        case .ended:
            let reply = distance >= 56 ? swipeReplyAction : nil
            resetReplySwipe(animated: true)
            reply?()
        case .cancelled, .failed:
            resetReplySwipe(animated: true)
        default: break
        }
    }

    private func resetReplySwipe(animated: Bool) {
        swipeReplyAction = nil
        replyIndicator.alpha = 0
        crossedReplyThreshold = false
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.bubble.transform = .identity }
        } else {
            bubble.layer.removeAllAnimations()
            bubble.transform = .identity
        }
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
        resetReplySwipe(animated: false)
        _ = textView.resignFirstResponder()
        textView.isSelectable = false
        textView.isUserInteractionEnabled = false
        textView.selectedRange = NSRange(location: 0, length: 0)
        messageID = nil
        message = nil
        selectAfterDismissal = false
    }

    func configure(message: TimelineMessage, toggleStar: @escaping () -> Void, retry: @escaping () -> Void, reply: @escaping () -> Void) {
        self.message = message
        self.toggleStar = toggleStar
        self.retry = retry
        self.replyAction = reply
        if messageID != message.id {
            resetReplySwipe(animated: false)
            _ = textView.resignFirstResponder()
            textView.isSelectable = false
            textView.isUserInteractionEnabled = false
            messageID = message.id
        }
        quote.isHidden = message.reply == nil
        quoteAuthor.text = message.reply?.author
        quoteBody.text = message.reply?.body
        NSLayoutConstraint.deactivate([plainTextTop, replyTextTop])
        (message.reply == nil ? plainTextTop : replyTextTop)?.isActive = true
        let canRetry = message.isOutgoing && message.status?.canRetry == true
        leading.isActive = !message.isOutgoing
        trailing.isActive = message.isOutgoing
        bubble.backgroundColor = message.isOutgoing ? .systemGray5 : .secondarySystemBackground
        textView.textColor = .label
        if textView.text != message.body { textView.text = message.body }
        var descriptions = ["\(message.isOutgoing ? "You" : "Contact"): \(message.body)"]
        if let quote = message.reply { descriptions.append("Replying to \(quote.author): \(quote.body)") }
        if message.isStarred { descriptions.append("starred") }
        if let date = message.sentAt { descriptions.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if message.isOutgoing, let state = message.status { descriptions.append(state.accessibilityDescription) }
        if let notice = message.securityNotice { descriptions.append(notice) }
        textView.accessibilityLabel = descriptions.joined(separator: ", ")
        textView.accessibilityCustomActions = [UIAccessibilityCustomAction(name: message.isStarred ? "Unstar message" : "Star message") { _ in
            toggleStar()
            return true
        }]
        textView.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "Reply") { _ in reply(); return true })
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
        time.text = [message.securityNotice, message.sentAt?.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
        time.isHidden = message.sentAt == nil && message.securityNotice == nil
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

/// A horizontal message action must not start vertical scrolling or keyboard dismissal.
@MainActor
private final class ConversationCollectionView: UICollectionView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.x) > abs(velocity.y) * 1.5 { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
