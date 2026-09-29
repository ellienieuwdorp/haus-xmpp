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
    #expect(plan.requests[0].communication == NotificationCommunication(
        sender: .init(handle: "peer@example.org", displayName: "Peer", avatarHash: "abc"),
        conversationIdentifier: plan.requests[0].threadIdentifier, account: .init(handle: account, displayName: "me", avatarHash: nil), body: "One"))
    #expect(plan.requests.allSatisfy { $0.badge == nil })
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
    // No name or avatar reaches the system: no communication notification at all.
    #expect(plan.requests.allSatisfy { $0.communication == nil })
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

@Test func undisplayableIncomingMessagesUseReviewWordingWithoutContent() throws {
    let pending = candidate("p", body: "", key: .pending(sender: "peer@example.org", digest: "d")).withContent(.pendingEncrypted)
    let placeholderID = "unreadable-" + String(repeating: "0f", count: 32)
    let unreadable = candidate(placeholderID, body: "").withContent(.unreadable(messageID: placeholderID))
    let groupPending = candidate("g", chat: "room@rooms", sender: "bob@x", chatTitle: "Book club", key: .pending(sender: "bob@x", digest: "e"))
        .withContent(.pendingEncrypted)
    let plan = NotificationPlanner.plan(batch([pending, unreadable, groupPending]))
    #expect(plan.requests.map(\.body) == ["Sent an encrypted message. Open the chat to review.", "Sent a message this device can't read",
                                          "bob: Sent an encrypted message. Open the chat to review."])
    #expect(plan.requests.map(\.title) == ["Peer", "Peer", "Book club"])
    // No tap destination; a cleanup reference without address or content: the placeholder's opaque row ID, or nothing.
    #expect(plan.requests.allSatisfy { $0.destination == nil && $0.userInfo[NotificationDestination.userInfoKey] == nil })
    #expect(plan.requests.map { $0.reference?.kind } == [.retained, .placeholder, .retained])
    // Nothing to reply to or mark read from the notification: the category without actions.
    #expect(plan.requests.allSatisfy { $0.categoryIdentifier == NotificationIdentity.noticeCategory })
    #expect(plan.requests[0].userInfo == [NotificationReference.userInfoKey: ["version": "1", "kind": "retained",
                                                                               "account": try #require(plan.requests[0].reference).accountScope]])
    // Stable per ciphertext, distinct from any message identity.
    #expect(plan.requests[0].identifier == NotificationPlanner.identifier(for: pending))
    #expect(plan.requests[0].identifier.hasPrefix("m-") && plan.requests[0].identifier != plan.requests[2].identifier)
    // Neither retained ciphertext (possibly a stranger awaiting trust) nor an undecryptable placeholder makes its sender
    // a communication partner: they post plain even with previews on. A committed message does.
    #expect(plan.requests.allSatisfy { $0.communication == nil })
    #expect(NotificationPlanner.plan(batch([candidate(UUID().uuidString)])).requests.first?.communication != nil)
}

@Test func reactionDestinationsRoundTripAndLeaveMessagePayloadsUnchanged() throws {
    let id = UUID().uuidString
    let message = try #require(NotificationDestination(accountID: account, messageID: id))
    #expect(message.kind == .message && Set(message.payload.keys) == ["version", "account", "message"])
    #expect(NotificationDestination(payload: message.payload) == message)
    let reaction = try #require(NotificationDestination(accountID: account, messageID: id, kind: .reaction))
    #expect(reaction.payload["kind"] == "reaction" && NotificationDestination(payload: reaction.payload) == reaction)
    #expect(reaction != message)
    var unknown = reaction.payload; unknown["kind"] = "message"
    #expect(NotificationDestination(payload: unknown) == nil, "only the reaction kind is spelled out")
    var extra = message.payload; extra["title"] = "Bob"
    #expect(NotificationDestination(payload: extra) == nil)
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

@Test func anUnsentOldestMessageHandsItsEarlierCountToTheNextOne() {
    var unsent = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "peer@example.org", senderID: "peer@example.org", body: "", encryptionProfile: "modern")
    unsent.isRetracted = true
    let plan = NotificationPlanner.plan(batch([candidate(unsent.id, at: 1, earlier: 2).withContent(.message(unsent)),
                                               candidate(UUID().uuidString, chat: "other@example.org", body: "Elsewhere", at: 2),
                                               candidate(UUID().uuidString, body: "Kept", at: 3)]))
    #expect(plan.requests.map(\.body) == ["Elsewhere", "Kept\nand 2 more"])
}

@Test func chatsBeyondTheCapGetOneSummaryThatNeverTakesTheSound() throws {
    let newest = UUID().uuidString
    let capped = MessageNotification(candidates: [candidate(newest, body: "Newest", at: 9)], claimed: [.message(newest)],
                                     deferredCount: 7, deferredChatCount: 3, previewsEnabled: false)
    let plan = NotificationPlanner.plan(capped)
    #expect(plan.summarizesDeferredChats)
    #expect(plan.requests.map(\.identifier) == [NotificationIdentity.overflow(accountID: account), NotificationIdentity.message(accountID: account, messageID: newest)])
    #expect(plan.requests.map(\.body) == ["New messages in 3 more chats", "New message"])
    #expect(plan.requests.map(\.playsSound) == [false, true])
    #expect(plan.requests[0].title.isEmpty && plan.requests[0].userInfo.isEmpty && plan.requests[0].categoryIdentifier == NotificationIdentity.noticeCategory)
    // Only the deferred chats: a summary alone still sounds, and the account comes from the caller.
    let alone = NotificationPlanner.plan(MessageNotification(candidates: [], claimed: [], deferredCount: 1, deferredChatCount: 1, previewsEnabled: true),
                                         accountID: account)
    #expect(alone.requests.map(\.body) == ["New messages in 1 more chat"] && alone.requests[0].playsSound)
    #expect(!NotificationPlanner.plan(batch([candidate(newest)])).summarizesDeferredChats)
}

@Test func cleanupReferencesRoundTripAndRejectAddresses() throws {
    let placeholder = try #require(NotificationReference.placeholder(accountID: account, messageID: "unreadable-" + String(repeating: "ab", count: 32)))
    #expect(NotificationReference(payload: placeholder.payload) == placeholder && placeholder.belongs(to: account) && !placeholder.belongs(to: "x@y"))
    let retained = try #require(NotificationReference.retained(accountID: account))
    #expect(NotificationReference(payload: retained.payload) == retained && retained.messageID == nil)
    #expect(NotificationReference.placeholder(accountID: account, messageID: "peer@example.org") == nil)
    #expect(NotificationReference.placeholder(accountID: account, messageID: UUID().uuidString) == nil)
    var extra = retained.payload; extra["message"] = "unreadable-" + String(repeating: "ab", count: 32)
    #expect(NotificationReference(payload: extra) == nil)
    #expect(!String(describing: placeholder.payload).contains("@"))
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
    let failure = NotificationIdentity.replyFailure(accountID: "me@example.org", chatID: "peer@example.org")
    #expect(failure.hasPrefix("e-") && !failure.contains("peer") && failure != NotificationIdentity.replyFailure(accountID: "me@example.org", chatID: "carol@example.org"))
}

extension NotificationCandidate {
    func withContent(_ content: Content) -> NotificationCandidate {
        NotificationCandidate(key: key, accountID: accountID, chatID: chatID, chatTitle: chatTitle, chatAvatarHash: chatAvatarHash,
                              senderID: senderID, senderTitle: senderTitle, isGroup: isGroup, sentAt: sentAt, content: content, earlierCount: earlierCount)
    }
}

// MARK: Communication notifications, badge and reactions (wave 2, stream D)

@Test func groupCommunicationNamesTheSenderTheRoomAndOtherMembers() throws {
    let members = [NotificationParticipant(id: "carol@x", title: "Carol", avatarHash: "c"), NotificationParticipant(id: account, title: nil, avatarHash: nil),
                   NotificationParticipant(id: "bob@x", title: "Bob", avatarHash: "b")]
    let message = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "room@rooms", senderID: "bob@x", body: "Hi all", encryptionProfile: "modern")
    let group = NotificationCandidate(key: .message(message.id), accountID: account, chatID: "room@rooms", chatTitle: "Book club", chatAvatarHash: "room",
                                      senderID: "bob@x", senderTitle: "Bob", senderAvatarHash: "b", isGroup: true, sentAt: message.sentAt,
                                      content: .message(message), groupMembers: members)
    let request = try #require(NotificationPlanner.plan(batch([group]), badge: 4).requests.first)
    let communication = try #require(request.communication)
    #expect(communication.sender == .init(handle: "bob@x", displayName: "Bob", avatarHash: "b"))
    #expect(communication.groupName == "Book club" && communication.groupAvatarHash == "room" && communication.isGroup)
    #expect(communication.conversationIdentifier == NotificationIdentity.thread(accountID: account, chatID: "room@rooms"))
    // Never the sender or the account among the other recipients.
    #expect(communication.otherRecipients == [.init(handle: "carol@x", displayName: "Carol", avatarHash: "c")])
    #expect(request.badge == 4)
    // The system names the sender in a group's communication notification; the plain fallback keeps the prefix.
    #expect(request.body == "Bob: Hi all" && communication.body == "Hi all")
    #expect(!String(describing: communication).contains("Bob"))
}

private func reaction(_ emoji: [String], chat: String = "peer@example.org", actor: String = "peer@example.org", actorTitle: String? = "Peer",
                      target body: String = "Lunch at noon?", at: TimeInterval = 5, sequence: Int = 1) -> ReactionNotificationCandidate {
    let target = StoredMessage(id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", accountID: account, chatID: chat, senderID: account, body: body,
                               isOutgoing: true, encryptionProfile: "modern")
    return ReactionNotificationCandidate(key: .reaction(sequence: sequence), accountID: account, chatID: chat, chatTitle: chat == actor ? "Peer" : "Book club",
                                         actor: NotificationParticipant(id: actor, title: actorTitle, avatarHash: "a"), isGroup: chat != actor,
                                         target: target, reactions: emoji, reactedAt: Date(timeIntervalSince1970: at))
}

@Test func reactionsReadAsReactedToTheQuotedMessageAndReplaceByActorAndTarget() throws {
    let direct = reaction(["👍"])
    let group = reaction(["❤️", "🔥"], chat: "room@rooms", actor: "bob@x", actorTitle: "Bob", target: String(repeating: "long ", count: 80), at: 6, sequence: 2)
    let message = candidate(UUID().uuidString, body: "Newest message", at: 7)
    let batch = MessageNotification(candidates: [message], claimed: [message.key, direct.key, group.key], previewsEnabled: true, reactions: [direct, group])
    let plan = NotificationPlanner.plan(batch, badge: 2)
    #expect(plan.requests.map(\.body).first == "Reacted 👍 to “Lunch at noon?”")
    #expect(plan.requests[1].body.hasPrefix("Bob reacted ❤️🔥 to “long long") && plan.requests[1].body.hasSuffix("…”"))
    #expect(plan.requests[1].body.count < 280)
    #expect(plan.requests.map(\.title) == ["Peer", "Book club", "Peer"])
    // By time: the message is newest and alone plays the sound.
    #expect(plan.requests.map(\.playsSound) == [false, false, true])
    #expect(plan.requests[0].identifier == NotificationIdentity.reaction(accountID: account, chatID: "peer@example.org", actorID: "peer@example.org",
                                                                          targetMessageID: direct.target.id))
    #expect(plan.requests[0].threadIdentifier == NotificationIdentity.thread(accountID: account, chatID: "peer@example.org"))
    // A tap opens the reacted-to own message's chat; a cleanup reference that names only the local message ID.
    let destination = try #require(plan.requests[0].destination)
    #expect(destination.kind == .reaction && destination.messageID == direct.target.id && destination.belongs(to: account))
    #expect(plan.requests[0].reference == .reaction(accountID: account, targetMessageID: direct.target.id))
    #expect(plan.requests[1].communication?.sender.handle == "bob@x" && plan.requests[1].communication?.groupName == "Book club")
    #expect(plan.requests[1].communication?.body.hasPrefix("Reacted ❤️🔥 to “long long") == true)
    #expect(plan.requests[0].communication?.body == plan.requests[0].body)
    #expect(plan.requests.allSatisfy { $0.badge == 2 })
    // Reactions have their own category, without the message actions; the message keeps its own.
    #expect(plan.requests.map(\.categoryIdentifier) == [NotificationIdentity.reactionCategory, NotificationIdentity.reactionCategory,
                                                        NotificationIdentity.messageCategory])
    #expect(plan.claimed.count == 3)
    // The identifier is per actor and target, whatever the emoji.
    #expect(NotificationPlanner.plan(MessageNotification(candidates: [], claimed: [], previewsEnabled: true, reactions: [reaction(["🎉"], sequence: 9)]))
                .requests[0].identifier == plan.requests[0].identifier)
}

@Test func hiddenPreviewReactionsNameNobody() throws {
    let plan = NotificationPlanner.plan(MessageNotification(candidates: [], claimed: [], previewsEnabled: false,
                                                            reactions: [reaction(["👍"]), reaction(["😂"], chat: "room@rooms", actor: "bob@x", sequence: 2)]))
    #expect(plan.requests.map(\.body) == ["Reacted to your message", "Reacted to your message"])
    #expect(plan.requests.allSatisfy { $0.title.isEmpty && $0.communication == nil })
    // A file without text is named by its kind.
    var file = reaction(["👍"], target: "")
    file = ReactionNotificationCandidate(key: file.key, accountID: account, chatID: file.chatID, chatTitle: file.chatTitle, actor: file.actor, isGroup: false,
                                         target: StoredMessage(id: file.target.id, accountID: account, chatID: file.chatID, senderID: account, body: "",
                                                               isOutgoing: true, encryptionProfile: "modern",
                                                               attachment: StoredAttachment(name: "p.jpg", mediaType: "image/jpeg", size: 1, hash: "h", secret: Data())),
                                         reactions: ["👍"], reactedAt: file.reactedAt)
    #expect(NotificationPlanner.reactionBody(file) == "Reacted 👍 to your photo")
    let reference = try #require(NotificationReference.reaction(accountID: account, targetMessageID: file.target.id))
    #expect(NotificationReference(payload: reference.payload) == reference && reference.kind == .reaction)
    #expect(NotificationReference.reaction(accountID: account, targetMessageID: "peer@example.org") == nil)
    #expect(NotificationReference(payload: ["version": "1", "account": reference.accountScope, "kind": "reaction", "message": "bob@x"]) == nil)
}

@Test func badgeCountsUnreadOutsideMutedChats() {
    let now = Date(timeIntervalSince1970: 1_000)
    let unread = ["a": 3, "b": 2, "c": 4, "d": 1]
    let settings: [String: ChatNotificationSetting] = [
        "b": ChatNotificationSetting(mutedUntil: now.addingTimeInterval(60)),       // muted: excluded
        "c": ChatNotificationSetting(mutedUntil: now.addingTimeInterval(-60)),      // expired: counts
        "d": ChatNotificationSetting(level: .mentions)                              // mentions only: counts
    ]
    #expect(NotificationBadge.count(unread: unread, settings: settings, now: now) == 8)
    #expect(NotificationBadge.count(unread: [:], settings: settings, now: now) == 0)
    #expect(NotificationBadge.count(unread: ["b": 5], settings: ["b": ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always)], now: now) == 0)
}

@Test func donationBudgetBoundsEachDonationAndTheirTotal() {
    let budget = DonationBudget(.seconds(3))
    #expect(budget.next(maximum: .milliseconds(2500)) == .milliseconds(2500))
    budget.spend(.milliseconds(2500))
    #expect(budget.next(maximum: .milliseconds(2500)) == .milliseconds(500))
    budget.spend(.milliseconds(400))
    #expect(budget.next(maximum: .milliseconds(2500)) == nil)
}
