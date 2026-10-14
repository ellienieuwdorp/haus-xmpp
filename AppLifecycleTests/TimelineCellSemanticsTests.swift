import SafariServices
import UIKit
import XCTest
@testable import HausXMPP

/// What each kind of timeline cell shows and says: the side a bubble sits on, its VoiceOver label and the actions it
/// offers. The long-press menu and the VoiceOver custom actions read the same action list, so the custom actions
/// stand for the menu here.
@MainActor
final class TimelineCellSemanticsTests: XCTestCase {
    private var window: UIWindow!
    private var controller: ConversationTimelineController!
    private let sentAt = Date(timeIntervalSince1970: 1_789_380_000)

    override func setUp() async throws {
        controller = ConversationTimelineController()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
        controller = nil
    }

    private var collectionView: UICollectionView { controller.view.subviews.compactMap { $0 as? UICollectionView }.first! }
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>? { collectionView.dataSource as? UICollectionViewDiffableDataSource<Int, String> }

    private func show(_ messages: [TimelineMessage], typing: TimelineTyping? = nil, onOpenEncryption: @escaping () -> Void = {}) {
        controller.update(messages: messages, typing: typing, onToggleStar: { _ in }, onOpenEncryption: onOpenEncryption)
        collectionView.layoutIfNeeded()
    }

    private func descendants(of view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }

    private func cell(at path: IndexPath) throws -> UICollectionViewCell {
        try XCTUnwrap(collectionView.cellForItem(at: path), "item \(path.item) is on screen")
    }

    /// The one element VoiceOver reaches for a message: the visible view carrying its actions (its text, or the file
    /// when there is no caption).
    private func speaker(_ id: String) throws -> UIView {
        let path = try XCTUnwrap(dataSource?.indexPath(for: id), id)
        let speakers = descendants(of: try cell(at: path).contentView)
            .filter { $0.isAccessibilityElement && !$0.isHidden && !($0.accessibilityCustomActions ?? []).isEmpty }
        XCTAssertEqual(speakers.count, 1, "\(id) has one element speaking for it")
        return try XCTUnwrap(speakers.first, "\(id) can be reached by VoiceOver")
    }

    /// The bubble around the speaking view, in the timeline's coordinates.
    private func bubble(_ id: String) throws -> CGRect {
        let bubble = try XCTUnwrap(try speaker(id).superview)
        return bubble.convert(bubble.bounds, to: collectionView)
    }

    private func actions(_ view: UIView) -> [String] { view.accessibilityCustomActions?.map(\.name) ?? [] }

    func testUnreadablePlaceholdersAreNoticesOnTheirSendersSide() throws {
        var opened = 0
        show([
            TimelineMessage(id: "own", body: "", isOutgoing: true, isStarred: false, sentAt: sentAt, status: .serverAccepted, unreadable: .notForThisDevice),
            TimelineMessage(id: "incoming", body: "", isOutgoing: false, isStarred: false, sentAt: sentAt, unreadable: .decryptFailed),
        ], onOpenEncryption: { opened += 1 })
        let own = try speaker("own")
        let incoming = try speaker("incoming")
        XCTAssertEqual((own as? UITextView)?.text, "Sent from another device and not encrypted for this iPhone")
        XCTAssertEqual((incoming as? UITextView)?.text, "Couldn't read this message")
        // VoiceOver hears who it is from and why there is no text; a direct chat's peer is "Contact".
        XCTAssertTrue(own.accessibilityLabel?.hasPrefix("You: Sent from another device and not encrypted for this iPhone, not readable on this device") == true,
                      own.accessibilityLabel ?? "no label")
        XCTAssertTrue(incoming.accessibilityLabel?.hasPrefix("Contact: Couldn't read this message, not readable on this device") == true,
                      incoming.accessibilityLabel ?? "no label")
        // A notice, never content: nothing to reply to, copy, star or select; only why it is unreadable.
        XCTAssertEqual(actions(own), ["Encryption details"])
        XCTAssertEqual(actions(incoming), ["Encryption details"])
        let details = try XCTUnwrap(incoming.accessibilityCustomActions?.first)
        XCTAssertEqual(details.actionHandler?(details), true)
        XCTAssertEqual(opened, 1, "Encryption details opens the chat's encryption screen")
        // The own-device send on the trailing side, the incoming one on the leading side.
        XCTAssertEqual(try bubble("own").maxX, collectionView.bounds.width - 16, accuracy: 0.5)
        XCTAssertEqual(try bubble("incoming").minX, 16, accuracy: 0.5)
    }

    func testAnUnsentOwnMessageKeepsAQuietBubbleThatCanOnlyBeStarred() throws {
        show([TimelineMessage(id: "m", body: "That sounds perfect. Around ten?", isOutgoing: true, isStarred: false, sentAt: sentAt,
                              status: .serverAccepted, canEdit: true, canUnsend: true)])
        let original = try bubble("m").width
        show([TimelineMessage(id: "m", body: "", isOutgoing: true, isStarred: false, sentAt: sentAt, status: .serverAccepted, isRetracted: true)])
        let placeholder = try speaker("m")
        XCTAssertEqual((placeholder as? UITextView)?.text, "You unsent a message")
        XCTAssertTrue(placeholder.accessibilityLabel?.hasPrefix("You: You unsent a message") == true, placeholder.accessibilityLabel ?? "no label")
        XCTAssertEqual(actions(placeholder), ["Star message"])
        // Its bubble stays on the trailing side and never outgrows the message it replaced.
        let unsent = try bubble("m")
        XCTAssertLessThanOrEqual(unsent.width, max(original, 240) + 0.5)
        XCTAssertEqual(unsent.maxX, collectionView.bounds.width - 16, accuracy: 0.5)
    }

    /// VoiceOver gets the menu's actions (`MessageActionMenuTests` owns which), then the file's, then a toggle per quick
    /// reaction, and each one does what it says.
    func testVoiceOverOffersTheMenuThenTheFileThenReactions() throws {
        var reacted: [String] = []
        controller.update(messages: [TimelineMessage(id: "own", body: "See you there", isOutgoing: true, isStarred: false,
                                                     attachment: TimelineAttachment(name: "plan.pdf", mediaType: "application/pdf", size: 2_000, width: nil, height: nil,
                                                                                    download: .failed),
                                                     sentAt: sentAt, status: .serverAccepted, canReact: true, isEdited: true, canEdit: true, canUnsend: true)],
                          onToggleStar: { _ in }, onReaction: { reacted.append("\($0) \($1)") })
        collectionView.layoutIfNeeded()
        let own = try speaker("own")
        XCTAssertEqual(actions(own), ["Reply", "Copy", "Star message", "Select text", "Edit", "Unsend", "Download file",
                                      "Add heart reaction", "Add thumbs up reaction", "Add tears of joy reaction",
                                      "Add surprised reaction", "Add sad reaction", "Add folded hands reaction"])
        let thumbsUp = try XCTUnwrap(own.accessibilityCustomActions?.first { $0.name == "Add thumbs up reaction" })
        XCTAssertEqual(thumbsUp.actionHandler?(thumbsUp), true)
        XCTAssertEqual(reacted, ["own 👍"])
        XCTAssertTrue(own.accessibilityLabel?.hasPrefix("You: See you there, edited, File plan.pdf, could not be downloaded") == true, own.accessibilityLabel ?? "no label")
    }

    /// Every message reserves the star's slot, so starring neither widens nor shifts the bubble.
    func testStarringKeepsTheBubbleWhereItWas() throws {
        for isOutgoing in [true, false] {
            let message = { (starred: Bool) in
                TimelineMessage(id: "m", body: "Ok", isOutgoing: isOutgoing, isStarred: starred, sentAt: self.sentAt,
                                status: isOutgoing ? .serverAccepted : nil)
            }
            show([message(false)])
            let before = try bubble("m")
            show([message(true)])
            XCTAssertEqual(try bubble("m"), before, isOutgoing ? "own" : "received")
            show([message(false)])
            XCTAssertEqual(try bubble("m"), before, isOutgoing ? "own" : "received")
        }
    }

    /// A photo sent without a caption hides its text view, so the photo itself speaks for the message, quote included.
    func testACaptionlessPhotoSpeaksForItselfAndItsQuote() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        show([TimelineMessage(id: "photo", body: "", isOutgoing: true, isStarred: false,
                              attachment: TimelineAttachment(name: "IMG_0001.jpg", mediaType: "image/jpeg", size: 120_000, width: 1200, height: 900, localURL: file),
                              sentAt: sentAt, status: .serverAccepted, reply: TimelineReply(author: "you", body: "Love this view"))])
        let photo = try speaker("photo")
        XCTAssertFalse(photo is UITextView, "the file, not the hidden text view, speaks")
        let label = try XCTUnwrap(photo.accessibilityLabel)
        XCTAssertTrue(label.hasPrefix("You, Photo IMG_0001.jpg"), label)
        XCTAssertTrue(label.contains("Replying to you: Love this view"), label)
        XCTAssertTrue(photo.accessibilityTraits.contains(.image))
        XCTAssertEqual(actions(photo).prefix(1), ["Reply"])
        XCTAssertTrue(actions(photo).contains("Open photo"))
    }

    /// A link message still has one element speaking for it: the card adds its phrase to that label, every link gets
    /// an action after the menu's, the Links rotor walks them, and each opens where `LinkOpening` sends it. The card
    /// takes the media width rule and sits above the text.
    func testLinksAndTheCardSpeakThroughTheBubblesOneElement() throws {
        var chats: [String] = []
        controller.onOpenChat = { chats.append($0) }
        let card = TimelineLinkPreview(url: URL(string: "https://example.org/a")!, host: "example.org", title: "Council approves the bridge",
                                       summary: "Construction starts in spring.", variant: .text)
        show([TimelineMessage(id: "card", body: "See example.org/a", isOutgoing: false, isStarred: false, linkPreview: card, sentAt: sentAt),
              TimelineMessage(id: "links", body: "Ring +31 6 12345678 or write xmpp:romeo@montague.lit", isOutgoing: true, isStarred: false,
                              sentAt: sentAt, status: .serverAccepted)])

        let carded = try speaker("card")
        XCTAssertEqual(carded.accessibilityLabel?.hasPrefix("Contact: See example.org/a, Link preview: Council approves the bridge, example.org"), true,
                       carded.accessibilityLabel ?? "no label")
        XCTAssertEqual(actions(carded), ["Reply", "Copy", "Star message", "Select text", "Open link example.org/a"])
        let bubble = try XCTUnwrap(carded.superview)
        let cardView = try XCTUnwrap(descendants(of: bubble).first { $0 is LinkPreviewCardView })
        XCTAssertTrue(cardView.accessibilityElementsHidden, "the card's labels are read in the bubble's label, not on their own")
        XCTAssertEqual(bubble.bounds.width, 280, accuracy: 0.5, "a short message with a card takes the media width")
        XCTAssertEqual(cardView.convert(cardView.bounds, to: bubble).width, 280 - 16, accuracy: 0.5)
        XCTAssertLessThanOrEqual(cardView.convert(cardView.bounds, to: bubble).maxY, carded.frame.minY + 0.5, "the card sits above the text")

        let linked = try speaker("links")
        XCTAssertEqual(actions(linked).suffix(2), ["Call +31 6 12345678", "Open chat xmpp:romeo@montague.lit"])
        let rotor = try XCTUnwrap(linked.accessibilityCustomRotors?.first)
        XCTAssertEqual(rotor.systemRotorType, .link)
        let textView = try XCTUnwrap(linked as? UITextView)
        var walked: [String] = []
        let search = UIAccessibilityCustomRotorSearchPredicate()
        search.searchDirection = .next
        search.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: linked, targetRange: nil)
        while let item = rotor.itemSearchBlock(search), let range = item.targetRange {
            walked.append(textView.text(in: range) ?? "")
            search.currentItem = item
        }
        XCTAssertEqual(walked, ["+31 6 12345678", "xmpp:romeo@montague.lit"])
        search.searchDirection = .previous
        XCTAssertEqual(rotor.itemSearchBlock(search)?.targetRange.flatMap(textView.text(in:)), "+31 6 12345678")

        let chat = try XCTUnwrap(linked.accessibilityCustomActions?.last)
        XCTAssertEqual(chat.actionHandler?(chat), true)
        XCTAssertEqual(chats, ["romeo@montague.lit"])
        // Web links open in the in-app browser unless "Open Links in Safari" is on (off by default).
        XCTAssertFalse(LinkSettings.shared.openInSafari)
        let open = try XCTUnwrap(carded.accessibilityCustomActions?.last)
        XCTAssertEqual(open.actionHandler?(open), true)
        let browser = try XCTUnwrap(controller.presentedViewController as? SFSafariViewController)
        browser.dismiss(animated: false)
    }

    func testTypingIsTheLastItemBelowTheNewestMessage() throws {
        let typing = TimelineTyping(author: nil, colorKey: "alex@preview.local", accessibilityLabel: TypingTracker.description(["Alex"]))
        var shown = [TimelineMessage(id: "mine", body: "See you at ten", isOutgoing: true, isStarred: false, sentAt: sentAt, status: .serverAccepted),
                     TimelineMessage(id: "newest", body: "Ten it is ☕️", isOutgoing: false, isStarred: false, sentAt: sentAt)]

        func indicator() throws -> CGRect {
            let last = IndexPath(item: collectionView.numberOfItems(inSection: 0) - 1, section: 0)
            let view = try XCTUnwrap(descendants(of: try cell(at: last).contentView).first { $0.accessibilityIdentifier == "typingIndicator" },
                                     "the last item is the typing bubble")
            XCTAssertTrue(view.isAccessibilityElement)
            XCTAssertEqual(view.accessibilityLabel, "Alex is typing…")
            return view.convert(view.bounds, to: collectionView)
        }

        show(shown, typing: typing)
        let first = try indicator()
        XCTAssertEqual(first.height, 40, accuracy: 0.5)
        XCTAssertEqual(first.minX, 16, accuracy: 0.5, "a received-style bubble on the leading side")
        XCTAssertGreaterThan(first.minY, try bubble("newest").maxY)

        // A message arriving while they type lands above the dots, which stay last and keep their size.
        shown.append(TimelineMessage(id: "arrived", body: "Almost there", isOutgoing: false, isStarred: false, sentAt: sentAt))
        show(shown, typing: typing)
        let after = try indicator()
        XCTAssertEqual(after.height, first.height, accuracy: 0.5)
        XCTAssertGreaterThan(after.minY, try bubble("arrived").maxY)
    }
}
