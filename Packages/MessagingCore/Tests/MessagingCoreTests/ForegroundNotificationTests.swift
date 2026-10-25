import Foundation
import MessageStore
import Testing
@testable import MessagingCore

private let account = "alice@example.org"

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
        let plan = NotificationPlanner.foreground(batch, accountID: account, readingChatID: nil, now: now)
        #expect(Set(plan.requests.map(\.identifier)) == Set([inside, edge].map { NotificationPlanner.identifier(for: $0) }))
        #expect(Set(plan.claimed) == Set([inside.key, edge.key, outside.key]), "the old one is dismissed, not left behind")
    }

    @Test func bannersAreTheExtensionsRequestsForOtherChatsOnly() async throws {
        try await withStore { store in
            let now = Date()
            try await store.upsertChat(accountID: account, chatID: "dave@example.org", title: "Dave")
            try await store.setChatNotificationSetting(accountID: account, chatID: "dave@example.org",
                                                       ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
            try await receive(store, chat: "bob@example.org", body: "In the open chat", at: now.addingTimeInterval(-5).timeIntervalSince1970)
            let carol = try await receive(store, chat: "carol@example.org", body: "Elsewhere", at: now.addingTimeInterval(-3).timeIntervalSince1970)
            try await receive(store, chat: "dave@example.org", body: "Muted", at: now.addingTimeInterval(-1).timeIntervalSince1970)
            // What the extension would have posted for Carol, computed before the claim.
            let expected = NotificationPlanner.plan(try await store.pendingNotifications(accountID: account), accountID: account)
                .requests.filter { $0.destination?.messageID == carol.id }
            let posting = FakePosting()
            let posted = try await NotificationPresenter(posting: posting)
                .presentForeground(store: store, accountID: account, readingChatID: "bob@example.org", presents: true, now: now)
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

    /// A banner batch planned before the user unlinked: a request posted after the unlink names no contact, and the
    /// one whose donation was in flight has its conversation's donations withdrawn after it.
    @Test func anUnlinkDuringABatchNeverLeavesTheOldContactDonated() async throws {
        try await withStore { store in
            let now = Date()
            for chat in ["bob@example.org", "carol@example.org"] {
                try await linkContact(store, chat: chat, identifier: "contact-" + chat)
                try await receive(store, chat: chat, at: now.addingTimeInterval(-5).timeIntervalSince1970)
            }
            let posting = FakePosting(), withdrawn = WithdrawnDonations()
            // The user unlinks both chats while the first banner is being posted.
            await posting.duringAdd { _ in
                for chat in ["bob@example.org", "carol@example.org"] { _ = try? await store.removeContactLink(accountID: account, jid: chat) }
            }
            var presenter = NotificationPresenter(posting: posting)
            presenter.withdrawDonations = { await withdrawn.add($0) }
            #expect(try await presenter.presentForeground(store: store, accountID: account, readingChatID: nil, presents: true, now: now) == 2)
            let added = await posting.added
            #expect(added.count == 2)
            #expect(added[0].communication?.sender.contactIdentifier != nil, "linked when it was posted")
            #expect(added[1].communication?.sender.contactIdentifier == nil, "posted after the unlink")
            #expect(await withdrawn.conversations == [added[0].threadIdentifier])
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
                .presentForeground(store: store, accountID: account, readingChatID: "bob@example.org", presents: true, now: now)
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
            try await receive(store, chat: "carol@example.org", body: "Secret", at: Date().timeIntervalSince1970)
            let posting = FakePosting()
            try await NotificationPresenter(posting: posting).presentForeground(store: store, accountID: account, readingChatID: nil, presents: true)
            let added = await posting.added
            #expect(added.map(\.title) == [""] && added.map(\.body) == [NotificationPlanner.hiddenBody])
        }
    }

    @Test func readMessagesAndCatchUpDismissWithoutBanners() async throws {
        try await withStore { store in
            let read = try await receive(store, chat: "carol@example.org", at: Date().timeIntervalSince1970)
            try await store.markRead(accountID: account, chatID: "carol@example.org", throughMessageID: read.id)
            try await receive(store, chat: "erin@example.org", at: Date().timeIntervalSince1970)
            let posting = FakePosting()
            // Catching up (or no permission): dismissed, as the foreground always did.
            #expect(try await NotificationPresenter(posting: posting).presentForeground(store: store, accountID: account, readingChatID: nil, presents: false) == 0)
            #expect(await posting.added.isEmpty)
            #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        }
    }
}

private func reaction(_ chat: String, sequence: Int, at: TimeInterval) -> ReactionNotificationCandidate {
    let target = StoredMessage(id: UUID().uuidString, accountID: account, chatID: chat, senderID: account, body: "Lunch?",
                               sentAt: Date(timeIntervalSince1970: at - 60), isOutgoing: true, encryptionProfile: "modern")
    return ReactionNotificationCandidate(key: .reaction(sequence: sequence), accountID: account, chatID: chat, chatTitle: nil,
                                         actor: NotificationParticipant(id: chat, title: nil, avatarHash: nil), isGroup: false, target: target,
                                         reactions: ["👍"], reactedAt: Date(timeIntervalSince1970: at))
}

/// What a desktop app caught up on after waking or launching: one banner per chat, held until the catch-up is in.
struct CaughtUpNotificationTests {
    @Test func oneBannerPerChatWhateverItsAgeButNotForTheChatBeingRead() async throws {
        try await withStore { store in
            let now = Date().timeIntervalSince1970
            try await receive(store, chat: "erin@example.org", body: "Two days ago", at: now - 2 * 86_400)
            try await receive(store, chat: "carol@example.org", body: "First", at: now - 3_600)
            try await receive(store, chat: "carol@example.org", body: "Second", at: now - 3_500)
            let carol = try await receive(store, chat: "carol@example.org", body: "Third", at: now - 3_400)
            try await receive(store, chat: "bob@example.org", body: "Being read", at: now - 60)
            let posting = FakePosting()
            let posted = try await NotificationPresenter(posting: posting)
                .presentCaughtUp(store: store, accountID: account, readingChatID: "bob@example.org", presents: true)
            let added = await posting.added
            #expect(posted == 2)
            #expect(added.map(\.threadIdentifier) == ["erin@example.org", "carol@example.org"].map { NotificationIdentity.thread(accountID: account, chatID: $0) })
            #expect(added.map(\.body) == ["Two days ago", "Third\nand 2 more"])
            #expect(added.last?.destination == NotificationDestination(accountID: account, messageID: carol.id), "a tap opens the newest message's chat")
            #expect(added.map(\.playsSound) == [false, true], "one sound for the whole catch-up")
            // Everything is claimed, the chat being read included: a later catch-up cannot alert for any of it again.
            #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        }
    }

    @Test func withoutPermissionEverythingHeldIsDismissed() async throws {
        try await withStore { store in
            try await receive(store, chat: "carol@example.org", at: Date().timeIntervalSince1970 - 3_600)
            let posting = FakePosting()
            #expect(try await NotificationPresenter(posting: posting)
                .presentCaughtUp(store: store, accountID: account, readingChatID: nil, presents: false) == 0)
            #expect(await posting.added.isEmpty)
            #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        }
    }

    /// The caught-up batch is rebuilt for the planner: the device's preview setting must come through.
    @Test func previewsOffHideTitleAndText() {
        let hidden = NotificationPlanner.caughtUp(
            MessageNotification(candidates: [candidate("carol@example.org", at: 1)], claimed: [], previewsEnabled: false),
            accountID: account, readingChatID: nil)
        #expect(hidden.requests.map(\.title) == [""] && hidden.requests.map(\.body) == [NotificationPlanner.hiddenBody])
        #expect(hidden.requests.allSatisfy { $0.communication == nil })
    }

    @Test func reactionsAlertOnlyInChatsWithoutAMessageBannerAndOnlyTheNewest() {
        let message = candidate("carol@example.org", at: 10)
        let reactions = [reaction("carol@example.org", sequence: 1, at: 11), reaction("erin@example.org", sequence: 2, at: 12),
                         reaction("erin@example.org", sequence: 3, at: 13), reaction("bob@example.org", sequence: 4, at: 14)]
        let batch = MessageNotification(candidates: [message], claimed: [message.key] + reactions.map(\.key), previewsEnabled: true, reactions: reactions)
        let plan = NotificationPlanner.caughtUp(batch, accountID: account, readingChatID: "bob@example.org")
        #expect(plan.requests.map(\.categoryIdentifier) == [NotificationIdentity.messageCategory, NotificationIdentity.reactionCategory])
        #expect(plan.requests.last?.identifier == NotificationIdentity.reaction(accountID: account, chatID: "erin@example.org",
                                                                                actorID: "erin@example.org", targetMessageID: reactions[2].target.id))
        #expect(plan.claimed == batch.claimed, "the reactions without a banner are claimed with the rest")
    }

    @Test func chatsPastTheCapGetTheDeferredChatsSummary() {
        let shown = candidate("carol@example.org", at: 10)
        let batch = MessageNotification(candidates: [shown], claimed: [shown.key], deferredCount: 5, deferredChatCount: 3, previewsEnabled: true)
        let plan = NotificationPlanner.caughtUp(batch, accountID: account, readingChatID: nil)
        #expect(plan.requests.map(\.body) == [NotificationPlanner.overflowBody(chats: 3), "Hi"])
        #expect(plan.summarizesDeferredChats)
    }
}
