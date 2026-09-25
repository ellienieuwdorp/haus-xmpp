import MessageStore
import QuickLook
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct TimelineReply: Sendable, Equatable {
    let author: String
    let body: String
}

struct TimelineReaction: Sendable, Equatable {
    let emoji: String
    let count: Int
    let isSelected: Bool

    static let choices = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
    static func name(for emoji: String) -> String {
        switch emoji {
        case "❤️": "heart"
        case "👍": "thumbs up"
        case "😂": "tears of joy"
        case "😮": "surprised"
        case "😢": "sad"
        case "🙏": "folded hands"
        default: emoji
        }
    }
    var accessibilityDescription: String {
        "\(count) \(Self.name(for: emoji)) \(count == 1 ? "reaction" : "reactions")" + (isSelected ? ", including you" : "")
    }
}

struct TimelineAttachment: Sendable, Equatable {
    let name: String
    let mediaType: String
    let size: Int
    let width: Int?
    let height: Int?
    /// Plaintext on disk once sent or downloaded and verified; nil while it is still fetching.
    var localURL: URL? = nil
    var isImage: Bool { mediaType.hasPrefix("image/") }
    var isVideo: Bool { mediaType.hasPrefix("video/") }
    var showsPreview: Bool { isImage || isVideo }
    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 4 / 3 }
        return CGFloat(width) / CGFloat(height)
    }
    var kindLabel: String { isImage ? "Photo" : isVideo ? "Video" : "File" }
}

struct TimelineMessage: Identifiable, Sendable, Equatable {
    let id: String
    let body: String
    let isOutgoing: Bool
    let isStarred: Bool
    var attachment: TimelineAttachment? = nil
    var sentAt: Date? = nil
    var status: Status? = nil
    var reply: TimelineReply? = nil
    var securityNotice: String? = nil
    var reactions: [TimelineReaction] = []
    var canReact: Bool = false
    /// Shown under a disabled reaction row; nil when `canReact`.
    var reactionUnavailableReason: String? = nil
    var author: String? = nil
    /// The sender unsent it: `body` is empty and the bubble shows a quiet placeholder.
    var isRetracted = false
    /// `body` is the sender's latest correction.
    var isEdited = false
    var canEdit = false
    var canUnsend = false
    /// This device could not show the message; `body` is empty and the bubble shows the reason as a quiet placeholder.
    var unreadable: UnreadableReason? = nil

    /// Unsent or unreadable: the bubble keeps its shape and time, and its text is a quiet italic notice.
    var showsPlaceholder: Bool { isRetracted || unreadable != nil }
    var placeholder: String {
        if let unreadable { return UnreadableCopy.bubble(unreadable, isOutgoing: isOutgoing) }
        return isOutgoing ? "You unsent a message" : "Message unsent"
    }

    enum Status: String, Sendable, Equatable {
        case queued, submitting, unconfirmed, failed, serverAccepted, delivered, displayed

        var accessibilityDescription: String {
            switch self {
            case .queued: "Waiting to send"
            case .submitting: "Sending"
            case .unconfirmed: "Sending, not yet confirmed"
            case .failed: "Not sent"
            case .serverAccepted: "Sent"
            case .delivered: "Delivered"
            case .displayed: "Read"
            }
        }

        var canRetry: Bool { self == .unconfirmed || self == .failed }
    }
}

/// One place for the words; the bubble, the chat list and VoiceOver read the same ones.
enum UnreadableCopy {
    static func bubble(_ reason: UnreadableReason, isOutgoing: Bool) -> String {
        switch reason {
        case .notForThisDevice: isOutgoing ? "Sent from another device and not encrypted for this iPhone" : "Not encrypted for this iPhone"
        case .unsupportedEncryption, .malformedContent, .decryptFailed: "Couldn't read this message"
        }
    }
    static func preview(_ reason: UnreadableReason) -> String {
        switch reason {
        case .notForThisDevice: "Not encrypted for this iPhone"
        case .unsupportedEncryption, .malformedContent, .decryptFailed: "Couldn't read this message"
        }
    }
}

/// Which status mark a sent message shows. A socket write is not delivery: until the server accepts the
/// message it keeps the dashed sending ring, spinning only while the outbox is actively working on it.
enum MessageStatusGlyph: Equatable, Sendable {
    case sending(spinning: Bool), sent, delivered, read, failed

    static func glyph(for status: TimelineMessage.Status) -> MessageStatusGlyph {
        switch status {
        case .queued, .submitting: .sending(spinning: true)
        case .unconfirmed: .sending(spinning: false)
        case .failed: .failed
        case .serverAccepted: .sent
        case .delivered: .delivered
        case .displayed: .read
        }
    }

    /// Only a server-held message carries a check.
    var showsCheck: Bool {
        switch self {
        case .sent, .delivered, .read: true
        case .sending, .failed: false
        }
    }
}

/// Someone is typing: a received-style bubble of dots after the newest message.
struct TimelineTyping: Sendable, Equatable {
    /// Group only: who, above the bubble like a message author.
    let author: String?
    /// The author colour's key, so the line matches that sender's messages.
    let colorKey: String
    let accessibilityLabel: String
}

/// A message plus what its neighbours decide: day header, run start (spacing, sender name) and run end (tail corner).
struct TimelineRow: Equatable {
    let message: TimelineMessage
    let dateHeader: String?
    let startsRun: Bool
    let endsRun: Bool

    static func rows(for messages: [TimelineMessage]) -> [TimelineRow] {
        let calendar = Calendar.current
        var headers: [String?] = []
        var starts: [Bool] = []
        var lastDay: Date?
        for (index, message) in messages.enumerated() {
            var header: String?
            if let date = message.sentAt {
                if lastDay.map({ !calendar.isDate($0, inSameDayAs: date) }) ?? true {
                    header = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday" : date.formatted(date: .abbreviated, time: .omitted)
                }
                lastDay = date
            }
            let previous = index > 0 ? messages[index - 1] : nil
            let continues = previous.map { $0.isOutgoing == message.isOutgoing && $0.author == message.author } ?? false
            headers.append(header)
            starts.append(header != nil || !continues)
        }
        return messages.indices.map { index in
            TimelineRow(message: messages[index], dateHeader: headers[index], startsRun: starts[index],
                        endsRun: index == messages.count - 1 || starts[index + 1])
        }
    }
}

/// Native baseline for the first transport milestone. Composer and message state belong to the parent.
struct ConversationTimeline: UIViewControllerRepresentable {
    let messages: [TimelineMessage]
    var typing: TimelineTyping? = nil
    /// The server's older history is being fetched for this chat: a quiet cell sits above the oldest message.
    var loadingEarlier = false
    /// SwiftUI banners floating over the top edge. UIKit only sees the navigation bar as safe area, so this adds theirs.
    var topBannerHeight: CGFloat = 0
    /// Hosted above the keyboard by the controller; nil hides it (search).
    var composer: AnyView? = nil
    var onToggleStar: (String) -> Void
    var onRetryMessage: (String) -> Void = { _ in }
    var onReply: (String) -> Void = { _ in }
    var onReaction: (String, String) -> Void = { _, _ in }
    var onEdit: (String) -> Void = { _ in }
    var onUnsend: (String) -> Void = { _ in }
    /// A placeholder's "Encryption details" action; the parent owns navigation.
    var onOpenEncryption: () -> Void = {}
    /// A received message's cell came on screen; the model decides whether that is a read marker.
    var onDisplayed: (String) -> Void = { _ in }
    /// The long-press menu put the keyboard away and nothing else claimed focus; bring it back.
    var onRestoreComposerFocus: () -> Void = {}
    /// The user scrolled to the oldest loaded message.
    var onReachTop: () -> Void = {}
    /// Its hidden responder is installed in the controller's view, so the attachment panel is the keyboard here.
    var attachmentKeyboard: AttachmentKeyboard? = nil
    // Observed so a stored accent change re-renders visible bubbles.
    private var accent: String { AccentTheme.current.rawValue }

    func makeUIViewController(context: Context) -> ConversationTimelineController {
        ConversationTimelineController()
    }

    func updateUIViewController(_ controller: ConversationTimelineController, context: Context) {
        if controller.additionalSafeAreaInsets.top != topBannerHeight { controller.additionalSafeAreaInsets.top = topBannerHeight }
        controller.setComposer(composer)
        controller.update(messages: messages, typing: typing, loadingEarlier: loadingEarlier, accent: accent, onToggleStar: onToggleStar, onRetryMessage: onRetryMessage, onReply: onReply, onReaction: onReaction, onEdit: onEdit, onUnsend: onUnsend,
                          onOpenEncryption: onOpenEncryption, onDisplayed: onDisplayed)
        controller.onRestoreComposerFocus = onRestoreComposerFocus
        controller.onReachTop = onReachTop
        controller.attachmentKeyboard = attachmentKeyboard
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
    private var rows: [TimelineRow] = []
    private var rowsByID: [String: TimelineRow] = [:]
    /// The typing bubble is the last item when someone types; no stored message ID contains a NUL.
    private static let typingID = "typing\u{0}"
    /// The loading-earlier cell is the first item while the model backfills this chat's archive.
    static let loadingEarlierID = "loading-earlier\u{0}"
    private var typing: TimelineTyping?
    private var loadingEarlier = false
    private var typingArrived = false
    private var accent = ""
    private var onToggleStar: (String) -> Void = { _ in }
    private var onRetryMessage: (String) -> Void = { _ in }
    private var onReply: (String) -> Void = { _ in }
    private var onReaction: (String, String) -> Void = { _, _ in }
    private var onEdit: (String) -> Void = { _ in }
    private var onUnsend: (String) -> Void = { _ in }
    private var onOpenEncryption: () -> Void = {}
    private var onDisplayed: (String) -> Void = { _ in }
    private var previousSize: CGSize = .zero
    private var revision = 0
    private var followsBottom = true
    private let composerHost = UIHostingController(rootView: AnyView(EmptyView()))
    var onRestoreComposerFocus: () -> Void = {}
    var onReachTop: () -> Void = {}
    /// While the long-press menu is up the timeline holds still: its snapshot sits at the bubble's captured frame.
    private var actionsVisible = false
    private var heldUpdate: (() -> Void)?
    private var restoresKeyboard = false
    private var sliding = false
    /// The update whose slide is playing; a later slide replaces it and settles the offset itself.
    private var slideRevision = 0
    private var bottomInset: CGFloat = 0
    private var composerHeight: NSLayoutConstraint!
    /// Content position at the visible bottom edge, so an inset change can put the same messages back above the composer.
    private var bottomEdgeY: CGFloat = 0
    private var knownSafeBottom: CGFloat = 0
    private var knownAdjustedTop: CGFloat = 0
    /// The day under the top edge while the reader scrolls history (Signal's sticky date). It stands in for that day's
    /// inline header, whose text is covered while the chip shows, so the same date never appears twice.
    private let dateChip = DateChipView()
    /// The previous day's chip dissolving in place while the next one takes over.
    private let leavingDateChip = DateChipView()
    /// Between the reader's first drag and a second after the list comes to rest; programmatic scrolls never start it.
    private var dateChipActive = false
    private var dateChipIdle: DispatchWorkItem?
    /// The idle second came due under a resting finger; it starts over when the finger lifts.
    private var dateChipWaitsForLift = false
    /// The offset of the last deceleration step large enough to see.
    private var dateChipMovingY: CGFloat = 0
    /// The message whose inline day header the chip currently covers.
    private var coveredHeaderID: String?

    override func loadView() {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64)))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64)),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        // 2pt inside a run; a run's first cell adds its own 6pt on top.
        section.interGroupSpacing = 2
        section.contentInsets = .init(top: 8, leading: 0, bottom: 12, trailing: 0)
        collectionView = ConversationCollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        // Clear over the container, which paints the chat background once; the collection view runs under the bars,
        // where the scroll-edge effect (below) dissolves the messages that scroll beneath.
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "conversation.timeline"
        collectionView.register(MessageBubbleCell.self, forCellWithReuseIdentifier: "message")
        collectionView.register(TypingIndicatorCell.self, forCellWithReuseIdentifier: "typing")
        collectionView.register(LoadingEarlierCell.self, forCellWithReuseIdentifier: "loadingEarlier")
        collectionView.addGestureRecognizer(TouchGate(down: { [weak self] point in self?.reserveSwipe(forBubbleAt: point) }, up: { [weak self] in self?.releaseSwipe() }))
        let container = UIView()
        container.backgroundColor = .systemBackground
        collectionView.frame = container.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(collectionView)
        // The navigation bar's soft scroll-edge effect dissolves messages under the bar (Signal's iOS 26 look: no
        // material strip, no hairline). SwiftUI's banner bar is invisible to UIKit, so this clear, touch-transparent
        // container spans bar plus banners (the safe area includes the banner inset) and extends the effect below them.
        let topEdge = UIView()
        topEdge.isUserInteractionEnabled = false
        topEdge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topEdge)
        let topEdgeInteraction = UIScrollEdgeElementContainerInteraction()
        topEdgeInteraction.scrollView = collectionView
        topEdgeInteraction.edge = .top
        topEdge.addInteraction(topEdgeInteraction)
        NSLayoutConstraint.activate([
            topEdge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topEdge.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topEdge.topAnchor.constraint(equalTo: container.topAnchor),
            topEdge.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
        ])
        // The date chips sit above the edge effect so they stay legible while it dissolves the messages.
        container.addSubview(leavingDateChip)
        container.addSubview(dateChip)
        // The composer rides the keyboard guide, so it follows an interactive dismiss; SwiftUI's own avoidance is off.
        composerHost.safeAreaRegions = []
        composerHeight = composerHost.view.heightAnchor.constraint(equalToConstant: 60)
        composerHost.view.backgroundColor = .clear
        composerHost.view.translatesAutoresizingMaskIntoConstraints = false
        composerHost.view.isHidden = true
        addChild(composerHost)
        container.addSubview(composerHost.view)
        NSLayoutConstraint.activate([
            composerHost.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            composerHost.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            composerHost.view.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor),
            composerHeight,
        ])
        composerHost.didMove(toParent: self)
        view = container
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collection, indexPath, id in
            if id == Self.typingID {
                // A snapshot can outlive the typing it was built for; the cell then stays empty until the next apply.
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "typing", for: indexPath)
                let typing = self?.typing
                cell.contentView.isHidden = typing == nil
                if let typing { (cell as? TypingIndicatorCell)?.configure(typing) }
                return cell
            }
            if id == Self.loadingEarlierID {
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "loadingEarlier", for: indexPath)
                (cell as? LoadingEarlierCell)?.startAnimating()
                return cell
            }
            guard let self, let row = rowsByID[id],
                  let cell = collection.dequeueReusableCell(withReuseIdentifier: "message", for: indexPath) as? MessageBubbleCell else { return nil }
            cell.configure(row: row, toggleStar: { [weak self] in self?.onToggleStar(id) }, retry: { [weak self] in self?.onRetryMessage(id) }, reply: { [weak self] in self?.onReply(id) }, reaction: { [weak self] emoji in self?.onReaction(id, emoji) },
                           edit: { [weak self] in self?.onEdit(id) }, unsend: { [weak self] in self?.onUnsend(id) },
                           openEncryption: { [weak self] in self?.onOpenEncryption() },
                           presentActions: { [weak self] context in
                               guard let self, presentedViewController == nil else { return false }
                               guard MessageActionsOverlay.present(from: self, context: context,
                                                                   willDismiss: { [weak self] chosen in self?.actionsWillDismiss(chosen: chosen) ?? false },
                                                                   onDismiss: { [weak self] _ in self?.actionsDismissed() }) else { return false }
                               actionsVisible = true
                               // The bubble was measured with the keyboard up and the overlay now covers the timeline.
                               putKeyboardAwayForActions()
                               return true
                           }, openAttachment: { [weak self] url in self?.preview(url, title: row.message.attachment?.name, isImage: row.message.attachment?.isImage == true) })
            return cell
        }
    }

    /// Photos get the swipe-to-dismiss viewer with Save; Quick Look plays video and shows documents.
    private let previewSource = PreviewSource()
    private func preview(_ url: URL, title: String?, isImage: Bool) {
        guard presentedViewController == nil else { return }
        if isImage, let image = UIImage(contentsOfFile: url.path) {
            present(ImageViewer(image: image, url: url), animated: true)
            return
        }
        previewSource.item = .init(url: url, title: title)
        let viewer = QLPreviewController()
        viewer.dataSource = previewSource
        viewer.delegate = previewSource
        present(viewer, animated: true)
    }

    func update(messages incoming: [TimelineMessage], typing: TimelineTyping? = nil, loadingEarlier: Bool = false, accent: String = "", onToggleStar: @escaping (String) -> Void, onRetryMessage: @escaping (String) -> Void = { _ in }, onReply: @escaping (String) -> Void = { _ in }, onReaction: @escaping (String, String) -> Void = { _, _ in },
                onEdit: @escaping (String) -> Void = { _ in }, onUnsend: @escaping (String) -> Void = { _ in }, onOpenEncryption: @escaping () -> Void = {},
                onDisplayed: @escaping (String) -> Void = { _ in }) {
        loadViewIfNeeded()
        if actionsVisible {
            heldUpdate = { [weak self] in self?.update(messages: incoming, typing: typing, loadingEarlier: loadingEarlier, accent: accent, onToggleStar: onToggleStar, onRetryMessage: onRetryMessage, onReply: onReply, onReaction: onReaction, onEdit: onEdit, onUnsend: onUnsend,
                                                       onOpenEncryption: onOpenEncryption, onDisplayed: onDisplayed) }
            return
        }
        self.onToggleStar = onToggleStar
        self.onRetryMessage = onRetryMessage
        self.onReply = onReply
        self.onReaction = onReaction
        self.onEdit = onEdit
        self.onUnsend = onUnsend
        self.onOpenEncryption = onOpenEncryption
        self.onDisplayed = onDisplayed
        // The durable store supplies unique IDs. Avoid a diffable crash if a caller repeats an ID.
        var seen = Set<String>()
        let uniqueRows = TimelineRow.rows(for: incoming.filter { seen.insert($0.id).inserted })
        let accentChanged = accent != self.accent
        let typingChanged = typing != self.typing
        let loadingChanged = loadingEarlier != self.loadingEarlier
        guard uniqueRows != rows || accentChanged || typingChanged || loadingChanged else { return }
        self.accent = accent
        self.loadingEarlier = loadingEarlier
        let typingLeft = self.typing != nil && typing == nil
        typingArrived = self.typing == nil && typing != nil
        self.typing = typing
        // Only a message arriving at the tail moves, and only when the reader is at the tail; nothing else animates.
        // Judged from the tail alone: the loaded window is the newest N, so its head moves as messages arrive.
        let newIDs = uniqueRows.map(\.message.id)
        let tailStart = rows.last.flatMap { newIDs.lastIndex(of: $0.message.id) }.map { $0 + 1 } ?? newIDs.count
        let appended = tailStart < newIDs.count
        // Sending always returns to the newest message, wherever the reader was.
        let sentOwn = uniqueRows[tailStart...].contains { $0.message.isOutgoing }
        let wasNearBottom = isNearBottom
        let firstContent = rows.isEmpty
        let shouldFollow = firstContent || wasNearBottom || sentOwn
        // From far up in history a send jumps; a slide would cross cells that were never drawn.
        // The typing bubble coming or going at the tail moves the same way as a message arriving.
        let slidesIn = !firstContent && (appended || typingChanged) && wasNearBottom && view.window != nil && !UIAccessibility.isReduceMotionEnabled
        let anchor = visibleAnchor()
        let previous = rowsByID
        rows = uniqueRows
        rowsByID = Dictionary(uniqueKeysWithValues: uniqueRows.map { ($0.message.id, $0) })
        revision += 1
        let currentRevision = revision
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        // Above the oldest message; the anchor below skips it, so it comes and goes without moving the reader.
        if loadingEarlier { snapshot.appendItems([Self.loadingEarlierID]) }
        snapshot.appendItems(uniqueRows.map(\.message.id))
        if typing != nil { snapshot.appendItems([Self.typingID]) }
        var changed = uniqueRows.compactMap { row -> String? in
            guard let old = previous[row.message.id], old != row || accentChanged else { return nil }
            return row.message.id
        }
        if typing != nil, !typingArrived, typingChanged { changed.append(Self.typingID) }
        snapshot.reconfigureItems(changed)
        // A shrinking content size clamps the offset during the apply, so a slide back down starts from here.
        let offsetBefore = collectionView.contentOffset.y
        if typingLeft { fadeOutTypingCell() }
        // Every offset decision happens in this call, before the next frame: waiting for an apply's completion let a
        // frame show a first load at the top of its window, or a prepend at the old offset.
        if firstContent {
            // Nothing on screen to diff against: load the cells in place and land on the newest message at once.
            dataSource.applySnapshotUsingReloadData(snapshot)
            collectionView.layoutIfNeeded()
            scrollToBottom()
            followsBottom = true
            return
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        if dataSource.snapshot().itemIdentifiers != snapshot.itemIdentifiers {
            // A non-animated apply on the main queue is synchronous; if that ever changes, keep the offset logic synchronous.
            assertionFailure("A non-animated diffable apply did not land synchronously")
            dataSource.applySnapshotUsingReloadData(snapshot)
        }
        collectionView.layoutIfNeeded()
        if slidesIn {
            // Settle the final offset first so the new cells exist, then play the distance back.
            let start = typingLeft && !appended ? offsetBefore : collectionView.contentOffset.y
            scrollToBottom()
            let end = collectionView.contentOffset.y
            collectionView.contentOffset.y = start
            sliding = true
            slideRevision = currentRevision
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { self.collectionView.contentOffset.y = end } completion: { [weak self] _ in
                guard let self, slideRevision == currentRevision else { return }
                sliding = false
                if followsBottom { scrollToBottom() }
            }
        } else if shouldFollow {
            followBottom()
        } else if let anchor, let indexPath = dataSource.indexPath(for: anchor.id),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
            collectionView.contentOffset.y = clampedOffset(attributes.frame.minY - anchor.distanceFromTop)
        }
        followsBottom = shouldFollow || isNearBottom
        recordBottomEdge()
    }

    /// The typing bubble leaves as a fading copy; the cell itself goes with the apply.
    private func fadeOutTypingCell() {
        guard let path = dataSource.indexPath(for: Self.typingID), let cell = collectionView.cellForItem(at: path),
              let ghost = cell.snapshotView(afterScreenUpdates: false) else { return }
        ghost.frame = cell.frame
        ghost.isUserInteractionEnabled = false
        collectionView.addSubview(ghost)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) { ghost.alpha = 0 } completion: { _ in ghost.removeFromSuperview() }
    }

    /// Right after the overlay is presented over the captured bubble: the keyboard would cover the menu, so it slides
    /// away with UIKit's own animation and the composer and insets follow it under the blur. Nothing is laid out
    /// synchronously here; the overlay's snapshot never depended on where the timeline settles.
    private func putKeyboardAwayForActions() {
        attachmentKeyboard?.menuWillPresent() // attachment panel: remember it was up; endEditing below resigns it too
        restoresKeyboard = view.keyboardLayoutGuide.layoutFrame.height > view.safeAreaInsets.bottom + 100
        guard restoresKeyboard else { return }
        view.endEditing(true)
    }

    /// As the menu starts to close. The keyboard comes back only when nothing takes its place: reply and edit focus
    /// the composer themselves, text selection and the unsend dialog must keep it away. A plain dismissal, reaction,
    /// copy, star or retry presents nothing, so the keyboard (or the attachment panel, when that was up) starts back
    /// now, under the fading blur, and the timeline rides up with it while the snapshot returns to where the press
    /// found the bubble. Returns true in that case: the live bubble lands there again, not where it is this moment.
    private func actionsWillDismiss(chosen: MessageAction.Kind?) -> Bool {
        let keyboardFree = chosen.map(Self.leavesKeyboardFree) ?? true
        defer { restoresKeyboard = false }
        // The attachment panel reopens itself instead when it was up before the menu.
        if attachmentKeyboard?.menuDismissed(choseAction: !keyboardFree) == true { return true }
        guard restoresKeyboard, keyboardFree else { return false }
        onRestoreComposerFocus()
        return true
    }

    private func actionsDismissed() {
        actionsVisible = false
        heldUpdate?()
        heldUpdate = nil
    }

    private static func leavesKeyboardFree(_ kind: MessageAction.Kind) -> Bool {
        switch kind {
        case .copy, .star, .retry: true
        case .reply, .edit, .selectText, .unsend, .encryptionDetails: false
        }
    }

    /// A rightward swipe that starts on a bubble is a reply; anywhere else it is the system's swipe back. The system
    /// recognizer takes no failure requirement from ours (each ends up waiting for the other), so it is switched off
    /// for the length of a touch that starts on a bubble.
    private weak var reservedPopGesture: UIGestureRecognizer?

    private func reserveSwipe(forBubbleAt point: CGPoint) {
        guard let path = collectionView.indexPathForItem(at: point), let cell = collectionView.cellForItem(at: path) as? MessageBubbleCell,
              cell.bubbleContains(collectionView.convert(point, to: cell)),
              let gesture = navigationController?.interactiveContentPopGestureRecognizer, gesture.isEnabled else { return }
        gesture.isEnabled = false
        reservedPopGesture = gesture
    }

    private func releaseSwipe() {
        reservedPopGesture?.isEnabled = true
        reservedPopGesture = nil
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        releaseSwipe()
        attachmentKeyboard?.close()
    }

    /// The attachment panel's responder lives in this view: its input view is the keyboard to UIKit, so the composer
    /// on the keyboard guide, the insets, interactive dismissal and the message menu all follow the panel unchanged.
    var attachmentKeyboard: AttachmentKeyboard? {
        didSet {
            guard oldValue !== attachmentKeyboard else { return }
            oldValue?.uninstall()
            loadViewIfNeeded()
            attachmentKeyboard?.install(in: self)
        }
    }

    func setComposer(_ composer: AnyView?) {
        loadViewIfNeeded()
        // Search hides the composer; the panel belongs to it and goes too.
        if composer == nil { attachmentKeyboard?.close() }
        composerHost.view.isHidden = composer == nil
        // The composer reports the height it wants at this width; the host's intrinsic size is measured without a
        // width, where a long draft never wraps.
        if let composer {
            composerHost.rootView = AnyView(composer.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    guard let self, abs(composerHeight.constant - height) > 0.5 else { return }
                    composerHeight.constant = height
                    view.setNeedsLayout()
                }
                .frame(maxHeight: .infinity, alignment: .bottom))
        }
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        if previousSize != size {
            previousSize = size
            if followsBottom { followBottom() }
        }
        updateBottomInset()
    }

    /// Messages end above the composer, or above the keyboard while the composer is hidden. This runs inside the
    /// keyboard's animation, so the inset and offset move with it.
    private func updateBottomInset() {
        let top = composerHost.view.isHidden ? view.keyboardLayoutGuide.layoutFrame.minY : composerHost.view.frame.minY
        let inset = max(0, view.bounds.maxY - top)
        // An interactive dismiss starts at the composer's top edge rather than the keyboard's.
        view.keyboardLayoutGuide.keyboardDismissPadding = composerHost.view.isHidden ? 0 : composerHost.view.bounds.height
        // adjustedContentInset adds the safe area back, so the visible inset is exactly `inset`.
        // UIKit shifts the offset itself when the safe area changes under it, so that counts as an inset change too.
        let content = inset - collectionView.safeAreaInsets.bottom
        let safeAreaMoved = abs(collectionView.contentInset.bottom - content) > 0.5
        if safeAreaMoved {
            collectionView.contentInset.bottom = content
            collectionView.verticalScrollIndicatorInsets.bottom = content
        }
        knownSafeBottom = collectionView.safeAreaInsets.bottom
        guard safeAreaMoved || abs(inset - bottomInset) > 0.5 else { return }
        bottomInset = inset
        // A finger on the list owns the offset, as during an interactive keyboard dismissal.
        if !collectionView.isTracking {
            if followsBottom { followBottom() }
            // Reading history: keep the same messages above the composer instead of letting it cover them.
            else { collectionView.contentOffset.y = clampedOffset(bottomEdgeY - collectionView.bounds.height + inset) }
        }
        recordBottomEdge()
    }

    private func recordBottomEdge() { bottomEdgeY = collectionView.contentOffset.y + collectionView.bounds.height - bottomInset }

    /// The composer arrives as bottom safe area after the first apply; keyboard changes come the same way.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if followsBottom { followBottom() }
        view.setNeedsLayout()
    }

    /// A banner appearing, growing or closing changes the top inset. The collection view only takes it in the next
    /// layout pass (after `viewSafeAreaInsetsDidChange`), and UIKit then keeps the message at the top edge in place,
    /// which pushes the newest message behind the composer. While following the bottom, re-clamp to it here, where the
    /// new inset is already in place. Bottom changes stay with `updateBottomInset`.
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        let top = scrollView.adjustedContentInset.top
        guard abs(top - knownAdjustedTop) > 0.5 else { return }
        knownAdjustedTop = top
        guard followsBottom, !sliding, !scrollView.isTracking else { return }
        scrollView.contentOffset.y = clampedOffset(.greatestFiniteMagnitude)
        recordBottomEdge()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let cell = cell as? TypingIndicatorCell {
            cell.startDots()
            if typingArrived { typingArrived = false; cell.animateIn() }
            return
        }
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rowsByID[id], !row.message.isOutgoing else { return }
        onDisplayed(id)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Layout changes during a keyboard transition are not a user's scroll intent.
        // Every move counts, including the nudges self-sizing cells cause, except the shift UIKit makes for a safe-area
        // change this controller has not laid out for yet: that one is undone from the recorded edge.
        if abs(collectionView.safeAreaInsets.bottom - knownSafeBottom) < 0.5 { recordBottomEdge() }
        // Before the guard: page loads and inset changes move a chip that is already up, without ever raising it.
        updateDateChip()
        // Deceleration crawls for a second or more below a point a frame; the chip's second starts when the eye sees rest.
        if scrollView.isDecelerating, abs(scrollView.contentOffset.y - dateChipMovingY) >= 0.5 {
            dateChipMovingY = scrollView.contentOffset.y
            scheduleDateChipIdle()
        }
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        followsBottom = isNearBottom
        // A few screens early, so older messages are usually in place before the reader arrives.
        if scrollView.contentOffset.y + scrollView.adjustedContentInset.top < 1200 { onReachTop() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dateChipIdle?.cancel()
        dateChipWaitsForLift = false
        dateChipActive = true
        updateDateChip()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        dateChipMovingY = scrollView.contentOffset.y
        scheduleDateChipIdle()
    }

    /// The chip leaves a second after the list visibly comes to rest; a new drag cancels that, a held finger keeps it.
    /// A touch that never becomes a drag (a hold, a long press on a bubble) sends no end-of-drag callback, so while a
    /// finger is down the timer checks again shortly and restarts its full second once the finger lifts.
    private func scheduleDateChipIdle(after delay: TimeInterval = 1.0) {
        dateChipIdle?.cancel()
        let idle = DispatchWorkItem { [weak self] in
            guard let self, dateChipActive else { return }
            if collectionView.isTracking {
                dateChipWaitsForLift = true
                scheduleDateChipIdle(after: 0.2)
            } else if dateChipWaitsForLift {
                dateChipWaitsForLift = false
                scheduleDateChipIdle()
            } else {
                dateChipActive = false
                updateDateChip(fade: 0.3)
            }
        }
        dateChipIdle = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: idle)
    }

    /// Where the chip's text sits below the bars and banners; the inline header text it replaces sticks at this line.
    private static let dateChipLine: CGFloat = 12
    /// Gap kept between the chip and the next day's header as that header pushes it up.
    private static let dateChipPushGap: CGFloat = 6

    /// Signal's rule: the last day header whose text has passed the line under the bars sticks, the next one pushes it
    /// up and away, and a header coming back down to the line takes its date back from the chip. The chip's text sits
    /// exactly where the inline text would, so the two swap in place.
    private func updateDateChip(fade: TimeInterval = 0.15) {
        let line = collectionView.contentOffset.y + collectionView.adjustedContentInset.top + Self.dateChipLine
        let stuck = dateChipActive ? stuckDayHeader(line: line) : nil
        let wasShown = dateChip.alpha > 0
        let previous = coveredHeaderID
        // One day's chip handing over to another: the old capsule dissolves where it was, over the header taking its
        // text back, while the new one fades in over the header it covers.
        let handover = wasShown && stuck != nil && previous != nil && previous != stuck?.id
        if handover, dateChip.pushFade > 0.01 {
            UIView.performWithoutAnimation {
                leavingDateChip.text = dateChip.text
                leavingDateChip.pushFade = dateChip.pushFade
                leavingDateChip.frame = dateChip.frame
                leavingDateChip.alpha = 1
                leavingDateChip.layoutIfNeeded()
            }
            UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) { self.leavingDateChip.alpha = 0 }
        }
        let alpha: CGFloat = stuck == nil ? 0 : 1
        // A header crossing the line trades places with the chip in one frame: both texts sit on the line, and the list
        // keeps moving under the fixed chip, so any fade shows the date twice, a few points apart.
        let swap = !handover && (stuck.map { !wasShown && headerTextNearLine($0.id, line: line) }
            ?? (wasShown && dateChipActive && previous.map { headerTextNearLine($0, line: line) } == true))
        // Otherwise text and capsule change together: the fade of whichever chip is arriving or leaving.
        let crossfade = handover ? 0.15 : swap ? 0 : (alpha != dateChip.alpha ? (alpha > 0 ? 0.2 : fade) : 0)
        if stuck?.id != previous {
            if let previous { dateHeaderCell(for: previous)?.coverDateHeader(false, fade: crossfade) }
            coveredHeaderID = stuck?.id
            // The inline text clears at once and only the capsule fades: the list keeps moving under a fixed chip, so
            // a dissolving inline date would show beside the chip's for a few frames.
            if let id = stuck?.id { dateHeaderCell(for: id)?.coverDateHeader(true, fade: 0) }
        } else if let id = stuck?.id {
            // A recycled cell comes back with its text showing.
            dateHeaderCell(for: id)?.coverDateHeader(true, fade: 0)
        }
        if let stuck {
            UIView.performWithoutAnimation {
                dateChip.text = stuck.text
                let bounds = view.bounds
                let size = dateChip.sizeThatFits(CGSize(width: bounds.width - 32, height: .greatestFiniteMagnitude))
                let restTop = line - DateChipView.verticalPadding
                var top = restTop
                if let next = stuck.nextTextTop { top = min(restTop, next - Self.dateChipPushGap - size.height) }
                let push = restTop - top
                // Gone by the time it reaches the bars. Reduce Motion: it fades where it is instead of sliding.
                dateChip.pushFade = max(0, min(1, 1 - push / max(1, Self.dateChipLine + size.height / 2)))
                if UIAccessibility.isReduceMotionEnabled { top = restTop }
                let scale = max(1, view.traitCollection.displayScale)
                let y = ((top - collectionView.contentOffset.y) * scale).rounded() / scale
                let x = ((bounds.width - size.width) / 2 * scale).rounded() / scale
                dateChip.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                dateChip.layoutIfNeeded()
                if handover { dateChip.alpha = 0 }
            }
        }
        guard dateChip.alpha != alpha else { return }
        UIView.animate(withDuration: crossfade, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.dateChip.alpha = alpha
        }
    }

    /// The stuck header's message ID and text, and where the next day's header text is when it is on screen.
    private func stuckDayHeader(line: CGFloat) -> (id: String, text: String, nextTextTop: CGFloat?)? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        guard let last = visible.last else { return nil }
        // The first item reaching below the line: its day, or the day of the header before it, is under the chip.
        let current = visible.first { (collectionView.layoutAttributesForItem(at: $0)?.frame.maxY ?? 0) > line } ?? last
        func header(_ item: Int) -> (id: String, text: String)? {
            guard item >= 0, let id = dataSource.itemIdentifier(for: IndexPath(item: item, section: 0)),
                  let text = rowsByID[id]?.dateHeader else { return nil }
            return (id, text)
        }
        func textTop(_ item: Int) -> CGFloat? {
            collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0)).map { $0.frame.minY + MessageBubbleCell.dateHeaderTop }
        }
        var stuckItem: Int?
        var nextSearch = current.item
        if header(current.item) != nil, let top = textTop(current.item), top < line {
            stuckItem = current.item
            nextSearch = current.item + 1
        } else {
            // The loaded window always opens on a header, so this walk is bounded by one day of messages.
            var item = current.item - 1
            while item >= 0, stuckItem == nil {
                if header(item) != nil { stuckItem = item }
                item -= 1
            }
        }
        // Nothing has passed the line: the top of history, where the first header is still in place.
        guard let stuckItem, let stuck = header(stuckItem) else { return nil }
        var nextTextTop: CGFloat?
        if nextSearch <= last.item {
            for item in nextSearch...last.item where header(item) != nil {
                nextTextTop = textTop(item)
                break
            }
        }
        return (stuck.id, stuck.text, nextTextTop)
    }

    /// Whether this header's text is within a chip's reach of the line, where the chip's text would sit over it.
    private func headerTextNearLine(_ id: String, line: CGFloat) -> Bool {
        guard let path = dataSource.indexPath(for: id), let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return false }
        return abs(frame.minY + MessageBubbleCell.dateHeaderTop - line) < 40
    }

    private func dateHeaderCell(for id: String) -> MessageBubbleCell? {
        dataSource.indexPath(for: id).flatMap { collectionView.cellForItem(at: $0) as? MessageBubbleCell }
    }

    private var isNearBottom: Bool {
        collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
            - collectionView.contentOffset.y - collectionView.bounds.height < 80
    }

    /// The first visible message. Never the loading-earlier cell: anchored on it, its removal would drop the reader.
    private func visibleAnchor() -> Anchor? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        guard let path = visible.first(where: { dataSource.itemIdentifier(for: $0) != Self.loadingEarlierID }),
              let id = dataSource.itemIdentifier(for: path),
              let attributes = collectionView.layoutAttributesForItem(at: path) else { return nil }
        return Anchor(id: id, distanceFromTop: attributes.frame.minY - collectionView.contentOffset.y)
    }

    private func clampedOffset(_ value: CGFloat) -> CGFloat {
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(minimum, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        return min(maximum, max(minimum, value))
    }

    /// A status tick landing mid-slide must not cut it short; the slide settles at the bottom itself.
    private func followBottom() { if !sliding { scrollToBottom() } }

    private func scrollToBottom() {
        // scrollToItem sizes the final cells first; the clamp then lands on the real content height. A cell that
        // self-sizes as it comes on screen changes that height again, so settle until it holds (usually at once).
        if let last = typing != nil ? Self.typingID : rows.last?.message.id, let path = dataSource.indexPath(for: last) {
            collectionView.scrollToItem(at: path, at: .bottom, animated: false)
            collectionView.layoutIfNeeded()
        }
        for _ in 0..<3 {
            let bottom = clampedOffset(.greatestFiniteMagnitude)
            guard abs(collectionView.contentOffset.y - bottom) > 0.5 else { break }
            collectionView.contentOffset.y = bottom
            collectionView.layoutIfNeeded()
        }
        recordBottomEdge()
    }

}

@MainActor
private final class PreviewSource: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
    /// Immutable so Quick Look may read it from any thread. The title is the sender's file
    /// name; the cache file itself is named after its hash.
    final class Item: NSObject, QLPreviewItem, Sendable {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, title: String?) { previewItemURL = url; previewItemTitle = title }
    }
    var item: Item?
    /// A delivered file is not a draft: no Markup.
    func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { item == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item ?? Item(url: URL(fileURLWithPath: "/"), title: nil) }
}

@MainActor
private final class MessageBubbleCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    private static let pillHang: CGFloat = 12
    private var row: TimelineRow?
    private var message: TimelineMessage? { row?.message }
    private var openAttachment: (URL) -> Void = { _ in }
    private let attachmentArea = UIView()
    private let media = UIImageView()
    private let mediaSpinner = UIActivityIndicatorView(style: .medium)
    private let fileIcon = UIImageView(image: UIImage(systemName: "doc.fill"))
    private let fileName = UILabel()
    private let fileDetail = UILabel()
    private var attachmentHeight: NSLayoutConstraint!
    private var plainAttachmentTop: NSLayoutConstraint!
    private var replyAttachmentTop: NSLayoutConstraint!
    private var textHeight: NSLayoutConstraint!
    /// The time row sits under the caption, or directly under a photo that has none.
    private var footerAfterText: NSLayoutConstraint!
    private var footerAfterMedia: NSLayoutConstraint!
    /// The bubble-coloured frame around a photo or video preview, equal on all four sides.
    private static let mediaInset: CGFloat = 3
    /// Space between a caption-less preview's frame and its time row; with the frame it puts the time ink
    /// as far below the photo as it sits above the bubble's bottom edge.
    private static let mediaFooterGap: CGFloat = 5
    private var toggleStar: () -> Void = {}
    private var retry: () -> Void = {}
    private var replyAction: () -> Void = {}
    private var reactionAction: (String) -> Void = { _ in }
    private var editAction: () -> Void = {}
    private var unsendAction: () -> Void = {}
    private var openEncryptionAction: () -> Void = {}
    /// Returns whether the menu opened; when it did not, the cell puts its squeezed bubble back.
    private var presentActions: (MessageActionsContext) -> Bool = { _ in false }
    private let pressFeedback = UIImpactFeedbackGenerator(style: .medium)
    /// Bumped by every press start and end, so a squeeze that completes after the finger lifted presents nothing.
    private var pressGeneration = 0
    /// Recognition after 0.2 s (Signal's), then a 0.2 s squeeze to 0.95; the menu opens when the squeeze completes
    /// under a held finger.
    private static let pressDelay: TimeInterval = 0.2
    private static let squeezeDuration: TimeInterval = 0.2
    private static let squeezedScale: CGFloat = 0.95
    private var swipeReplyAction: (() -> Void)?
    private var crossedReplyThreshold = false
    private let replyFeedback = UIImpactFeedbackGenerator(style: .light)
    private let dateLabel = UILabel()
    /// Space above a day header's text; the floating date chip sticks that text at the same distance under the bars.
    static let dateHeaderTop: CGFloat = 12
    private var dateTop: NSLayoutConstraint!
    private var dateHeight: NSLayoutConstraint!
    private let author = UILabel()
    private var authorHeight: NSLayoutConstraint!
    private var authorTop: NSLayoutConstraint!
    private var bubbleTop: NSLayoutConstraint!
    private var bubbleBottom: NSLayoutConstraint!
    private let quote = UIView()
    private let quoteBar = UIView()
    private let quoteAuthor = UILabel()
    private let quoteBody = UILabel()
    private var plainTextTop: NSLayoutConstraint!
    private var replyTextTop: NSLayoutConstraint!
    private let bubble = UIView()
    private let replyIndicator = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private var replyIndicatorLeading: NSLayoutConstraint!
    private let textView = MessageTextView()
    private var messageID: String?
    private let footer = UIStackView()
    private let reactionRow = UIStackView()
    private var reactionLeading: NSLayoutConstraint!
    private var reactionTrailing: NSLayoutConstraint!
    private let time = UILabel()
    private let status = MessageStatusView()
    private let star = UIImageView(image: UIImage(systemName: "star.fill"))
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var bubbleWidth: NSLayoutConstraint!

    static var incomingBubble: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.149, green: 0.149, blue: 0.165, alpha: 1) : .secondarySystemBackground }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.clipsToBounds = true
        replyIndicator.translatesAutoresizingMaskIntoConstraints = false
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
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = Self.pressDelay
        press.delegate = self
        bubble.addGestureRecognizer(press)
        let replyPan = UIPanGestureRecognizer(target: self, action: #selector(handleReplyPan(_:)))
        replyPan.maximumNumberOfTouches = 1
        replyPan.delegate = self
        bubble.addGestureRecognizer(replyPan)
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .secondaryLabel
        dateLabel.accessibilityTraits = .header
        contentView.addSubview(dateLabel)
        dateTop = dateLabel.topAnchor.constraint(equalTo: contentView.topAnchor)
        dateHeight = dateLabel.heightAnchor.constraint(equalToConstant: 0)
        author.translatesAutoresizingMaskIntoConstraints = false
        author.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        author.adjustsFontForContentSizeCategory = true
        author.numberOfLines = 1
        author.lineBreakMode = .byTruncatingMiddle
        author.isAccessibilityElement = false
        contentView.addSubview(author)
        authorHeight = author.heightAnchor.constraint(equalToConstant: 0)
        authorTop = author.topAnchor.constraint(equalTo: dateLabel.bottomAnchor)
        bubbleTop = bubble.topAnchor.constraint(equalTo: author.bottomAnchor)
        bubbleBottom = bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            dateTop, authorTop, bubbleTop, bubbleBottom,
            dateLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            author.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 13),
            author.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16)
        ])
        quote.translatesAutoresizingMaskIntoConstraints = false
        quote.isUserInteractionEnabled = false
        quote.isAccessibilityElement = false
        quote.layer.cornerRadius = 12
        quote.layer.cornerCurve = .continuous
        bubble.addSubview(quote)
        quoteBar.translatesAutoresizingMaskIntoConstraints = false
        quoteBar.layer.cornerRadius = 1.5
        quote.addSubview(quoteBar)
        let quoteLabels = UIStackView(arrangedSubviews: [quoteAuthor, quoteBody])
        quoteLabels.translatesAutoresizingMaskIntoConstraints = false
        quoteLabels.axis = .vertical
        quoteLabels.spacing = 1
        quote.addSubview(quoteLabels)
        quoteAuthor.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        quoteAuthor.numberOfLines = 1
        quoteBody.font = .preferredFont(forTextStyle: .footnote)
        quoteBody.numberOfLines = 1
        quoteBody.alpha = 0.75
        for label in [quoteAuthor, quoteBody] {
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
        }
        NSLayoutConstraint.activate([
            quote.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8),
            quote.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            quote.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            quoteBar.leadingAnchor.constraint(equalTo: quote.leadingAnchor, constant: 8),
            quoteBar.topAnchor.constraint(equalTo: quote.topAnchor, constant: 6),
            quoteBar.bottomAnchor.constraint(equalTo: quote.bottomAnchor, constant: -6),
            quoteBar.widthAnchor.constraint(equalToConstant: 3),
            quoteLabels.leadingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: 8),
            quoteLabels.trailingAnchor.constraint(equalTo: quote.trailingAnchor, constant: -10),
            quoteLabels.topAnchor.constraint(equalTo: quote.topAnchor, constant: 6),
            quoteLabels.bottomAnchor.constraint(equalTo: quote.bottomAnchor, constant: -6)
        ])
        // Media and file cards sit above the text; the bubble's own corners clip them.
        attachmentArea.translatesAutoresizingMaskIntoConstraints = false
        attachmentArea.clipsToBounds = true
        attachmentArea.isAccessibilityElement = false
        attachmentArea.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAttachmentTap)))
        bubble.addSubview(attachmentArea)
        media.translatesAutoresizingMaskIntoConstraints = false
        media.contentMode = .scaleAspectFill
        media.clipsToBounds = true
        // Framed by the bubble colour so a white photo keeps an edge on a white canvas; the radius is the
        // bubble's 20pt corner less the frame, so the two curves stay concentric.
        media.cornerConfiguration = .uniformCorners(radius: .fixed(20 - Self.mediaInset))
        media.backgroundColor = .quaternarySystemFill
        media.accessibilityIgnoresInvertColors = true
        attachmentArea.addSubview(media)
        mediaSpinner.translatesAutoresizingMaskIntoConstraints = false
        mediaSpinner.hidesWhenStopped = true
        attachmentArea.addSubview(mediaSpinner)
        fileIcon.translatesAutoresizingMaskIntoConstraints = false
        fileIcon.contentMode = .scaleAspectFit
        fileIcon.preferredSymbolConfiguration = .init(pointSize: 26, weight: .regular)
        attachmentArea.addSubview(fileIcon)
        fileName.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        fileName.adjustsFontForContentSizeCategory = true
        fileName.lineBreakMode = .byTruncatingMiddle
        fileDetail.font = .preferredFont(forTextStyle: .caption1)
        fileDetail.adjustsFontForContentSizeCategory = true
        let fileLabels = UIStackView(arrangedSubviews: [fileName, fileDetail])
        fileLabels.translatesAutoresizingMaskIntoConstraints = false
        fileLabels.axis = .vertical
        fileLabels.spacing = 1
        attachmentArea.addSubview(fileLabels)
        NSLayoutConstraint.activate([
            media.leadingAnchor.constraint(equalTo: attachmentArea.leadingAnchor, constant: Self.mediaInset),
            media.trailingAnchor.constraint(equalTo: attachmentArea.trailingAnchor, constant: -Self.mediaInset),
            media.topAnchor.constraint(equalTo: attachmentArea.topAnchor, constant: Self.mediaInset),
            media.bottomAnchor.constraint(equalTo: attachmentArea.bottomAnchor, constant: -Self.mediaInset),
            mediaSpinner.centerXAnchor.constraint(equalTo: attachmentArea.centerXAnchor), mediaSpinner.centerYAnchor.constraint(equalTo: attachmentArea.centerYAnchor),
            fileIcon.leadingAnchor.constraint(equalTo: attachmentArea.leadingAnchor, constant: 12),
            fileIcon.centerYAnchor.constraint(equalTo: attachmentArea.centerYAnchor),
            fileIcon.widthAnchor.constraint(equalToConstant: 32),
            fileLabels.leadingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 10),
            fileLabels.trailingAnchor.constraint(equalTo: attachmentArea.trailingAnchor, constant: -12),
            fileLabels.centerYAnchor.constraint(equalTo: attachmentArea.centerYAnchor)
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
        star.preferredSymbolConfiguration = .init(textStyle: .caption2, scale: .small)
        star.contentMode = .scaleAspectFit
        star.isAccessibilityElement = false
        star.setContentCompressionResistancePriority(.required, for: .horizontal)
        // One slot width for every state (MessageStatusView), so a bubble never resizes as its message
        // is accepted, delivered and read.
        time.font = .preferredFont(forTextStyle: .caption2)
        time.adjustsFontForContentSizeCategory = true
        time.isAccessibilityElement = false
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        footer.addArrangedSubview(star)
        footer.addArrangedSubview(time)
        footer.addArrangedSubview(status)
        // Pills hang off the bubble's bottom corner; the message accessibility label already reads them.
        reactionRow.translatesAutoresizingMaskIntoConstraints = false
        reactionRow.axis = .horizontal
        reactionRow.spacing = 3
        reactionRow.isAccessibilityElement = false
        contentView.addSubview(reactionRow)
        reactionLeading = reactionRow.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8)
        reactionTrailing = reactionRow.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8)
        leading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        trailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        bubbleWidth = bubble.widthAnchor.constraint(equalToConstant: 200)
        plainAttachmentTop = attachmentArea.topAnchor.constraint(equalTo: bubble.topAnchor)
        replyAttachmentTop = attachmentArea.topAnchor.constraint(equalTo: quote.bottomAnchor, constant: 8)
        plainAttachmentTop.isActive = true
        attachmentHeight = attachmentArea.heightAnchor.constraint(equalToConstant: 0)
        // With no attachment the area is zero-height and the text keeps its original top.
        plainTextTop = textView.topAnchor.constraint(equalTo: attachmentArea.bottomAnchor)
        replyTextTop = textView.topAnchor.constraint(equalTo: attachmentArea.bottomAnchor, constant: -12)
        plainTextTop.isActive = true
        textHeight = textView.heightAnchor.constraint(equalToConstant: 0)
        footerAfterText = footer.topAnchor.constraint(equalTo: textView.bottomAnchor)
        footerAfterMedia = footer.topAnchor.constraint(equalTo: attachmentArea.bottomAnchor, constant: Self.mediaFooterGap)
        footerAfterText.isActive = true
        NSLayoutConstraint.activate([
            bubbleWidth, attachmentHeight,
            attachmentArea.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            attachmentArea.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            footer.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: bubble.leadingAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            reactionRow.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Self.pillHang),
            reactionRow.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 20pt corners; the last bubble of a run gets a 6pt tail on its outer bottom corner.
    private var corners: (bottomLeft: CGFloat, bottomRight: CGFloat) {
        guard let row, row.endsRun else { return (20, 20) }
        return row.message.isOutgoing ? (20, 6) : (6, 20)
    }

    /// Hit-testing twin of the continuous-corner configuration the bubble draws with.
    private func bubblePath(in rect: CGRect) -> UIBezierPath {
        let radius = min(20, rect.height / 2)
        let (bottomLeft, bottomRight) = (min(corners.bottomLeft, radius), min(corners.bottomRight, radius))
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(withCenter: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight), radius: bottomRight, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft), radius: bottomLeft, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        path.close()
        return path
    }

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
            let limit = min(230, maximumTextWidth - 21)
            let bodyWidth = (reply.body as NSString).size(withAttributes: [.font: quoteBody.font!]).width
            let authorWidth = (reply.author as NSString).size(withAttributes: [.font: quoteAuthor.font!]).width
            quoteWidth = min(limit, max(bodyWidth, authorWidth)) + 45
        }
        var width = min(maximumTextWidth + 24, max(quoteWidth, max(metadataWidth, max(44, ceil(measured.width) + 25))))
        if let attachment = message?.attachment {
            if attachment.showsPreview {
                // A fixed preview width per chat; height follows the photo, bounded so one tall shot never fills the screen.
                width = min(maximumTextWidth + 24, 280)
                // The photo keeps its own aspect inside the frame; the frame is added around it, not cropped from it.
                let frame = 2 * Self.mediaInset
                attachmentHeight.constant = frame + min(340 - frame, max(120 - frame, ((width - frame) / attachment.aspectRatio).rounded()))
            } else {
                width = max(width, min(maximumTextWidth + 24, 240))
                attachmentHeight.constant = 62
            }
        } else { attachmentHeight.constant = 0 }
        bubbleWidth.constant = width
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    @objc private func handleAttachmentTap() {
        guard let url = message?.attachment?.localURL else { return }
        openAttachment(url)
    }

    private func configureAttachment(_ attachment: TimelineAttachment?, isOutgoing: Bool, textColor: UIColor) {
        attachmentArea.isHidden = attachment == nil
        media.isHidden = attachment?.showsPreview != true
        let showsCard = attachment != nil && attachment?.showsPreview != true
        fileIcon.isHidden = !showsCard
        fileName.isHidden = !showsCard
        fileDetail.isHidden = !showsCard
        media.image = nil
        mediaSpinner.stopAnimating()
        guard let attachment else { return }
        if showsCard {
            fileIcon.tintColor = textColor
            fileName.textColor = textColor
            fileDetail.textColor = textColor.withAlphaComponent(0.75)
            fileName.text = attachment.name
            let size = attachment.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file) : nil
            fileDetail.text = [size, attachment.localURL == nil ? "Downloading…" : nil].compactMap { $0 }.joined(separator: " · ")
            if fileDetail.text?.isEmpty ?? true { fileDetail.text = attachment.mediaType }
            return
        }
        guard let url = attachment.localURL else { mediaSpinner.startAnimating(); return }
        if let hit = AttachmentThumbnails.cached(for: url) {
            media.image = hit
            media.contentMode = .scaleAspectFill
            return
        }
        mediaSpinner.startAnimating()
        let id = messageID
        Task { [weak self] in
            let image = await AttachmentThumbnails.image(for: url, mediaType: attachment.mediaType)
            guard let self, messageID == id else { return }
            mediaSpinner.stopAnimating()
            media.image = image ?? UIImage(systemName: attachment.isVideo ? "video" : "photo")
            media.contentMode = image == nil ? .center : .scaleAspectFill
        }
    }

    /// The one action list; the overlay menu and VoiceOver custom actions both read it.
    private func actions() -> [MessageAction] {
        guard let message else { return [] }
        // A placeholder is a notice, not content: nothing to quote, copy, star or select; only why it is unreadable.
        if message.unreadable != nil {
            return [MessageAction(kind: .encryptionDetails, title: "Encryption details", symbol: "lock.shield", perform: openEncryptionAction)]
        }
        let star = MessageAction(kind: .star, title: message.isStarred ? "Unstar message" : "Star message", symbol: message.isStarred ? "star.slash" : "star", perform: toggleStar)
        // An unsent bubble has no text to quote, copy or select.
        if message.isRetracted { return [star] }
        var actions: [MessageAction] = [
            MessageAction(kind: .reply, title: "Reply", symbol: "arrowshape.turn.up.left", perform: replyAction),
            MessageAction(kind: .copy, title: "Copy", symbol: "doc.on.doc") { UIPasteboard.general.string = message.body },
            star,
            MessageAction(kind: .selectText, title: "Select text", symbol: "text.cursor") { [weak self] in self?.beginTextSelection() }
        ]
        if message.isOutgoing, message.status?.canRetry == true {
            actions.append(MessageAction(kind: .retry, title: "Retry message", symbol: "arrow.clockwise", perform: retry))
        }
        if message.canEdit { actions.append(MessageAction(kind: .edit, title: "Edit", symbol: "pencil", perform: editAction)) }
        if message.canUnsend { actions.append(MessageAction(kind: .unsend, title: "Unsend", symbol: "trash", perform: unsendAction)) }
        return actions
    }

    @objc private func handlePress(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            guard message != nil else { return }
            MessageActionsOverlay.signposter.emitEvent("press began")
            pressFeedback.prepare()
            // A reply swipe still settling would put its offset into the snapshot.
            if bubble.transform.tx != 0 { resetReplySwipe(animated: false) }
            pressGeneration += 1
            let generation = pressGeneration
            if UIAccessibility.isReduceMotionEnabled { presentMenu(actionsContext()); return }
            // The snapshot and frames are taken before the squeeze (a snapshot ignores the transform anyway); the
            // prepared overlay draws its source at the squeeze's end scale, which it will have when it is shown.
            var context = actionsContext()
            context?.sourceScale = Self.squeezedScale
            UIView.animate(withDuration: Self.squeezeDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.squeeze(Self.squeezedScale)
            } completion: { [weak self] _ in
                guard let self, generation == pressGeneration, press.state == .began || press.state == .changed else { return }
                presentMenu(context)
            }
            // The overlay is built hidden on the next turn, once the squeeze is committed: the render server runs the
            // squeeze while the main thread does the hosting setup, and the squeeze's end only has to unhide it.
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == pressGeneration, let context, let window else { return }
                MessageActionsOverlay.prepare(in: window, context: context)
            }
        case .ended, .cancelled, .failed:
            pressGeneration += 1
            // Released before the menu opened: the bubble springs back and the prepared overlay goes.
            // After it opened the live bubble is hidden and already unsqueezed.
            MessageActionsOverlay.discardPrepared()
            releaseSqueeze()
        default:
            break
        }
    }

    /// Scales the bubble about its centre and keeps the reaction pills hanging off it by scaling them about the same point.
    private func squeeze(_ scale: CGFloat) {
        bubble.transform = CGAffineTransform(scaleX: scale, y: scale)
        let offset = CGPoint(x: (1 - scale) * (bubble.center.x - reactionRow.center.x), y: (1 - scale) * (bubble.center.y - reactionRow.center.y))
        reactionRow.transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.x, ty: offset.y)
    }

    private func releaseSqueeze() {
        guard bubble.transform.a != 1 else { return }
        UIView.animate(springDuration: 0.25, bounce: 0.2, options: [.beginFromCurrentState, .allowUserInteraction]) { self.squeeze(1) }
    }

    /// The window frame a view has without its squeeze transform.
    private func unsqueezedFrame(_ view: UIView) -> CGRect {
        let centre = contentView.convert(view.center, to: nil)
        return CGRect(x: centre.x - view.bounds.width / 2, y: centre.y - view.bounds.height / 2, width: view.bounds.width, height: view.bounds.height)
    }

    /// Haptic, then the overlay over the squeezed bubble with the snapshot and frames taken as the press began
    /// (keyboard still up). The timeline moves the keyboard only after the overlay covers it.
    private func presentMenu(_ context: MessageActionsContext?) {
        guard var context, window != nil, messageID == context.message.id else {
            MessageActionsOverlay.discardPrepared()
            releaseSqueeze()
            return
        }
        pressFeedback.impactOccurred(intensity: 0.8)
        context.sourceScale = bubble.transform.a
        if !presentActions(context) { releaseSqueeze() }
    }

    /// The snapshot and frames exactly as the screen shows them, and what the menu will offer. Frames ignore the squeeze.
    private func actionsContext() -> MessageActionsContext? {
        guard let message, window != nil, let bubbleSnapshot = bubble.snapshotView(afterScreenUpdates: false) else { return nil }
        let reactions = message.reactions.isEmpty ? nil : reactionRow.snapshotView(afterScreenUpdates: false)
        let id = message.id
        return MessageActionsContext(message: message, bubble: bubbleSnapshot, bubbleFrame: unsqueezedFrame(bubble),
                                             bubbleShape: bubblePath(in: bubble.bounds).cgPath, sourceScale: bubble.transform.a,
                                             reactions: reactions, reactionsFrame: unsqueezedFrame(reactionRow),
                                             actions: actions(), react: reactionAction,
                                             setSourceHidden: { [weak self] hidden in
                                                 guard let self else { return }
                                                 // Hidden, it drops the squeeze so the menu closes onto its resting size.
                                                 if hidden { squeeze(1) }
                                                 bubble.alpha = hidden ? 0 : 1
                                                 reactionRow.alpha = hidden ? 0 : 1
                                             },
                                             currentBubbleFrame: { [weak self] in
                                                 guard let self, messageID == id, window != nil else { return nil }
                                                 return unsqueezedFrame(bubble)
                                             })
    }

    /// `point` is in the cell's coordinates.
    func bubbleContains(_ point: CGPoint) -> Bool { messageID != nil && bubblePath(in: bubble.bounds).contains(convert(point, to: bubble)) }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !isSelectingText, bubbleContains(gestureRecognizer.location(in: self)) else { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: contentView)
        return pan.location(in: window).x > 24 && velocity.x > 0 && velocity.x > abs(velocity.y) * 1.5
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
    }


    @objc private func handleReplyPan(_ pan: UIPanGestureRecognizer) {
        let distance = max(0, pan.translation(in: contentView).x)
        switch pan.state {
        case .began:
            // A placeholder has nothing to reply to. The pan still begins, so gesture arbitration with the
            // collection view is unchanged; the bubble simply does not travel and there is no haptic.
            swipeReplyAction = message?.unreadable == nil ? replyAction : nil
            crossedReplyThreshold = false
            guard swipeReplyAction != nil else { break }
            replyIndicatorLeading.constant = bubble.frame.minX + 12
            replyFeedback.prepare()
        case .changed:
            guard swipeReplyAction != nil else { break }
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
        // A cell recycled while its bubble hid under the menu, or mid-squeeze, must come back whole.
        pressGeneration += 1
        squeeze(1)
        bubble.alpha = 1
        reactionRow.alpha = 1
        _ = textView.resignFirstResponder()
        textView.isSelectable = false
        textView.isUserInteractionEnabled = false
        textView.selectedRange = NSRange(location: 0, length: 0)
        status.stopSpinning()
        coverDateHeader(false, fade: 0)
        messageID = nil
        row = nil
    }

    /// The floating date chip draws this day header's text while it stands in for it. The text is only made clear,
    /// never hidden, so VoiceOver keeps the inline header.
    func coverDateHeader(_ covered: Bool, fade: TimeInterval) {
        let color: UIColor = covered ? .clear : .secondaryLabel
        guard dateLabel.textColor != color else { return }
        guard fade > 0 else { dateLabel.textColor = color; return }
        UIView.transition(with: dateLabel, duration: fade, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.dateLabel.textColor = color }
    }

    func configure(row: TimelineRow, toggleStar: @escaping () -> Void, retry: @escaping () -> Void, reply: @escaping () -> Void, reaction: @escaping (String) -> Void,
                   edit: @escaping () -> Void = {}, unsend: @escaping () -> Void = {}, openEncryption: @escaping () -> Void = {},
                   presentActions: @escaping (MessageActionsContext) -> Bool, openAttachment: @escaping (URL) -> Void = { _ in }) {
        let message = row.message
        self.row = row
        self.toggleStar = toggleStar
        self.retry = retry
        self.replyAction = reply
        self.reactionAction = reaction
        self.editAction = edit
        self.unsendAction = unsend
        self.openEncryptionAction = openEncryption
        self.presentActions = presentActions
        self.openAttachment = openAttachment
        bubble.cornerConfiguration = .corners(topLeftRadius: .fixed(20), topRightRadius: .fixed(20),
                                              bottomLeftRadius: .fixed(corners.bottomLeft), bottomRightRadius: .fixed(corners.bottomRight))
        if messageID != message.id {
            resetReplySwipe(animated: false)
            _ = textView.resignFirstResponder()
            textView.isSelectable = false
            textView.isUserInteractionEnabled = false
            messageID = message.id
        }
        let theme = AccentTheme.current
        let hasHeader = row.dateHeader != nil
        let showsAuthor = message.author != nil && row.startsRun
        dateLabel.text = row.dateHeader
        dateLabel.isHidden = !hasHeader
        dateHeight.isActive = !hasHeader
        dateTop.constant = hasHeader ? Self.dateHeaderTop : (row.startsRun ? 6 : 0)
        authorTop.constant = hasHeader ? 8 : 0
        author.text = showsAuthor ? message.author : nil
        author.isHidden = !showsAuthor
        authorHeight.isActive = !showsAuthor
        author.textColor = message.author.map(AvatarPalette.color(for:)) ?? theme.tint
        bubbleTop.constant = showsAuthor ? 3 : 0
        bubbleBottom.constant = message.reactions.isEmpty ? 0 : -(Self.pillHang + 2)
        quote.isHidden = message.reply == nil
        quoteAuthor.text = message.reply?.author
        quoteBody.text = message.reply?.body
        NSLayoutConstraint.deactivate([plainTextTop, replyTextTop, plainAttachmentTop, replyAttachmentTop])
        (message.reply == nil ? plainAttachmentTop : replyAttachmentTop)?.isActive = true
        // Under a preview the caption keeps its own inset; under a quote alone the text tucks up as before.
        (message.reply == nil || message.attachment != nil ? plainTextTop : replyTextTop)?.isActive = true
        textHeight.isActive = message.body.isEmpty && message.attachment != nil
        textView.isHidden = textHeight.isActive
        // A caption keeps its usual 10pt inset from the photo itself, not from the frame below it.
        let showsPreview = !message.showsPlaceholder && message.attachment?.showsPreview == true
        plainTextTop.constant = showsPreview ? -Self.mediaInset : 0
        NSLayoutConstraint.deactivate([footerAfterText, footerAfterMedia])
        (showsPreview && textHeight.isActive ? footerAfterMedia : footerAfterText)?.isActive = true
        let canRetry = message.isOutgoing && message.status?.canRetry == true
        leading.isActive = !message.isOutgoing
        trailing.isActive = message.isOutgoing
        reactionLeading.isActive = !message.isOutgoing
        reactionTrailing.isActive = message.isOutgoing
        let text: UIColor = message.isOutgoing ? theme.bubbleText : .label
        let meta: UIColor = message.isOutgoing ? theme.bubbleText.withAlphaComponent(0.75) : .secondaryLabel
        bubble.backgroundColor = message.isOutgoing ? theme.bubble : Self.incomingBubble
        textView.textColor = text
        quote.backgroundColor = message.isOutgoing ? theme.bubbleText.withAlphaComponent(theme.bubbleText == .white ? 0.18 : 0.08) : UIColor.black.withAlphaComponent(0.06)
        quoteBar.backgroundColor = message.isOutgoing ? theme.bubbleText : theme.tint
        quoteAuthor.textColor = text
        quoteBody.textColor = text
        time.textColor = meta
        star.tintColor = meta
        replyIndicator.tintColor = theme.tint
        // An unsent or unreadable message keeps its bubble and time; the text becomes a quiet italic placeholder.
        let shown = message.showsPlaceholder ? message.placeholder : message.body
        if textView.text != shown { textView.text = shown }
        let bodyDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        textView.font = message.showsPlaceholder ? UIFont(descriptor: bodyDescriptor.withSymbolicTraits(.traitItalic) ?? bodyDescriptor, size: 0) : .preferredFont(forTextStyle: .body)
        textView.textColor = message.showsPlaceholder ? meta : text
        configureAttachment(message.showsPlaceholder ? nil : message.attachment, isOutgoing: message.isOutgoing, textColor: text)
        var descriptions = ["\(message.isOutgoing ? "You" : (message.author ?? "Contact")): \(shown)"]
        if message.unreadable != nil { descriptions.append("not readable on this device") }
        if message.isEdited { descriptions.append("edited") }
        if !message.showsPlaceholder, let attachment = message.attachment { descriptions.append("\(attachment.kindLabel) \(attachment.name)" + (attachment.localURL == nil ? ", downloading" : "")) }
        if let quote = message.reply { descriptions.append("Replying to \(quote.author): \(quote.body)") }
        if message.isStarred { descriptions.append("starred") }
        if let date = message.sentAt { descriptions.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if message.isOutgoing, let state = message.status { descriptions.append(state.accessibilityDescription) }
        if let notice = message.securityNotice { descriptions.append(notice) }
        if !message.reactions.isEmpty { descriptions.append(message.reactions.map(\.accessibilityDescription).joined(separator: ", ")) }
        for pill in reactionRow.arrangedSubviews { pill.removeFromSuperview() }
        for reaction in message.reactions {
            reactionRow.addArrangedSubview(ReactionPill(reaction, onTap: message.canReact ? { [weak self] in self?.reactionAction(reaction.emoji) } : nil))
        }
        textView.accessibilityLabel = descriptions.joined(separator: ", ")
        textView.accessibilityCustomActions = actions().map { action in UIAccessibilityCustomAction(name: action.title) { _ in action.perform(); return true } }
        if let url = message.attachment?.localURL {
            textView.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "Open \(message.attachment?.kindLabel.lowercased() ?? "file")") { [weak self] _ in self?.openAttachment(url); return true })
        }
        if message.canReact {
            let selected = Set(message.reactions.filter(\.isSelected).map(\.emoji))
            for emoji in TimelineReaction.choices {
                let actionName = "\(selected.contains(emoji) ? "Remove" : "Add") \(TimelineReaction.name(for: emoji)) reaction"
                textView.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: actionName) { _ in reaction(emoji); return true })
            }
        }
        star.alpha = message.isStarred ? 1 : 0
        time.text = [message.isEdited ? "Edited" : nil, message.securityNotice, message.sentAt?.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
        time.isHidden = message.sentAt == nil && message.securityNotice == nil && !message.isEdited
        status.isHidden = !message.isOutgoing || message.status == nil
        // Neutral like the time: read is told by the filled rings and failure by the filled exclamation, never by colour.
        status.tintColor = meta
        status.show(message.isOutgoing ? message.status.map(MessageStatusGlyph.glyph(for:)) : nil)
        setNeedsLayout()
    }
}

/// Shown above the oldest message while older history is fetched: a small spinner and one quiet line, nothing to tap.
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

/// Three dots in a received bubble, bouncing in turn; with Reduce Motion they only fade.
@MainActor
private final class TypingIndicatorCell: UICollectionViewCell {
    private let author = UILabel()
    private let bubble = UIView()
    private let dots = (0..<3).map { _ in UIView() }
    private var authorHeight: NSLayoutConstraint!
    private var bubbleTop: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        author.translatesAutoresizingMaskIntoConstraints = false
        author.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        author.adjustsFontForContentSizeCategory = true
        author.lineBreakMode = .byTruncatingTail
        author.isAccessibilityElement = false
        contentView.addSubview(author)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = MessageBubbleCell.incomingBubble
        // Shaped like the last bubble of a received run: 20pt corners and the 6pt tail.
        bubble.cornerConfiguration = .corners(topLeftRadius: .fixed(20), topRightRadius: .fixed(20), bottomLeftRadius: .fixed(6), bottomRightRadius: .fixed(20))
        bubble.isAccessibilityElement = true
        bubble.accessibilityIdentifier = "typingIndicator"
        contentView.addSubview(bubble)
        let row = UIStackView(arrangedSubviews: dots)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.spacing = 5
        for dot in dots {
            dot.backgroundColor = .secondaryLabel
            dot.layer.cornerRadius = 4
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        bubble.addSubview(row)
        authorHeight = author.heightAnchor.constraint(equalToConstant: 0)
        bubbleTop = bubble.topAnchor.constraint(equalTo: author.bottomAnchor)
        NSLayoutConstraint.activate([
            // A run of its own: the same 6pt a run's first message adds.
            author.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            author.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 13),
            author.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            bubbleTop,
            bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bubble.heightAnchor.constraint(equalToConstant: 40),
            row.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: bubble.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ typing: TimelineTyping) {
        author.text = typing.author
        author.textColor = AvatarPalette.color(for: typing.colorKey)
        author.isHidden = typing.author == nil
        authorHeight.isActive = typing.author == nil
        bubbleTop.constant = typing.author == nil ? 0 : 3
        bubble.accessibilityLabel = typing.accessibilityLabel
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startDots() }
    }

    /// A 1.2 s wave: each dot brightens (and lifts 3pt) a beat after the one before it.
    func startDots() {
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.35, 1, 0.35, 0.35]
            let group = CAAnimationGroup()
            group.animations = [fade]
            if !UIAccessibility.isReduceMotionEnabled {
                let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
                lift.values = [0, -3, 0, 0]
                group.animations?.append(lift)
            }
            for case let animation as CAKeyframeAnimation in group.animations ?? [] {
                animation.keyTimes = [0, 0.22, 0.44, 1]
                animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            }
            group.duration = 1.2
            group.repeatCount = .infinity
            group.beginTime = now + Double(index) * 0.16
            group.fillMode = .backwards
            // Kept across a trip to the background, which otherwise strips running animations.
            group.isRemovedOnCompletion = false
            dot.layer.add(group, forKey: "typing")
        }
    }

    /// Grows out of its tail corner; with Reduce Motion it only fades in.
    func animateIn() {
        let views = [bubble, author]
        views.forEach { $0.alpha = 0 }
        let grows = !UIAccessibility.isReduceMotionEnabled
        if grows { bubble.transform = CGAffineTransform(translationX: -8, y: 5).scaledBy(x: 0.7, y: 0.7) }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            views.forEach { $0.alpha = 1 }
            self.bubble.transform = .identity
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        bubble.layer.removeAllAnimations()
        bubble.transform = .identity
        bubble.alpha = 1
        author.alpha = 1
    }
}

/// One reaction chip: emoji plus count, ringed in the accent when the user is among the reactors.
@MainActor
private final class ReactionPill: UIView {
    private let ring = UIView()
    private let onTap: (() -> Void)?

    init(_ reaction: TimelineReaction, onTap: (() -> Void)?) {
        self.onTap = onTap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false
        if onTap != nil { addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped))) }
        backgroundColor = .systemBackground
        layer.cornerRadius = 12
        layer.borderWidth = 1.5
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        let emoji = UILabel()
        emoji.font = .systemFont(ofSize: 14)
        emoji.text = reaction.emoji
        let count = UILabel()
        count.font = .systemFont(ofSize: 12, weight: .semibold)
        count.textColor = .label
        count.text = "\(reaction.count)"
        count.isHidden = reaction.count <= 1
        let stack = UIStackView(arrangedSubviews: [emoji, count])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 3
        stack.alignment = .center
        addSubview(stack)
        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.layer.cornerRadius = 10.5
        ring.layer.borderWidth = 1.5
        ring.isHidden = !reaction.isSelected
        addSubview(ring)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1.5),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1.5),
            ring.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5)
        ])
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: ReactionPill, _: UITraitCollection) in pill.applyColors() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onTap?() }

    private func applyColors() {
        layer.borderColor = UIColor.systemBackground.cgColor
        layer.shadowColor = UIColor.black.cgColor
        ring.layer.borderColor = AccentTheme.current.tint.resolvedColor(with: traitCollection).cgColor
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

/// Reports where a touch lands and when it is over. It never recognizes, so it blocks nothing.
private final class TouchGate: UIGestureRecognizer {
    private let down: (CGPoint) -> Void
    private let up: () -> Void

    init(down: @escaping (CGPoint) -> Void, up: @escaping () -> Void) {
        self.down = down
        self.up = up
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view { down(touch.location(in: view)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    // Also reached when another recognizer wins and UIKit fails this one: the touch is spoken for either way.
    override func reset() { up() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
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
