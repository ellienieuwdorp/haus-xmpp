import MessageStore
import OMEMO
import XCTest
@testable import HausXMPP

/// What the open conversation derives from the model: the status a sent message may claim, the reaction summary, quotes,
/// who is shown typing, which message moves the read marker and what an empty chat says.
@MainActor
final class ConversationPresenterTests: XCTestCase {
    private static let account = "me@example.org"
    private static let peer = "alex@example.org"

    private final class Source: ConversationSource {
        var accountID = ConversationPresenterTests.account
        var isDemo = false
        var messages: [ChatMessage] = []
        var messagesLoadedFor: String? = ConversationPresenterTests.peer
        var messageReactions: [String: [AuthenticatedReaction]] = [:]
        var messageReceipts: [String: MessageEventKind] = [:]
        var attachmentFiles: [String: URL] = [:]
        var attachmentDownloads: [String: AttachmentDownloadState] = [:]
        var linkPreviews: [String: FetchedLinkPreview] = [:]
        var linkPreviewUploadHosts: Set<String> = []
        var encryptionOverview: EncryptionOverview?
        var openChatTyping: [String]?
        var groups: Set<String> = []
        var reactable = false
        func isGroup(_ chatID: String) -> Bool { groups.contains(chatID) }
        func canSend(to chatID: String) -> Bool { true }
        func canReact(to message: StoredMessage) -> Bool { reactable }
        func canRevise(_ message: StoredMessage) -> Bool { false }
        func isBackfilling(chat: String) -> Bool { false }
        func linkPreviewDisplayed(_ messageID: String) {}
    }

    private let source = Source()

    private func presenter(chatID: String = peer, search: String = "", starred: Bool = false, searching: Bool = false) -> ConversationPresenter {
        ConversationPresenter(source: source, chatID: chatID, title: "Alex", searchTerm: search, starredOnly: starred, showingSearch: searching)
    }

    private func message(_ id: String, from sender: String = peer, chat: String = peer, body: String = "Hi", transport: OutgoingTransportState? = nil,
                         reply: MessageReply? = nil, unreadable: UnreadableReason? = nil, retracted: Bool = false) -> ChatMessage {
        var message = StoredMessage(id: id, accountID: Self.account, chatID: chat, senderID: sender, body: body,
                                    isOutgoing: sender == Self.account, transportState: transport, reply: reply, encryptionProfile: "modern",
                                    unreadableReason: unreadable)
        message.isRetracted = retracted
        return message
    }

    private func shown(_ id: String, in presenter: ConversationPresenter? = nil) throws -> TimelineMessage {
        try XCTUnwrap((presenter ?? self.presenter()).timelineMessages.first { $0.id == id }, id)
    }

    /// A socket write is not delivery: receipts count only once the server accepted the message, and an own message
    /// with no outbox row (archive, carbon) is already held by the server.
    func testASentMessageClaimsDeliveryOnlyAfterTheServerAcceptedIt() throws {
        let cases: [(transport: OutgoingTransportState?, receipt: MessageEventKind?, status: TimelineMessage.Status, line: UInt)] = [
            (.queued, .delivered, .queued, #line),
            (.submitting, .displayed, .submitting, #line),
            (.unconfirmed, .delivered, .unconfirmed, #line),
            (.failed, nil, .failed, #line),
            (.serverAccepted, nil, .serverAccepted, #line),
            (nil, nil, .serverAccepted, #line),
            (.serverAccepted, .delivered, .delivered, #line),
            (nil, .displayed, .displayed, #line),
        ]
        for (index, entry) in cases.enumerated() {
            let id = "own\(index)"
            source.messages = [message(id, from: Self.account, transport: entry.transport)]
            source.messageReceipts = entry.receipt.map { [id: $0] } ?? [:]
            XCTAssertEqual(try shown(id).status, entry.status, line: entry.line)
        }
        source.messages = [message("in")]
        source.messageReceipts = ["in": .displayed]
        XCTAssertNil(try shown("in").status, "a received message shows no status")
    }

    /// One pill per emoji with everyone's count: the quick choices in menu order first, others after them by emoji,
    /// ringed where the user is among the reactors. An unsent message keeps none.
    func testReactionsSummariseEveryActorInMenuOrder() throws {
        source.reactable = true
        source.messages = [message("m"), message("gone", retracted: true)]
        func reaction(_ actor: String, _ emoji: [String], on id: String) -> AuthenticatedReaction {
            AuthenticatedReaction(id: "\(actor)-\(id)", chatID: Self.peer, actorID: actor, targetWireID: id, reactions: emoji, updatedAt: .now)
        }
        source.messageReactions = [
            "m": [reaction(Self.peer, ["🎉", "👍", "❤️"], on: "m"), reaction(Self.account, ["👍", "🔥"], on: "m"), reaction("sam@example.org", ["👍"], on: "m")],
            "gone": [reaction(Self.peer, ["❤️"], on: "gone")],
        ]
        XCTAssertEqual(try shown("m").reactions, [
            TimelineReaction(emoji: "❤️", count: 1, isSelected: false),
            TimelineReaction(emoji: "👍", count: 3, isSelected: true),
            TimelineReaction(emoji: "🎉", count: 1, isSelected: false),
            TimelineReaction(emoji: "🔥", count: 1, isSelected: true),
        ])
        XCTAssertTrue(try shown("m").canReact)
        XCTAssertEqual(try shown("gone").reactions, [])
        XCTAssertFalse(try shown("gone").canReact)
    }

    /// A quote shows its snapshot unless the quoted message was unsent since; a quoted photo keeps its still's slot from
    /// the snapshot's media type before the photo itself is loaded.
    func testQuotesFollowTheQuotedMessage() throws {
        source.messages = [
            message("unsent", body: "", retracted: true),
            message("text", from: Self.account, reply: MessageReply(messageID: "unsent", senderID: Self.peer, body: "See you at ten")),
            message("photo", reply: MessageReply(messageID: "elsewhere", senderID: Self.account, body: "Photo", mediaType: "image/jpeg")),
        ]
        let text = try XCTUnwrap(try shown("text").reply)
        XCTAssertEqual(text.author, "Alex")
        XCTAssertEqual(text.body, "Message unsent")
        XCTAssertNil(text.thumbnail)
        let photo = try XCTUnwrap(try shown("photo").reply)
        XCTAssertEqual(photo.author, "you")
        XCTAssertEqual(photo.thumbnail?.mediaType, "image/jpeg")
        XCTAssertNil(photo.thumbnail?.localURL, "not loaded, so nothing to show in the slot yet")
    }

    func testTypingShowsAtTheEndOfTheWholeChatOnly() {
        source.openChatTyping = [Self.peer]
        XCTAssertEqual(presenter().typing, TimelineTyping(author: nil, colorKey: Self.peer, accessibilityLabel: "Alex is typing…"))
        XCTAssertNil(presenter(searching: true).typing, "search lists a slice of history")
        XCTAssertNil(presenter(starred: true).typing)
        source.openChatTyping = nil
        XCTAssertNil(presenter().typing)

        let room = "room@groups.example.org"
        source.groups = [room]
        source.openChatTyping = ["maya@example.org", "sam@example.org"]
        XCTAssertEqual(presenter(chatID: room).typing,
                       TimelineTyping(author: "maya, sam", colorKey: "maya@example.org", accessibilityLabel: "maya and sam are typing…"))
    }

    /// A marker covers everything before it, so only the newest received message sends one: the newest readable one
    /// (the peer hears about it) and the newest of any kind (the read pointer goes there).
    func testOnlyTheNewestReceivedMessagesMoveTheReadMarker() {
        source.messages = [message("older"), message("readable"), message("unreadable", body: "", unreadable: .notForThisDevice),
                           message("own", from: Self.account)]
        XCTAssertFalse(presenter().marksDisplayed("older"))
        XCTAssertTrue(presenter().marksDisplayed("readable"))
        XCTAssertTrue(presenter().marksDisplayed("unreadable"))
        XCTAssertFalse(presenter().marksDisplayed("own"))
    }

    /// Opening a chat never flashes "No messages yet" while its first page is on the way.
    func testOnlyALoadedEmptyChatSaysSo() {
        func notice(isEmpty: Bool = true, loadedFor: String?, search: String = "", starred: Bool = false) -> String? {
            ConversationPresenter.emptyNotice(isEmpty: isEmpty, loadedFor: loadedFor, chatID: "alex", searchTerm: search, starredOnly: starred)?.title
        }
        XCTAssertNil(notice(loadedFor: nil), "the first page is still loading")
        XCTAssertNil(notice(loadedFor: "maya"), "the loaded page is the previous chat's")
        XCTAssertNil(notice(isEmpty: false, loadedFor: "alex"))
        XCTAssertEqual(notice(loadedFor: "alex"), "No messages yet")
        XCTAssertEqual(notice(loadedFor: "alex", starred: true), "No starred messages")
        XCTAssertEqual(notice(loadedFor: "alex", search: "ten", starred: true), "No matching messages")
        XCTAssertNil(notice(loadedFor: nil, search: "ten"), "a search waits for the load too")

        // The filters decide emptiness: a chat with messages, none of them starred or matching.
        source.messages = [message("m", body: "Ten it is")]
        XCTAssertNil(presenter().emptyNotice)
        XCTAssertEqual(presenter(starred: true).emptyNotice?.title, "No starred messages")
        XCTAssertEqual(presenter(search: "eleven").emptyNotice?.title, "No matching messages")
        XCTAssertNil(presenter(search: "ten").emptyNotice, "search ignores case")
    }
}
