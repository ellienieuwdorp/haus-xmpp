import Foundation
import MessageStore
import Testing
@testable import MessagingCore

private let account = "alice@example.org"

private func withStore(_ body: (MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "foreground-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
    try await store.acquireTransportOwnership()
    try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
    do { try await body(store); try await store.close() } catch { try? await store.close(); throw error }
}

@discardableResult
private func receive(_ store: MessageStore, chat: String, body: String = "Synthetic", at date: Date) async throws -> StoredMessage {
    let message = StoredMessage(id: UUID().uuidString, accountID: account, chatID: chat, senderID: chat, body: body,
                                sentAt: date, encryptionProfile: "modern")
    let revision = try #require(try await store.encryptionStateRevision(accountID: account))
    try await store.commitEncryptedIncoming(accountID: account, sender: chat, digest: message.id, expectedRevision: revision,
                                            state: Data([UInt8(revision % 250 + 1)]), message: message)
    return message
}

private func candidate(_ chat: String, at: TimeInterval) -> NotificationCandidate {
    let message = StoredMessage(id: UUID().uuidString, accountID: account, chatID: chat, senderID: chat, body: "Hi",
                                sentAt: Date(timeIntervalSince1970: at), encryptionProfile: "modern")
    return NotificationCandidate(key: .message(message.id), accountID: account, chatID: chat, chatTitle: nil, chatAvatarHash: nil,
                                 senderID: chat, senderTitle: nil, isGroup: false, sentAt: message.sentAt, content: .message(message), earlierCount: 0)
}

struct ForegroundNotificationTests {
    /// Ten minutes: tolerant of a sender clock that runs behind and of a short server queue, while history the
    /// connection caught up on stays silent.
    @Test func theWindowIsTenMinutesInclusive() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(NotificationPlanner.foregroundWindow == 600)
        let inside = candidate("carol@example.org", at: 10_000 - 599)
        let edge = candidate("dave@example.org", at: 10_000 - 600)
        let outside = candidate("erin@example.org", at: 10_000 - 601)
        let batch = MessageNotification(candidates: [inside, edge, outside], claimed: [inside.key, edge.key, outside.key], previewsEnabled: true)
        let plan = NotificationPlanner.foreground(batch, accountID: account, openChatID: nil, now: now)
        #expect(Set(plan.requests.map(\.identifier)) == Set([inside, edge].map { NotificationPlanner.identifier(for: $0) }))
        #expect(Set(plan.claimed) == Set([inside.key, edge.key, outside.key]), "the old one is dismissed, not left behind")
    }

    @Test func theOpenChatAndOldHistoryNeverBannerButEverythingIsClaimed() {
        let now = Date(timeIntervalSince1970: 10_000)
        let open = candidate("bob@example.org", at: 9_990)
        let old = candidate("carol@example.org", at: 9_000)
        let fresh = candidate("carol@example.org", at: 9_995)
        let batch = MessageNotification(candidates: [old, open, fresh], claimed: [old.key, open.key, fresh.key], previewsEnabled: true)
        let plan = NotificationPlanner.foreground(batch, accountID: account, openChatID: "bob@example.org", now: now)
        #expect(plan.requests.map(\.identifier) == [NotificationPlanner.identifier(for: fresh)])
        #expect(plan.requests.map(\.playsSound) == [true])
        #expect(Set(plan.claimed) == Set([old.key, open.key, fresh.key]))
        #expect(!plan.summarizesDeferredChats)
        // On the chat list nothing is open: every chat with news banners.
        #expect(NotificationPlanner.foreground(batch, accountID: account, openChatID: nil, now: now).requests.count == 2)
    }

    @Test func bannersAreTheExtensionsRequestsForOtherChatsOnly() async throws {
        try await withStore { store in
            let now = Date()
            try await store.upsertChat(accountID: account, chatID: "dave@example.org", title: "Dave")
            try await store.setChatNotificationSetting(accountID: account, chatID: "dave@example.org",
                                                       ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
            try await receive(store, chat: "bob@example.org", body: "In the open chat", at: now.addingTimeInterval(-5))
            let carol = try await receive(store, chat: "carol@example.org", body: "Elsewhere", at: now.addingTimeInterval(-3))
            try await receive(store, chat: "dave@example.org", body: "Muted", at: now.addingTimeInterval(-1))
            // What the extension would have posted for Carol, computed before the claim.
            let expected = NotificationPlanner.plan(try await store.pendingNotifications(accountID: account), accountID: account)
                .requests.filter { $0.destination?.messageID == carol.id }
            let posting = FakePosting()
            let posted = try await NotificationPresenter(posting: posting)
                .presentForeground(store: store, accountID: account, openChatID: "bob@example.org", presents: true, now: now)
            let added = await posting.added
            #expect(posted == 1)
            #expect(added.map(\.identifier) == expected.map(\.identifier))
            #expect(added.map(\.threadIdentifier) == [NotificationIdentity.thread(accountID: account, chatID: "carol@example.org")])
            #expect(added.map(\.body) == ["Elsewhere"] && added.map(\.categoryIdentifier) == [NotificationIdentity.messageCategory])
            #expect(added.map(\.playsSound) == [true])
            // Claimed: a later extension run cannot alert for any of them again.
            #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        }
    }

    /// Plan D8 in front of the app: another person's reaction to our message banners like the extension would post it,
    /// but not in the open chat and not when it is old; either way it is claimed.
    @Test func reactionsInOtherChatsBannerAsTheExtensionWould() async throws {
        try await withStore { store in
            let now = Date()
            func mine(_ chat: String) async throws -> StoredMessage {
                let message = StoredMessage(id: UUID().uuidString, accountID: account, chatID: chat, senderID: account, body: "Lunch?",
                                            sentAt: now.addingTimeInterval(-60), isOutgoing: true, encryptionProfile: "modern",
                                            wireID: "wire-" + chat, wireIDAuthenticated: true)
                try await store.upsertChat(accountID: account, chatID: chat, title: chat)
                try await store.insertMessage(message)
                return message
            }
            func react(_ chat: String, at date: Date) async throws {
                let revision = try #require(try await store.encryptionStateRevision(accountID: account))
                try await store.commitEncryptedIncoming(accountID: account, sender: chat, digest: "r-" + chat, expectedRevision: revision,
                    state: Data([UInt8(revision % 250 + 1)]), message: nil,
                    reaction: AuthenticatedReaction(id: "r-" + chat, chatID: chat, actorID: chat, targetWireID: "wire-" + chat,
                                                    reactions: ["👍"], updatedAt: date))
            }
            let carol = try await mine("carol@example.org")
            _ = try await mine("bob@example.org")
            _ = try await mine("erin@example.org")
            try await react("carol@example.org", at: now.addingTimeInterval(-2))
            try await react("bob@example.org", at: now.addingTimeInterval(-1))
            try await react("erin@example.org", at: now.addingTimeInterval(-3_600))
            let posting = FakePosting()
            let posted = try await NotificationPresenter(posting: posting)
                .presentForeground(store: store, accountID: account, openChatID: "bob@example.org", presents: true, now: now)
            let added = await posting.added
            #expect(posted == 1)
            #expect(added.map(\.identifier) == [NotificationIdentity.reaction(accountID: account, chatID: "carol@example.org",
                                                                                actorID: "carol@example.org", targetMessageID: carol.id)])
            #expect(added.map(\.categoryIdentifier) == [NotificationIdentity.reactionCategory])
            #expect(added.map(\.body) == ["Reacted 👍 to “Lunch?”"])
            #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        }
    }

    @Test func previewsOffBannersWithoutTitleOrText() async throws {
        try await withStore { store in
            try await store.setNotificationPreviews(accountID: account, enabled: false)
            try await receive(store, chat: "carol@example.org", body: "Secret", at: Date())
            let posting = FakePosting()
            try await NotificationPresenter(posting: posting).presentForeground(store: store, accountID: account, openChatID: nil, presents: true)
            let added = await posting.added
            #expect(added.map(\.title) == [""] && added.map(\.body) == [NotificationPlanner.hiddenBody])
        }
    }

    @Test func readMessagesAndCatchUpDismissWithoutBanners() async throws {
        try await withStore { store in
            let read = try await receive(store, chat: "carol@example.org", at: Date())
            try await store.markRead(accountID: account, chatID: "carol@example.org", throughMessageID: read.id)
            try await receive(store, chat: "erin@example.org", at: Date())
            let posting = FakePosting()
            // Catching up (or no permission): dismissed, as the foreground always did.
            #expect(try await NotificationPresenter(posting: posting).presentForeground(store: store, accountID: account, openChatID: nil, presents: false) == 0)
            #expect(await posting.added.isEmpty)
            #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        }
    }

    @Test func onlyRequestsNamingAMessageAreInTheActionableCategory() {
        let placeholderID = "unreadable-" + String(repeating: "0f", count: 32)
        let placeholder = candidate("bob@example.org", at: 1).withContent(.unreadable(messageID: placeholderID))
        let message = candidate("bob@example.org", at: 2)
        let plan = NotificationPlanner.plan(MessageNotification(candidates: [placeholder, message], claimed: [], deferredCount: 1,
                                                                deferredChatCount: 1, previewsEnabled: true), accountID: account)
        #expect(plan.requests.map(\.categoryIdentifier) == [NotificationIdentity.noticeCategory, NotificationIdentity.noticeCategory,
                                                            NotificationIdentity.messageCategory])
        #expect(NotificationIdentity.isMessageRun(category: NotificationIdentity.noticeCategory))
        #expect(!NotificationIdentity.isMessageRun(category: NotificationIdentity.fallbackCategory))
        let failure = NotificationIdentity.replyFailure(accountID: account, chatID: "bob@example.org")
        #expect(failure.hasPrefix("e-") && !failure.contains("bob") && failure != NotificationIdentity.replyFailure(accountID: account, chatID: "carol@example.org"))
    }
}
