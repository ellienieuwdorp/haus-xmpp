import Foundation
import Testing
@testable import MessageStore

private let account = "me@example.org"
private let room = "room@rooms.example.org"
private let members = [account, "alice@example.org", "bob@example.org", "carol@example.org", "dave@example.org", "erin@example.org", "frank@example.org"]

/// Commits one authenticated incoming message and returns whether it became a notification candidate.
private func deliver(_ store: MessageStore, _ id: String, chat: String = "peer@example.org", sender: String = "peer@example.org",
                     body: String = "Hello", group: Bool = false) async throws -> Bool {
    let revision = try await store.encryptionStateRevision(accountID: account)!
    let message = StoredMessage(id: id, accountID: account, chatID: chat, senderID: sender, body: body, encryptionProfile: "modern")
    try await store.commitEncryptedIncoming(accountID: account, sender: sender, digest: id, expectedRevision: revision,
        state: Data([UInt8(revision % 250)]), message: message, groupRoom: group ? chat : nil, groupMembers: group ? members : [])
    return try await store.pendingNotificationMessageIDs(accountID: account).contains(id)
}

@Test func mutingSuppressesCandidatesAndDeletesPendingOnesForThatChatOnly() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await store.upsertChat(accountID: account, chatID: "peer@example.org", title: "Peer")
        try await store.upsertChat(accountID: account, chatID: "other@example.org", title: "Other")
        #expect(try await deliver(store, "before"))
        #expect(try await deliver(store, "elsewhere", chat: "other@example.org", sender: "other@example.org"))
        let muted = ChatNotificationSetting(mutedUntil: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded()))
        try await store.setChatNotificationSetting(accountID: account, chatID: "peer@example.org", muted)
        #expect(try await store.pendingNotificationMessageIDs(accountID: account) == ["elsewhere"])
        #expect(try await !deliver(store, "during"))
        #expect(try await store.message(accountID: account, messageID: "during") != nil, "muting never drops the message")
        #expect(try await store.chatNotificationSetting(accountID: account, chatID: "peer@example.org") == muted)
        #expect(try await store.chats(accountID: account).first { $0.id == "peer@example.org" }?.notification.isMuted() == true)
        try await store.setChatNotificationSetting(accountID: account, chatID: "peer@example.org", ChatNotificationSetting())
        #expect(try await deliver(store, "after"))
    }
}

@Test func alwaysMuteSurvivesReopenAndExpiredMuteReadsAsUnmuted() async throws {
    try await withEncryptedStore(account: account) { store, url in
        try await store.upsertChat(accountID: account, chatID: "peer@example.org", title: "Peer")
        try await store.upsertChat(accountID: account, chatID: "expired@example.org", title: "Expired")
        try await store.setChatNotificationSetting(accountID: account, chatID: "peer@example.org", ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
        try await store.setChatNotificationSetting(accountID: account, chatID: "expired@example.org", ChatNotificationSetting(mutedUntil: Date().addingTimeInterval(-1)))
        let reopened = try MessageStore(url: url)
        let always = try await reopened.chatNotificationSetting(accountID: account, chatID: "peer@example.org")
        #expect(always.isMutedAlways && always.isMuted(at: Date().addingTimeInterval(86_400 * 365 * 100)))
        let expired = try await reopened.chatNotificationSetting(accountID: account, chatID: "expired@example.org")
        #expect(!expired.isMuted())
        try await reopened.close()
        #expect(try await !deliver(store, "silent"))
        #expect(try await deliver(store, "loud", chat: "expired@example.org", sender: "expired@example.org"))
    }
}

@Test func settingsAreValidatedAndScopedToAnExistingChat() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.setChatNotificationSetting(accountID: account, chatID: "missing@example.org", ChatNotificationSetting(mutedUntil: .distantFuture))
        }
        try await store.upsertChat(accountID: account, chatID: "peer@example.org", title: "Peer")
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.setChatNotificationSetting(accountID: account, chatID: "peer@example.org", ChatNotificationSetting(mutedUntil: Date(timeIntervalSince1970: .infinity)))
        }
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.setGroupNickname(accountID: account, room: "missing@rooms.example.org", nickname: "me")
        }
        // Another account's identical chat ID is untouched.
        try await store.upsertChat(accountID: "other@example.org", chatID: "peer@example.org", title: "Peer")
        try await store.setChatNotificationSetting(accountID: account, chatID: "peer@example.org", ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
        #expect(try await store.chatNotificationSetting(accountID: "other@example.org", chatID: "peer@example.org") == ChatNotificationSetting())
    }
}

@Test func mentionsOnlyGroupQueuesOnlyMessagesThatMentionTheUser() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await store.upsertChat(accountID: account, chatID: room, title: "Room")
        try await store.setGroupNickname(accountID: account, room: room, nickname: "Ellie N")
        try await store.setChatNotificationSetting(accountID: account, chatID: room, ChatNotificationSetting(level: .mentions))
        let alice = "alice@example.org"
        #expect(try await !deliver(store, "plain", chat: room, sender: alice, body: "Lunch at noon?", group: true))
        #expect(try await deliver(store, "nick", chat: room, sender: alice, body: "ellie n, lunch?", group: true))
        // Five members named (the user included) still counts; six is a mass mention.
        #expect(try await deliver(store, "five", chat: room, sender: alice, body: "me alice bob carol dave: standup", group: true))
        #expect(try await !deliver(store, "six", chat: room, sender: alice, body: "me alice bob carol dave erin: standup", group: true))
        // Muting overrides the level; unmuting returns to mentions only.
        try await store.setChatNotificationSetting(accountID: account, chatID: room, ChatNotificationSetting(level: .mentions, mutedUntil: ChatNotificationSetting.always))
        #expect(try await !deliver(store, "muted", chat: room, sender: alice, body: "me?", group: true))
        try await store.setChatNotificationSetting(accountID: account, chatID: room, ChatNotificationSetting(level: .mentions))
        #expect(try await !deliver(store, "quiet", chat: room, sender: alice, body: "anyone?", group: true))
        try await store.setChatNotificationSetting(accountID: account, chatID: room, ChatNotificationSetting(level: .all))
        #expect(try await deliver(store, "all", chat: room, sender: alice, body: "anyone?", group: true))
    }
}

@Test func groupMembersRequireAGroupCommit() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        let message = StoredMessage(id: "x", accountID: account, chatID: "peer@example.org", senderID: "peer@example.org", body: "Hi", encryptionProfile: "modern")
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.commitEncryptedIncoming(accountID: account, sender: "peer@example.org", digest: "x", expectedRevision: 1,
                state: Data([1]), message: message, groupMembers: members)
        }
    }
}

@Test func migrationV17AddsNotificationColumnsIdempotently() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "mute-migration-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: account, chatID: room, title: "Room")
    try await store.close()
    #expect(sqliteExecute(url: url, sql: """
        ALTER TABLE chats DROP COLUMN notification_level;
        ALTER TABLE chats DROP COLUMN muted_until;
        ALTER TABLE chats DROP COLUMN room_nickname;
        PRAGMA user_version=17;
        """))
    let migrated = try MessageStore(url: url)
    #expect(try await migrated.chatNotificationSetting(accountID: account, chatID: room) == ChatNotificationSetting())
    try await migrated.setGroupNickname(accountID: account, room: room, nickname: "Ellie")
    try await migrated.close()
    try await MessageStore(url: url).close()
}

@Test func mentionDetectionIsCaseInsensitiveOnWordBoundaries() {
    let members = ["me@example.org", "alice@example.org", "bob@example.org", "carol@example.org", "dave@example.org", "erin@example.org"]
    func check(_ text: String, nickname: String? = "Elle") -> Bool { Mention.mentions(text, account: "me@example.org", nickname: nickname, members: members) }
    #expect(check("elle?"))
    #expect(check("Hi @ELLE!"))
    #expect(check("elle's turn"))
    #expect(!check("Ellen is here"))
    #expect(!check("gazelle"))
    #expect(!check("elle_x"))
    #expect(check("ME@EXAMPLE.ORG"))
    #expect(!check("mermaid time"))
    #expect(!check("home"))
    #expect(check("me: see this"))
    #expect(!check("anything", nickname: nil))
    // A one-character name never matches ordinary words.
    #expect(!Mention.mentions("a b c", account: "a@example.org", nickname: "a", members: []))
    // The user plus four others is five: still a mention. The user plus five others is not.
    #expect(check("elle alice bob carol dave"))
    #expect(!check("elle alice bob carol dave erin"))
    // Repeating one member's names counts that member once.
    #expect(check("elle alice alice@example.org bob carol dave"))
    // Unknown words are not members.
    #expect(check("elle zed yan xavier walt vic uma"))
}

@Test func namesSharedWithTheUserDoNotInflateTheMassMentionTally() {
    // Other members on other domains share the user's localpart or nickname: naming the user must not name them.
    let members = ["me@example.org", "me@other.example", "elle@third.example", "alice@example.org", "bob@example.org",
                   "carol@example.org", "dave@example.org"]
    func tally(_ text: String) -> Int {
        Mention.namedOthers(in: text, account: "me@example.org", ownNames: ["me", "me@example.org", "Elle"], members: members)
    }
    #expect(tally("me: see this") == 0)
    #expect(tally("Elle, look") == 0)
    #expect(tally("elle alice bob carol dave") == 4)
    #expect(Mention.mentions("elle alice bob carol dave", account: "me@example.org", nickname: "Elle", members: members))
    // Their full addresses still name them.
    #expect(tally("me@other.example elle@third.example") == 2)
    #expect(!Mention.mentions("me alice bob carol dave me@other.example", account: "me@example.org", nickname: "Elle", members: members))

    // Other members sharing one localpart count once, and not again when one of them is named by address.
    let shared = ["me@example.org", "bob@a.example", "bob@b.example", "carol@example.org"]
    func sharedTally(_ text: String) -> Int {
        Mention.namedOthers(in: text, account: "me@example.org", ownNames: ["me", "me@example.org"], members: shared)
    }
    #expect(sharedTally("bob and carol") == 2)
    #expect(sharedTally("bob@a.example and carol") == 2)
    #expect(sharedTally("bob@a.example bob@b.example carol") == 3)
}
