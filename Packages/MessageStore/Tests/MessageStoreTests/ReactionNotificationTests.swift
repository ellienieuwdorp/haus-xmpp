import Foundation
import Testing
import CSQLite
@testable import MessageStore

// Plan D8: another person's authenticated reaction to one of this account's messages alerts once per actor and target.

private let account = "me@example.org"
private let peer = "peer@example.org"
private let room = "room@rooms.example.org"

private func reactionStore(_ operation: (MessageStore, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "reaction-alerts-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let store = try MessageStore(url: url)
    do {
        try await store.acquireTransportOwnership()
        try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([0]))
        try await store.upsertChat(accountID: account, chatID: peer, title: "Peer")
        try await store.upsertChat(accountID: account, chatID: room, title: "Book club")
        try await operation(store, url)
        try await store.close()
    } catch { try? await store.close(); throw error }
}

/// A message in `chat` with an authenticated wire ID equal to its id.
private func insert(_ store: MessageStore, _ id: String, chat: String = peer, sender: String = account, body: String = "Lunch at noon?",
                    at second: Double = 0) async throws {
    try await store.insertMessage(StoredMessage(id: id, accountID: account, chatID: chat, senderID: sender, body: body,
                                                sentAt: Date(timeIntervalSince1970: 1_800_000_000 + second), isOutgoing: sender == account,
                                                encryptionProfile: "modern", wireID: id, wireIDAuthenticated: true))
}

/// One authenticated (SCE) reaction commit, as OMEMO makes it.
private func react(_ store: MessageStore, _ id: String, actor: String = peer, chat: String = peer, target: String, _ reactions: [String],
                   at second: Double = 100) async throws {
    let revision = try await store.encryptionStateRevision(accountID: account)!
    let reaction = AuthenticatedReaction(id: id, chatID: chat, actorID: actor, targetWireID: target, reactions: reactions,
                                         updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + second))
    try await store.commitEncryptedIncoming(accountID: account, sender: actor, digest: "digest-\(id)", expectedRevision: revision,
                                            state: Data([UInt8(revision % 250)]), message: nil, reaction: reaction,
                                            groupRoom: chat == room ? room : nil)
}

private func waiting(_ store: MessageStore) async throws -> [String] {
    try await store.pendingReactionCandidates(accountID: account).map { "\($0.actor)>\($0.target):\($0.reactions.joined())" }
}

@Test func peersAuthenticatedReactionToMyMessageQueuesExactlyOneCandidate() async throws {
    try await reactionStore { store, _ in
        try await insert(store, "mine")
        try await react(store, "r1", target: "mine", ["👍"])
        #expect(try await waiting(store) == ["peer@example.org>mine:👍"])
        let batch = try await store.pendingNotifications(accountID: account)
        #expect(batch.candidates.isEmpty)
        let candidate = try #require(batch.reactions.first)
        #expect(batch.reactions.count == 1)
        #expect(candidate.reactions == ["👍"] && candidate.target.body == "Lunch at noon?" && candidate.target.id == "mine")
        #expect(candidate.actor == NotificationParticipant(id: peer, title: "Peer", avatarHash: nil))
        #expect(!candidate.isGroup && candidate.chatTitle == "Peer" && candidate.groupMembers.isEmpty)
        #expect(!String(describing: candidate).contains("Lunch"))
        try await store.removeNotificationCandidates(accountID: account, keys: batch.claimed)
        #expect(try await waiting(store).isEmpty)
        #expect(try await store.pendingNotifications(accountID: account).reactions.isEmpty)
    }
}

@Test func ownReactionsReactionsToOthersMessagesAndPlaintextReactionsNeverQueue() async throws {
    try await reactionStore { store, _ in
        try await insert(store, "mine")
        try await insert(store, "theirs", sender: peer, at: 1)
        // Our other device reacting to our own message, and the peer reacting to their own message.
        try await react(store, "own", actor: account, target: "mine", ["🎉"])
        try await react(store, "self-target", target: "theirs", ["👍"])
        // A legacy plaintext reaction: server-authenticated actor only.
        try await store.recordReaction(accountID: account, reaction: AuthenticatedReaction(id: "plain", chatID: peer, actorID: peer, targetWireID: "mine",
                                                                                           reactions: ["😂"], updatedAt: Date(timeIntervalSince1970: 1_800_000_200)))
        #expect(try await waiting(store).isEmpty)
        #expect(try await store.reactions(accountID: account, chatID: peer, messageID: "mine").count == 2, "stored, just not alerting")
    }
}

@Test func replacementMergesRemovalDeletesAndOlderEventsAreIgnored() async throws {
    try await reactionStore { store, _ in
        try await insert(store, "mine")
        try await react(store, "r1", target: "mine", ["👍"], at: 100)
        try await react(store, "r2", target: "mine", ["❤️", "👍"], at: 110)
        #expect(try await waiting(store) == ["peer@example.org>mine:❤️👍"])
        // An archive copy of an older event arrives late: the projection keeps the newer set, and nothing new alerts.
        try await react(store, "r0", target: "mine", ["😮"], at: 50)
        #expect(try await waiting(store) == ["peer@example.org>mine:❤️👍"])
        // Dropping 👍 trims what waits; nothing new was added, so it does not re-alert on its own.
        try await react(store, "r3", target: "mine", ["❤️"], at: 120)
        #expect(try await waiting(store) == ["peer@example.org>mine:❤️"])
        #expect(try await store.liveReactionNotifications(accountID: account, targetMessageIDs: ["mine"])
                == [LiveReactionNotification(chatID: peer, actorID: peer, targetMessageID: "mine")])
        // Withdrawing the reaction deletes the candidate, and delivered ones are no longer live.
        try await react(store, "r4", target: "mine", [], at: 130)
        #expect(try await waiting(store).isEmpty)
        #expect(try await store.liveReactionNotifications(accountID: account, targetMessageIDs: ["mine", "missing"]).isEmpty)
    }
}

@Test func aClaimDeletesOnlyTheVersionItPosted() async throws {
    try await reactionStore { store, _ in
        try await insert(store, "mine")
        try await react(store, "r1", target: "mine", ["👍"], at: 100)
        let batch = try await store.pendingNotifications(accountID: account)
        // A replacement arrives between posting and deleting: it is a new version and waits for the next run.
        try await react(store, "r2", target: "mine", ["🔥"], at: 110)
        try await store.removeNotificationCandidates(accountID: account, keys: batch.claimed)
        #expect(try await waiting(store) == ["peer@example.org>mine:🔥"])
    }
}

/// Posts whatever waits, as a settled extension run does, and returns which (actor, target) notifications are current.
private func postAndCheck(_ store: MessageStore, targets: Set<String> = ["mine"]) async throws -> Set<String> {
    let batch = try await store.pendingNotifications(accountID: account)
    try await store.removeNotificationCandidates(accountID: account, keys: batch.claimed)
    return try await live(store, targets: targets)
}

private func live(_ store: MessageStore, targets: Set<String> = ["mine"]) async throws -> Set<String> {
    Set(try await store.liveReactionNotifications(accountID: account, targetMessageIDs: targets).map { "\($0.actorID)>\($0.targetMessageID)" })
}

@Test func aDeliveredReactionStaysCurrentOnlyWhileEverythingItShowedRemainsAndTheChatIsUnseen() async throws {
    try await reactionStore { store, _ in
        try await insert(store, "mine")
        try await insert(store, "incoming", sender: peer, at: 1)
        try await react(store, "r1", target: "mine", ["❤️", "👍"], at: 100)
        #expect(try await postAndCheck(store) == ["peer@example.org>mine"])
        // Dropping an emoji the notification showed makes it stale, although another one is still there.
        try await react(store, "r2", target: "mine", ["❤️"], at: 110)
        #expect(try await waiting(store).isEmpty, "a removal never re-alerts")
        #expect(try await live(store).isEmpty)
        // A new emoji alerts again and becomes what the notification shows.
        try await react(store, "r3", target: "mine", ["❤️", "🔥"], at: 120)
        #expect(try await waiting(store) == ["peer@example.org>mine:🔥"])
        #expect(try await live(store) == ["peer@example.org>mine"], "a waiting replacement keeps it until the next run replaces it")
        #expect(try await postAndCheck(store) == ["peer@example.org>mine"])
        // Dropping an emoji it did not show changes nothing.
        try await react(store, "r4", target: "mine", ["🔥"], at: 130)
        #expect(try await live(store) == ["peer@example.org>mine"])
        // Read here or on another device after it was posted: seen.
        #expect(try await store.markRead(accountID: account, chatID: peer, throughMessageID: "incoming"))
        #expect(try await live(store).isEmpty)
    }
}

@Test func openingAChatEndsItsReactionNotificationsAndNeedsTheTransportLease() async throws {
    try await reactionStore { store, _ in
        try await insert(store, "mine")
        try await react(store, "r1", target: "mine", ["👍"], at: 100)
        #expect(try await postAndCheck(store) == ["peer@example.org>mine"])
        try await react(store, "r2", target: "mine", ["👍", "🎉"], at: 110)
        // Without the lease an extension run may already hold these candidates: the app must not race it.
        try await store.releaseTransportOwnership()
        await #expect(throws: MessageStoreError.transportOwnershipRequired) {
            try await store.dismissReactionNotifications(accountID: account, chatID: peer)
        }
        #expect(try await waiting(store).count == 1)
        try await store.acquireTransportOwnership()
        try await store.dismissReactionNotifications(accountID: account, chatID: peer)
        #expect(try await waiting(store).isEmpty)
        #expect(try await live(store).isEmpty)
    }
}

@Test func muteSwitchReadingOpeningAndHistoryStopReactionAlerts() async throws {
    try await reactionStore { store, _ in
        try await insert(store, "mine")
        try await insert(store, "incoming", sender: peer, at: 1)
        // Muted: nothing queues, and muting drops what waits.
        try await react(store, "r1", target: "mine", ["👍"], at: 100)
        try await store.setChatNotificationSetting(accountID: account, chatID: peer, ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
        #expect(try await waiting(store).isEmpty)
        try await react(store, "r2", target: "mine", ["👍", "🔥"], at: 110)
        #expect(try await waiting(store).isEmpty)
        try await store.setChatNotificationSetting(accountID: account, chatID: peer, ChatNotificationSetting())
        // Switch off: nothing queues and what waits goes; back on, new reactions alert again.
        try await react(store, "r3", target: "mine", ["🎉"], at: 120)
        #expect(try await waiting(store) == ["peer@example.org>mine:🎉"])
        #expect(try await store.accountPreferences(accountID: account).reactionNotifications)
        try await store.setAccountPreferences(accountID: account, AccountPreferences(reactionNotifications: false))
        #expect(try await waiting(store).isEmpty)
        try await react(store, "r4", target: "mine", ["😂"], at: 130)
        #expect(try await waiting(store).isEmpty)
        try await store.setAccountPreferences(accountID: account, AccountPreferences())
        // Read after the reaction: seen.
        try await react(store, "r5", target: "mine", ["🙏"], at: 140)
        #expect(try await waiting(store).count == 1)
        #expect(try await store.markRead(accountID: account, chatID: peer, throughMessageID: "incoming"))
        #expect(try await waiting(store).isEmpty)
        // Opened: seen, whatever the pointer did.
        try await react(store, "r6", target: "mine", ["👀"], at: 150)
        #expect(try await waiting(store).count == 1)
        try await store.dismissReactionNotifications(accountID: account, chatID: peer)
        #expect(try await waiting(store).isEmpty)
        // The foreground owner presents everything itself.
        try await react(store, "r7", target: "mine", ["💯"], at: 160)
        try await store.dismissPendingMessageNotifications(accountID: account)
        #expect(try await waiting(store).isEmpty)
    }
}

@Test func reactionsFromArchiveHistoryNeverAlert() async throws {
    try await reactionStore { store, _ in
        try await insert(store, "mine")
        // A first page's catch-up: reactions queued while it was processed go once the page records its baseline.
        try await react(store, "old", target: "mine", ["👍"], at: 100)
        #expect(try await waiting(store).count == 1)
        try await store.saveNewestArchivePage(accountID: account, archiveID: account, cursor: "c", oldestID: "o", complete: true,
                                              historyThrough: Date(timeIntervalSince1970: 1_800_000_200))
        #expect(try await waiting(store).isEmpty)
        // Backfill brings an older one: history. A later one is news.
        try await react(store, "older", target: "mine", ["👍", "🙂"], at: 150)
        #expect(try await waiting(store).isEmpty)
        try await react(store, "new", target: "mine", ["👍", "🙂", "🔥"], at: 300)
        #expect(try await waiting(store) == ["peer@example.org>mine:🔥"])
    }
}

@Test func groupReactionNamesTheActorTheRoomAndOtherMembers() async throws {
    try await reactionStore { store, _ in
        try await store.upsertChat(accountID: account, chatID: "bob@example.org", title: "Bob")
        try await store.setAvatarHash(accountID: account, chatID: "bob@example.org", hash: String(repeating: "b", count: 40))
        try await insert(store, "carol-1", chat: room, sender: "carol@example.org", at: 1)
        try await insert(store, "mine", chat: room, sender: account, at: 2)
        try await insert(store, "bob-1", chat: room, sender: "bob@example.org", at: 3)
        try await react(store, "g1", actor: "bob@example.org", chat: room, target: "mine", ["👍"])
        let candidate = try #require(await store.pendingNotifications(accountID: account).reactions.first)
        #expect(candidate.isGroup && candidate.chatTitle == "Book club")
        #expect(candidate.actor == NotificationParticipant(id: "bob@example.org", title: "Bob", avatarHash: String(repeating: "b", count: 40)))
        #expect(candidate.groupMembers.map(\.id) == ["carol@example.org"])
        // Bob reacting to Carol's message is not ours to hear about.
        try await react(store, "g2", actor: "bob@example.org", chat: room, target: "carol-1", ["😂"], at: 110)
        #expect(try await waiting(store) == ["bob@example.org>mine:👍"])
    }
}

@Test func groupMessageCandidatesCarrySenderAvatarAndMembers() async throws {
    try await reactionStore { store, _ in
        try await store.upsertChat(accountID: account, chatID: "bob@example.org", title: "Bob")
        try await store.setAvatarHash(accountID: account, chatID: "bob@example.org", hash: String(repeating: "b", count: 40))
        try await insert(store, "carol-1", chat: room, sender: "carol@example.org", at: 1)
        let revision = try await store.encryptionStateRevision(accountID: account)!
        let message = StoredMessage(id: "m1", accountID: account, chatID: room, senderID: "bob@example.org", body: "Hi",
                                    sentAt: Date(timeIntervalSince1970: 1_800_000_010), encryptionProfile: "modern")
        try await store.commitEncryptedIncoming(accountID: account, sender: "bob@example.org", digest: "d-m1", expectedRevision: revision, state: Data([9]),
                                                message: message, groupRoom: room)
        let candidate = try #require(await store.pendingNotifications(accountID: account).candidates.first)
        #expect(candidate.senderAvatarHash == String(repeating: "b", count: 40) && candidate.senderTitle == "Bob")
        #expect(candidate.groupMembers.map(\.id) == ["carol@example.org"])
    }
}

@Test func schema21AddsReactionStorageIdempotentlyAndRefusesNewer() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "reaction-migration-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.setAccountPreferences(accountID: account, AccountPreferences(readReceipts: false))
    try await store.close()
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "DROP TABLE reaction_notification_candidates; DROP TABLE reaction_notifications_posted; ALTER TABLE account_preferences DROP COLUMN reaction_alerts; PRAGMA user_version=20;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let migrated = try MessageStore(url: url)
    #expect(try await migrated.accountPreferences(accountID: account) == AccountPreferences(readReceipts: false, reactionNotifications: true))
    try await migrated.acquireTransportOwnership()
    try await migrated.setAccountPreferences(accountID: account, AccountPreferences(reactionNotifications: false))
    #expect(try await migrated.pendingReactionCandidates(accountID: account).isEmpty)
    #expect(try await migrated.liveReactionNotifications(accountID: account, targetMessageIDs: ["none"]).isEmpty, "the posted table exists again")
    try await migrated.close()
    let reopened = try MessageStore(url: url)
    #expect(try await reopened.accountPreferences(accountID: account).reactionNotifications == false)
    try await reopened.close()
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "PRAGMA user_version=22;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    #expect(throws: MessageStoreError.unsupportedSchema(22)) { _ = try MessageStore(url: url) }
}
