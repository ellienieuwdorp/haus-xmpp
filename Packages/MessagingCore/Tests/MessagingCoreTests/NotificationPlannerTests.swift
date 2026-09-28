import Foundation
import MessageStore
import Testing
@testable import MessagingCore

private let account = "me@example.org"

private func candidate(_ id: String, chat: String = "peer@example.org", sender: String? = nil, body: String = "Synthetic",
                       chatTitle: String? = "Peer", senderTitle: String? = nil, at: TimeInterval = 1, earlier: Int = 0,
                       avatar: String? = nil, content: NotificationCandidate.Content? = nil,
                       key: NotificationCandidateKey? = nil) -> NotificationCandidate {
    let author = sender ?? chat
    let message = StoredMessage(id: id, accountID: account, chatID: chat, senderID: author, body: body,
                                sentAt: Date(timeIntervalSince1970: at), encryptionProfile: "modern")
    return NotificationCandidate(key: key ?? .message(id), accountID: account, chatID: chat, chatTitle: chatTitle, chatAvatarHash: avatar,
                                 senderID: author, senderTitle: senderTitle, isGroup: author != chat, sentAt: message.sentAt,
                                 content: content ?? .message(message), earlierCount: earlier)
}

private func batch(_ candidates: [NotificationCandidate], previews: Bool = true) -> MessageNotification {
    MessageNotification(candidates: candidates, claimed: candidates.map(\.key), previewsEnabled: previews)
}

@Test func planPostsOneRequestPerMessageOldestFirstWithOneSound() throws {
    let first = UUID().uuidString, second = UUID().uuidString
    let plan = NotificationPlanner.plan(batch([candidate(first, body: "One", at: 1, avatar: "abc"), candidate(second, body: "Two", at: 2)]))
    #expect(plan.requests.map(\.body) == ["One", "Two"])
    #expect(plan.requests.map(\.playsSound) == [false, true])
    #expect(plan.requests.allSatisfy { $0.title == "Peer" && $0.categoryIdentifier == NotificationIdentity.messageCategory })
    #expect(plan.requests[0].identifier == NotificationIdentity.message(accountID: account, messageID: first))
    #expect(plan.requests[0].threadIdentifier == NotificationIdentity.thread(accountID: account, chatID: "peer@example.org"))
    #expect(plan.requests[0].destination == NotificationDestination(accountID: account, messageID: first))
    #expect(plan.requests[0].userInfo == [NotificationDestination.userInfoKey: try #require(plan.requests[0].destination).payload])
    #expect(plan.requests[0].avatarHash == "abc")
    #expect(plan.claimed == [.message(first), .message(second)])
    #expect(NotificationPlanner.plan(batch([])).requests.isEmpty)
}

@Test func hiddenPreviewsShowNoTitleSenderOrContent() {
    let id = UUID().uuidString
    let plan = NotificationPlanner.plan(batch([candidate(id, chat: "room@rooms", sender: "bob@x", body: "Secret", chatTitle: "Book club", avatar: "abc"),
                                               candidate("p", key: .pending(sender: "peer@example.org", digest: "d"))
                                                .withContent(.pendingEncrypted)], previews: false))
    #expect(plan.requests.map(\.title) == ["", ""])
    #expect(plan.requests.map(\.body) == ["New message", "New message"])
    #expect(plan.requests.allSatisfy { $0.avatarHash == nil })
    #expect(!String(describing: plan.requests.map(\.userInfo)).contains("Secret"))
    // Tap routing is unchanged by the privacy setting.
    #expect(plan.requests[0].destination == NotificationDestination(accountID: account, messageID: id))
}

@Test func groupRequestsAreTitledByTheRoomAndNameTheSender() {
    let plan = NotificationPlanner.plan(batch([
        candidate(UUID().uuidString, chat: "room@rooms", sender: "bob@x", body: "Hi all", chatTitle: "Book club", senderTitle: "Bob", at: 1),
        candidate(UUID().uuidString, chat: "room@rooms", sender: "carol@x", body: "Hello", chatTitle: "room@rooms", at: 2)]))
    #expect(plan.requests.map(\.title) == ["Book club", "room"])
    #expect(plan.requests.map(\.body) == ["Bob: Hi all", "carol: Hello"])
}

@Test func undisplayableIncomingMessagesUseReviewWordingWithoutContent() {
    let pending = candidate("p", body: "", key: .pending(sender: "peer@example.org", digest: "d")).withContent(.pendingEncrypted)
    let unreadable = candidate("unreadable-1", body: "").withContent(.unreadable(messageID: "unreadable-1"))
    let groupPending = candidate("g", chat: "room@rooms", sender: "bob@x", chatTitle: "Book club", key: .pending(sender: "bob@x", digest: "e"))
        .withContent(.pendingEncrypted)
    let plan = NotificationPlanner.plan(batch([pending, unreadable, groupPending]))
    #expect(plan.requests.map(\.body) == ["Sent an encrypted message. Open the chat to review.", "Sent a message this device can't read",
                                          "bob: Sent an encrypted message. Open the chat to review."])
    #expect(plan.requests.map(\.title) == ["Peer", "Peer", "Book club"])
    #expect(plan.requests.allSatisfy { $0.destination == nil && $0.userInfo.isEmpty })
    // Stable per ciphertext, distinct from any message identity.
    #expect(plan.requests[0].identifier == NotificationPlanner.identifier(for: pending))
    #expect(plan.requests[0].identifier.hasPrefix("m-") && plan.requests[0].identifier != plan.requests[2].identifier)
}

@Test func retractedMessagesAreClaimedButNeverShownAndOlderOnesSummarize() {
    var unsent = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "peer@example.org", senderID: "peer@example.org", body: "", encryptionProfile: "modern")
    unsent.isRetracted = true
    let kept = candidate(UUID().uuidString, body: "Newest", at: 3, earlier: 3)
    let plan = NotificationPlanner.plan(batch([candidate(unsent.id).withContent(.message(unsent)), kept]))
    #expect(plan.requests.map(\.body) == ["Newest\nand 3 more"])
    #expect(plan.requests.map(\.playsSound) == [true])
    #expect(plan.claimed.count == 2)
}

@Test func planBoundsUntrustedDisplayTextAndNamesFileKinds() {
    let hostile = candidate(UUID().uuidString, body: "\u{202E}" + String(repeating: "👩🏽‍💻", count: 300), chatTitle: String(repeating: "a", count: 500))
    let request = NotificationPlanner.plan(batch([hostile])).requests[0]
    #expect(request.body.count <= 241 && request.body.utf8.count <= 1024 && !request.body.contains("\u{202E}"))
    #expect(request.body.hasPrefix("👩🏽‍💻") && request.body.hasSuffix("…"))
    #expect(request.title.count <= 81 && request.title.utf8.count <= 320)
    let oversized = "a" + String(repeating: "\u{0301}", count: 3000)
    #expect(NotificationPlanner.plan(batch([candidate(UUID().uuidString, body: oversized, chatTitle: oversized)])).requests[0].body == "…")
    var photo = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "peer@example.org", senderID: "peer@example.org", body: "", encryptionProfile: "modern",
                              attachment: StoredAttachment(name: "beach.jpg", mediaType: "image/jpeg", size: 10, hash: "ab", secret: Data([1]), url: "https://u/x"))
    #expect(NotificationPlanner.plan(batch([candidate(photo.id).withContent(.message(photo))])).requests[0].body == "Photo")
    photo.attachment?.mediaType = "application/pdf"
    #expect(NotificationPlanner.plan(batch([candidate(photo.id).withContent(.message(photo))])).requests[0].body == "File")
}

@Test func notificationIdentitiesAreStableOpaqueAndScoped() {
    let thread = NotificationIdentity.thread(accountID: "me@example.org", chatID: "peer@example.org")
    #expect(thread == NotificationIdentity.thread(accountID: "me@example.org", chatID: "peer@example.org"))
    #expect(thread != NotificationIdentity.thread(accountID: "other@example.org", chatID: "peer@example.org"))
    let message = NotificationIdentity.message(accountID: "me@example.org", messageID: "8C1F2C1E-8E0B-4E0B-9E43-0B1C9E8A0F11")
    #expect(message.hasPrefix("m-") && !message.contains("example") && !message.contains("8C1F"))
    #expect(NotificationIdentity.fallback(accountID: "me@example.org") != NotificationIdentity.fallback(accountID: "other@example.org"))
    #expect(!thread.contains("peer"))
}

extension NotificationCandidate {
    func withContent(_ content: Content) -> NotificationCandidate {
        NotificationCandidate(key: key, accountID: accountID, chatID: chatID, chatTitle: chatTitle, chatAvatarHash: chatAvatarHash,
                              senderID: senderID, senderTitle: senderTitle, isGroup: isGroup, sentAt: sentAt, content: content, earlierCount: earlierCount)
    }
}
