import XCTest
@testable import HausXMPP

/// Which actions each message offers, in menu order, and what VoiceOver adds after them. The long-press menu, the
/// VoiceOver custom actions and a Mac context menu all read this list.
final class MessageActionMenuTests: XCTestCase {
    private let sentAt = Date(timeIntervalSince1970: 1_789_380_000)

    func testEachMessageOffersOnlyTheActionsItSupports() {
        let reading = ["Reply", "Copy", "Star message", "Select text"]
        let cases: [(message: TimelineMessage, actions: [String], line: UInt)] = [
            (TimelineMessage(id: "received", body: "Ten it is", isOutgoing: false, isStarred: false, sentAt: sentAt), reading, #line),
            (TimelineMessage(id: "starred", body: "Keep this", isOutgoing: false, isStarred: true, sentAt: sentAt),
             ["Reply", "Copy", "Unstar message", "Select text"], #line),
            (TimelineMessage(id: "own", body: "See you there", isOutgoing: true, isStarred: false, sentAt: sentAt, status: .serverAccepted,
                             isEdited: true, canEdit: true, canUnsend: true), reading + ["Edit", "Unsend"], #line),
            (TimelineMessage(id: "failed", body: "Lost", isOutgoing: true, isStarred: false, sentAt: sentAt, status: .failed), reading + ["Retry message"], #line),
            (TimelineMessage(id: "unconfirmed", body: "Maybe", isOutgoing: true, isStarred: false, sentAt: sentAt, status: .unconfirmed), reading + ["Retry message"], #line),
            // A placeholder is a notice: only why it is unreadable, or for an unsent one, the star.
            (TimelineMessage(id: "unreadable", body: "", isOutgoing: false, isStarred: false, sentAt: sentAt, unreadable: .decryptFailed), ["Encryption details"], #line),
            (TimelineMessage(id: "unsent", body: "", isOutgoing: true, isStarred: true, sentAt: sentAt, status: .serverAccepted, isRetracted: true,
                             canEdit: true, canUnsend: true), ["Unstar message"], #line),
        ]
        for (message, expected, line) in cases {
            XCTAssertEqual(MessageActionMenu.items(for: message).map(\.title), expected, message.id, line: line)
        }
    }

    /// A long press on a link (or the card) puts that link's actions above the message's own, named for what the link
    /// is; a press elsewhere on the bubble, or on a placeholder, leaves the message's menu as it was.
    func testAPressedLinkPutsItsActionsAboveTheMessages() {
        let message = TimelineMessage(id: "m", body: "Links", isOutgoing: false, isStarred: false, sentAt: sentAt)
        let reading = ["Reply", "Copy", "Star message", "Select text"]
        let cases: [(link: String, actions: [String], line: UInt)] = [
            ("https://example.org/a", ["Open link", "Copy link", "Share link"], #line),
            ("tel:+31612345678", ["Call", "Send message", "Copy number"], #line),
            ("mailto:bob@example.org", ["New mail", "Copy email address", "Share link"], #line),
            ("xmpp:romeo@montague.lit", ["Open chat", "Copy address", "Share link"], #line),
            ("geo:37.78,-122.39", ["Open in Maps", "Copy link", "Share link"], #line),
            ("xmpp:montague.lit", ["Copy link"], #line),
        ]
        for item in cases {
            XCTAssertEqual(MessageActionMenu.items(for: message, link: URL(string: item.link)!).map(\.title), item.actions + reading, item.link, line: item.line)
        }
        XCTAssertEqual(MessageActionMenu.items(for: message).map(\.title), reading)
        let unreadable = TimelineMessage(id: "u", body: "", isOutgoing: false, isStarred: false, unreadable: .decryptFailed)
        XCTAssertEqual(MessageActionMenu.items(for: unreadable, link: URL(string: "https://example.org")!).map(\.title), ["Encryption details"])
    }

    /// A file opens once on disk and can be fetched while it waits for a tap or failed; an unsent message's file cannot.
    func testAFileOffersOpenOrDownloadByWhereItStands() {
        func file(_ download: AttachmentDownloadState, on disk: URL? = nil, retracted: Bool = false) -> TimelineMessage {
            TimelineMessage(id: "f", body: "", isOutgoing: false, isStarred: false,
                            attachment: TimelineAttachment(name: "IMG.jpg", mediaType: "image/jpeg", size: 1, width: nil, height: nil, localURL: disk, download: download),
                            isRetracted: retracted)
        }
        let url = URL(fileURLWithPath: "/tmp/IMG.jpg")
        XCTAssertEqual(MessageActionMenu.attachmentAction(for: file(.loading, on: url))?.action, .open(url))
        XCTAssertEqual(MessageActionMenu.attachmentAction(for: file(.loading, on: url))?.title, "Open photo")
        XCTAssertEqual(MessageActionMenu.attachmentAction(for: file(.tapToDownload(.size)))?.title, "Download photo")
        XCTAssertEqual(MessageActionMenu.attachmentAction(for: file(.failed))?.action, .download)
        XCTAssertNil(MessageActionMenu.attachmentAction(for: file(.loading)))
        XCTAssertNil(MessageActionMenu.attachmentAction(for: file(.tooLarge)))
        XCTAssertNil(MessageActionMenu.attachmentAction(for: file(.tapToDownload(.size), retracted: true)))
    }

    func testReactionTogglesNameWhatATapWouldDo() {
        var message = TimelineMessage(id: "m", body: "Hi", isOutgoing: false, isStarred: false,
                                      reactions: [TimelineReaction(emoji: "👍", count: 2, isSelected: true), TimelineReaction(emoji: "❤️", count: 1, isSelected: false)])
        XCTAssertTrue(MessageActionMenu.reactionToggles(for: message).isEmpty, "no toggles where reacting is unavailable")
        message.canReact = true
        XCTAssertEqual(MessageActionMenu.reactionToggles(for: message).map(\.title), [
            "Add heart reaction", "Remove thumbs up reaction", "Add tears of joy reaction",
            "Add surprised reaction", "Add sad reaction", "Add folded hands reaction",
        ])
    }

    func testVoiceOverReadsWhatTheBubbleShows() {
        let own = TimelineMessage(id: "own", body: "See you there", isOutgoing: true, isStarred: true, sentAt: sentAt, status: .failed,
                                  failure: "Their server refused it.", reactions: [TimelineReaction(emoji: "👍", count: 1, isSelected: false)], isEdited: true)
        let label = own.accessibilityDescription
        XCTAssertTrue(label.hasPrefix("You: See you there, edited, starred, "), label)
        XCTAssertTrue(label.hasSuffix(", Not delivered: Their server refused it., 1 thumbs up reaction"), label)
        let received = TimelineMessage(id: "in", body: "Ten it is", isOutgoing: false, isStarred: false, author: "maya")
        XCTAssertEqual(received.accessibilityDescription, "maya: Ten it is")
    }
}
