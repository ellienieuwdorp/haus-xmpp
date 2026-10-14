import ImageIO
import MessageStore
import OMEMO
import UIKit
import XCTest
@testable import HausXMPP

/// What the open conversation derives from the model: the status a sent message may claim, the reaction summary, quotes,
/// who is shown typing, which message moves the read marker and what an empty chat says.
@MainActor
final class ConversationPresenterTests: XCTestCase {
    private static let account = "me@example.org"
    private static let peer = "alex@example.org"
    private static let room = "room@groups.example.org"

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
        /// Senders our fetch may run for; the rule itself is `LinkPreviewPolicyTests`'.
        var fetchedFor: Set<String> = [ConversationPresenterTests.peer]
        func mayFetchLinkPreview(for message: StoredMessage) -> Bool { fetchedFor.contains(message.senderID) }
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

    /// One card per message: the preview it carries while that link is still in the body (whatever the fetch setting;
    /// a corrected body that dropped the link drops it), else our fetch for its first previewable link, else none and
    /// a request for one. Never on a file, an unsent or an unreadable message. The host is always the body link's.
    func testACardShowsTheCarriedPreviewElseOurFetchForTheFirstLink() throws {
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300), format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }())
            .pngData { $0.fill(CGRect(x: 0, y: 0, width: 600, height: 300)) }
        let fetchedImage = URL(fileURLWithPath: "/tmp/link-previews/news.jpg")
        source.linkPreviews = ["https://news.example/b": FetchedLinkPreview(title: "Fetched", summary: "From the page", imageFile: fetchedImage,
                                                                            imageWidth: 1200, imageHeight: 630)]
        var carried = message("carried", body: "see example.org/a and https://news.example/b")
        carried.linkPreview = StoredLinkPreview(url: "https://example.org/a", title: "Carried", summary: "From the sender", imageData: wide,
                                                imageType: "image/png", imageAlt: "A bridge", source: .sender)
        var corrected = message("corrected", body: "now https://News.example/b instead")
        corrected.linkPreview = StoredLinkPreview(url: "https://gone.example/", title: "Gone", source: .sender)
        var file = message("file", body: "https://news.example/b")
        file.attachment = StoredAttachment(name: "photo.jpg", mediaType: "image/jpeg", size: 1, hash: "", secret: Data())
        source.messages = [carried, corrected, message("waiting", body: "https://other.example/c"), message("plain", body: "No links here"), file,
                           message("unsent", body: "https://news.example/b", retracted: true)]

        let first = try XCTUnwrap(try shown("carried").linkPreview)
        XCTAssertEqual(first, TimelineLinkPreview(url: URL(string: "https://example.org/a")!, host: "example.org", title: "Carried", summary: "From the sender",
                                                  image: .data(wide), imageAlt: "A bridge", variant: .large, imageAspectRatio: 2))
        XCTAssertFalse(try shown("carried").wantsLinkPreview)

        // The cache is keyed by the normalised link; the card keeps the link as the body writes it.
        let fetched = try XCTUnwrap(try shown("corrected").linkPreview)
        XCTAssertEqual(fetched.url.absoluteString, "https://News.example/b")
        XCTAssertEqual(fetched.host, "news.example")
        XCTAssertEqual(fetched.title, "Fetched")
        XCTAssertEqual(fetched.image, .file(fetchedImage))
        XCTAssertEqual(fetched.variant, .large)
        XCTAssertEqual(try XCTUnwrap(fetched.imageAspectRatio), 1200.0 / 630, accuracy: 0.001)

        XCTAssertNil(try shown("waiting").linkPreview)
        XCTAssertTrue(try shown("waiting").wantsLinkPreview, "no card yet: the bubble asks for one when shown")
        for id in ["plain", "file", "unsent"] {
            XCTAssertNil(try shown(id).linkPreview, id)
            XCTAssertFalse(try shown(id).wantsLinkPreview, id)
        }
    }

    /// Our cache only shows where we would fetch: a link another message fetched stays bare on our own message (the
    /// peer got nothing with it, as when a legacy chat dropped our preview) and on a sender we never fetch for.
    func testOurFetchShowsOnlyWhereWeWouldFetch() throws {
        source.linkPreviews = ["https://news.example/b": FetchedLinkPreview(title: "Fetched", summary: nil)]
        source.groups = [Self.room]
        source.messages = [message("contact", body: "https://news.example/b"),
                           message("own", from: Self.account, body: "https://news.example/b", transport: .serverAccepted),
                           message("stranger", from: "\(Self.room)/sam", chat: Self.room, body: "https://news.example/b")]

        XCTAssertEqual(try shown("contact").linkPreview?.title, "Fetched")
        for shown in [try shown("own"), try shown("stranger", in: presenter(chatID: Self.room))] {
            XCTAssertNil(shown.linkPreview, shown.id)
            XCTAssertFalse(shown.wantsLinkPreview, shown.id)
        }
    }

    /// A carried image is judged by its header before anything decodes it: a few kilobytes can declare a canvas that
    /// takes hundreds of megabytes to inflate, so an image over the pixel budget is dropped and the card shows its text.
    /// A correction keeps the message ID, so one that swaps the image for another of the same byte count is read afresh.
    func testACarriedImageDeclaringAHugeCanvasLeavesATextCard() throws {
        // Two valid blank 1-bit PNGs padded to the same length: 600 x 300 px, and 5,000 x 5,000 px (25 MP) in a few KB.
        var honest = Self.blankPNG(width: 600, height: 300)
        var huge = Self.blankPNG(width: 5_000, height: 5_000)
        let length = max(honest.count, huge.count) + 64
        honest = Self.padded(honest, to: length)
        huge = Self.padded(huge, to: length)
        XCTAssertEqual(honest.count, huge.count)
        XCTAssertLessThan(huge.count, 64 * 1024, "within the wire's embedded image limit")
        let claimed = try XCTUnwrap(CGImageSourceCreateWithData(huge as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])
        XCTAssertEqual(claimed[kCGImagePropertyPixelWidth] as? Int, 5_000, "ImageIO reads the claimed canvas")

        var sent = message("m", body: "see https://example.org/a")
        sent.linkPreview = StoredLinkPreview(url: "https://example.org/a", title: "Bridge", imageData: honest, imageType: "image/png", source: .sender)
        source.messages = [sent]
        XCTAssertEqual(try shown("m").linkPreview?.variant, .large)
        XCTAssertEqual(try shown("m").linkPreview?.imageAspectRatio, 2)

        sent.linkPreview?.imageData = huge
        source.messages = [sent]
        let card = try XCTUnwrap(try shown("m").linkPreview)
        XCTAssertNil(card.image)
        XCTAssertEqual(card.variant, .text)
        XCTAssertNil(card.imageAspectRatio)
        XCTAssertEqual(card.title, "Bridge")
    }

    /// A blank grayscale 1-bit PNG, written by hand: drawing a canvas this size to encode it would take the memory the
    /// test is about.
    private static func blankPNG(width: UInt32, height: UInt32) -> Data {
        let row = 1 + (Int(width) + 7) / 8
        let raw = Data(count: row * Int(height))
        // zlib around raw deflate: header, data, Adler-32 of the zero bytes (a stays 1, b counts them).
        var zlib = Data([0x78, 0x9C])
        zlib.append(try! (raw as NSData).compressed(using: .zlib) as Data)
        zlib.append(contentsOf: bigEndian(UInt32(raw.count % 65_521) << 16 | 1))
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk("IHDR", bigEndian(width) + bigEndian(height) + [1, 0, 0, 0, 0]))
        png.append(chunk("IDAT", [UInt8](zlib)))
        png.append(chunk("IEND", []))
        return png
    }

    /// `png` with a text chunk after its header that brings it to `length` bytes.
    private static func padded(_ png: Data, to length: Int) -> Data {
        let filler = [UInt8]("Comment".utf8) + [0] + [UInt8](repeating: 0x20, count: length - png.count - 20)
        return png.prefix(33) + chunk("tEXt", filler) + png.dropFirst(33)
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> Data {
        let typed = [UInt8](type.utf8) + body
        return Data(bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed)))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    func testTypingShowsAtTheEndOfTheWholeChatOnly() {
        source.openChatTyping = [Self.peer]
        XCTAssertEqual(presenter().typing, TimelineTyping(author: nil, colorKey: Self.peer, accessibilityLabel: "Alex is typing…"))
        XCTAssertNil(presenter(searching: true).typing, "search lists a slice of history")
        XCTAssertNil(presenter(starred: true).typing)
        source.openChatTyping = nil
        XCTAssertNil(presenter().typing)

        let room = Self.room
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
