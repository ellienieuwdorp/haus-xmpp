import Foundation
import MessageStore
import Testing
import XMPPProtocol
@testable import MessagingCore

private let account = "alice@example.org"

/// A blocked address never alerts or badges, whichever process presents, and its candidates are still claimed.
struct BlockedSenderNotificationTests {
    @Test func aRunPostsNothingFromABlockedAddressAndClaimsIt() async throws {
        try await withStore { store in
            let bob = try await receive(store, chat: "bob@example.org", body: "Hello", at: 1)
            try await receive(store, chat: "spam@example.org", body: "Buy now", at: 2)
            try await receive(store, chat: "bot@spam.example", body: "Buy more", at: 3)
            let posting = FakePosting()
            let progress = NotificationRunProgress()
            try await NotificationPresenter(posting: posting).present(store: store, accountID: account, progress: progress,
                                                                      blocklist: XMPPBlocklist(["spam@example.org", "spam.example"]))
            let added = await posting.added
            #expect(added.map(\.identifier) == [NotificationIdentity.message(accountID: account, messageID: bob.id)])
            #expect(added.compactMap(\.badge) == [1])
            #expect(progress.isCommitted && progress.report.claimed == 3)
            #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        }
    }

    @Test func foregroundBannersSkipABlockedAddress() async throws {
        try await withStore { store in
            let now = Date()
            try await receive(store, chat: "spam@example.org", body: "Buy now", at: now.addingTimeInterval(-2).timeIntervalSince1970)
            let carol = try await receive(store, chat: "carol@example.org", body: "Hi", at: now.addingTimeInterval(-1).timeIntervalSince1970)
            let posting = FakePosting()
            let posted = try await NotificationPresenter(posting: posting)
                .presentForeground(store: store, accountID: account, readingChatID: nil, presents: true,
                                   blocklist: XMPPBlocklist(["spam@example.org"]), now: now)
            #expect(posted == 1)
            #expect(await posting.added.map(\.destination?.messageID) == [carol.id])
            #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        }
    }

    /// In a room the chat is not the sender: a blocked member's message is left out, the room's others are not.
    @Test func aBlockedRoomMemberIsLeftOutButTheRoomIsNot() {
        func candidate(chat: String, sender: String, group: Bool) -> NotificationCandidate {
            let message = StoredMessage(id: UUID().uuidString, accountID: account, chatID: chat, senderID: sender, body: "Hi",
                                        sentAt: Date(timeIntervalSince1970: 1), encryptionProfile: "modern")
            return NotificationCandidate(key: .message(message.id), accountID: account, chatID: chat, chatTitle: nil, senderID: sender,
                                         isGroup: group, sentAt: message.sentAt, content: .message(message))
        }
        let member = candidate(chat: "team@rooms.example.org", sender: "mallory@example.org", group: true)
        let other = candidate(chat: "team@rooms.example.org", sender: "carol@example.org", group: true)
        let batch = MessageNotification(candidates: [member, other], claimed: [member.key, other.key], previewsEnabled: true)
        let filtered = batch.excludingBlocked(XMPPBlocklist(["mallory@example.org"]))
        #expect(filtered.candidates == [other])
        #expect(filtered.claimed == batch.claimed)
        #expect(batch.excludingBlocked(XMPPBlocklist(["rooms.example.org/x"])).candidates.count == 2)
    }

    @Test func theBadgeLeavesOutBlockedChats() {
        #expect(NotificationBadge.count(unread: ["bob@example.org": 2, "spam@example.org": 5], settings: [:],
                                        blocklist: XMPPBlocklist(["spam@example.org"])) == 2)
    }
}
