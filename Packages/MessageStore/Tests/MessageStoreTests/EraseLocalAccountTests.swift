import Foundation
import Testing
@testable import MessageStore

/// Erasing a local-only account leaves no row of it in any table and every row of other accounts, and an account
/// with encryption state is refused with nothing removed.
@Test func erasingALocalAccountRemovesOnlyItsRowsAndRefusesAnAccountWithKeys() async throws {
    try await withEncryptedStore(account: "me@example.org", chats: [("bob@example.org", "Bob")]) { store, url in
        let sample = "preview.local"
        for account in [sample, "me@example.org"] {
            let chat = account == sample ? "alex@preview.local" : "bob@example.org"
            try await store.upsertChat(accountID: account, chatID: chat, title: "Peer")
            try await store.insertMessage(StoredMessage(id: "photo", accountID: account, chatID: chat, senderID: chat, body: "", wireID: "w1",
                                                        attachment: StoredAttachment(name: "a.jpg", mediaType: "image/jpeg", size: 1, hash: "00", secret: Data([0]))))
            try await store.insertMessage(StoredMessage(id: "sent", accountID: account, chatID: chat, senderID: account, body: "Hi https://example.org",
                                                        isOutgoing: true, isStarred: true, wireID: "w2",
                                                        linkPreview: StoredLinkPreview(url: "https://example.org", title: "Example", source: .own)))
            try await store.recordReaction(accountID: account, reaction: AuthenticatedReaction(id: "r", chatID: chat, actorID: account, targetWireID: "w1",
                                                                                               reactions: ["❤️"], updatedAt: Date()))
            try await store.recordReceipt(accountID: account, event: MessageEvent(id: "d", chatID: chat, actorID: chat, targetWireID: "w2", kind: .displayed,
                                                                                  payload: "{}", updatedAt: Date()))
            try await store.setChatNotificationSetting(accountID: account, chatID: chat, ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
            try await store.markChatRead(accountID: account, chatID: chat)
        }
        let tables = sqliteRows(url: url, sql: "SELECT m.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type='table' AND p.name='account_id'").map { $0[0] }
        func rows(_ account: String) -> [String: String] {
            Dictionary(uniqueKeysWithValues: tables.map { ($0, sqliteRows(url: url, sql: "SELECT COUNT(*) FROM \"\($0)\" WHERE account_id='\(account)'")[0][0]) })
        }
        let kept = rows("me@example.org")
        #expect(rows(sample).values.contains { $0 != "0" }, "the fixture wrote rows for the sample account")
        #expect(try await store.storedAccountIDs() == [sample, "me@example.org"])

        try await store.eraseLocalAccount(accountID: sample)
        #expect(try await store.storedAccountIDs() == ["me@example.org"])
        #expect(rows(sample).values.allSatisfy { $0 == "0" }, "\(rows(sample))")
        #expect(rows("me@example.org") == kept)
        #expect(try await store.chats(accountID: sample).isEmpty)

        await #expect(throws: MessageStoreError.invalidTransition) { try await store.eraseLocalAccount(accountID: "me@example.org") }
        #expect(rows("me@example.org") == kept)
    }
}
