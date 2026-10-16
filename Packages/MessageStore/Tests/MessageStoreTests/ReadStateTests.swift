import Foundation
import Testing
@testable import MessageStore

private let account = "self@x"
private let peer = "peer@x"
private let room = "room@rooms.x"

private func message(_ id: String, at second: Double, chat: String = peer, sender: String = peer, outgoing: Bool = false, wire: String? = nil) -> StoredMessage {
    StoredMessage(id: id, accountID: account, chatID: chat, senderID: sender, body: "Synthetic \(id)",
                  sentAt: Date(timeIntervalSince1970: 1_800_000_000 + second), isOutgoing: outgoing, encryptionProfile: "modern", wireID: wire ?? id)
}

/// One authenticated commit, as OMEMO makes it; the revision follows the store's.
private func commit(_ store: MessageStore, digest: String, sender: String = peer, message: StoredMessage? = nil, groupRoom: String? = nil,
                    roomStanzaID: String? = nil, archiveStanzaID: String? = nil, readMarker: OwnReadMarker? = nil) async throws {
    let revision = try await store.encryptionStateRevision(accountID: account)!
    try await store.commitEncryptedIncoming(accountID: account, sender: sender, digest: digest, expectedRevision: revision, state: Data([UInt8(revision % 250)]),
                                            message: message, groupRoom: groupRoom, roomStanzaID: roomStanzaID, archiveStanzaID: archiveStanzaID, readMarker: readMarker)
}

@Test func readPointerOnlyMovesForwardAndCountsWhatFollows() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await store.upsertChat(accountID: account, chatID: peer, title: "Peer")
        for (index, id) in ["m1", "m2", "m3"].enumerated() { try await store.insertMessage(message(id, at: Double(index))) }
        try await store.insertMessage(message("mine", at: 5, sender: account, outgoing: true))
        // Never read: every incoming message counts, our own never does.
        #expect(try await store.unreadCounts(accountID: account) == [peer: 3])
        #expect(try await store.readPointer(accountID: account, chatID: peer) == nil)
        #expect(try await store.markRead(accountID: account, chatID: peer, throughMessageID: "m2"))
        #expect(try await store.chats(accountID: account).first?.unreadCount == 1)
        // Older state is ignored.
        #expect(try await !store.markRead(accountID: account, chatID: peer, throughMessageID: "m1"))
        #expect(try await !store.markRead(accountID: account, chatID: peer, throughMessageID: "m2"))
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.messageID == "m2")
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.publishPending == true)
        // Marking the chat read goes to its newest message, our own reply included.
        #expect(try await store.markChatRead(accountID: account, chatID: peer))
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.messageID == "mine")
        #expect(try await store.unreadCounts(accountID: account).isEmpty)
        #expect(try await !store.markChatRead(accountID: account, chatID: peer))
        // A message of another chat is refused.
        await #expect(throws: MessageStoreError.invalidValue) { try await store.markRead(accountID: account, chatID: "other@x", throughMessageID: "m3") }
        // A same-instant message sorts by id, the same order the timeline uses.
        try await store.insertMessage(message("zz-late", at: 5))
        #expect(try await store.unreadCounts(accountID: account) == [peer: 1])
        #expect(try await store.readNotificationMessageIDs(accountID: account, messageIDs: ["m1", "m3", "zz-late", "unknown"]) == ["m1", "m3"])
    }
}

@Test func readMessagesNeverBecomeCandidatesAndReadingRemovesThem() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await commit(store, digest: "d1", message: message("m1", at: 10))
        #expect(try await store.markRead(accountID: account, chatID: peer, throughMessageID: "m1"))
        // Catch-up of history at or below the pointer (read elsewhere) never alerts.
        try await commit(store, digest: "d0", message: message("m0", at: 5))
        #expect(try await store.readNotificationMessageIDs(accountID: account, messageIDs: ["m0"]) == ["m0"])
        // Newer messages alert until the pointer passes them.
        try await commit(store, digest: "d2", message: message("m2", at: 20))
        try await commit(store, digest: "d3", message: message("m3", at: 30))
        #expect(try await store.markRead(accountID: account, chatID: peer, throughMessageID: "m2"))
        let batch = try await store.pendingNotifications(accountID: account)
        #expect(batch.candidates.map(\.key) == [.message("m3")] && batch.claimed == [.message("m3")])
    }
}

@Test func ownDisplayedMarkersAdvanceWithTheRatchetAndOnlyForPeerMessages() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await commit(store, digest: "d1", message: message("m1", at: 1, wire: "w1"))
        try await commit(store, digest: "d2", message: message("m2", at: 2, wire: "w2"))
        try await store.insertMessage(message("mine", at: 3, sender: account, outgoing: true, wire: "w-mine"))
        // Only our own account may carry a read marker, and nothing else may ride with it.
        await #expect(throws: MessageStoreError.invalidValue) {
            try await commit(store, digest: "forged", sender: peer, readMarker: OwnReadMarker(chatID: peer, targetWireID: "w2"))
        }
        await #expect(throws: MessageStoreError.invalidValue) {
            try await commit(store, digest: "mixed", sender: account, message: message("x", at: 9, sender: account, outgoing: true), readMarker: OwnReadMarker(chatID: peer, targetWireID: "w2"))
        }
        #expect(try await store.readPointer(accountID: account, chatID: peer) == nil)
        try await commit(store, digest: "own-marker", sender: account, readMarker: OwnReadMarker(chatID: peer, targetWireID: "w1"))
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.messageID == "m1")
        // Another device's read never publishes: that device owns its XEP-0490 state.
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.publishPending == false)
        #expect(try await store.hasEncryptedIncoming(accountID: account, sender: account, digest: "own-marker"))
        // Plain markers (carbons, archive) take the same rule; unknown and own targets are ignored.
        #expect(try await !store.recordOwnDisplayed(accountID: account, chatID: peer, targetWireID: "unknown"))
        #expect(try await !store.recordOwnDisplayed(accountID: account, chatID: peer, targetWireID: "w-mine"))
        #expect(try await store.recordOwnDisplayed(accountID: account, chatID: peer, targetWireID: "w2"))
        #expect(try await !store.recordOwnDisplayed(accountID: account, chatID: peer, targetWireID: "w1"))
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.messageID == "m2")
    }
}

@Test func displayedSyncResolvesOnlyThroughTheArchiveThatAssignedTheID() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await commit(store, digest: "d1", message: message("m1", at: 1), archiveStanzaID: "s1")
        try await commit(store, digest: "d2", message: message("m2", at: 2), archiveStanzaID: "s2")
        #expect(try await store.archiveStanzaID(accountID: account, messageID: "m1") == "s1")
        // Unknown ids and foreign archives are ignored (XEP-0490 business rules).
        #expect(try await !store.applyDisplayedSync(accountID: account, chatID: peer, stanzaID: "nope", by: account))
        #expect(try await !store.applyDisplayedSync(accountID: account, chatID: peer, stanzaID: "s1", by: peer))
        #expect(try await !store.applyDisplayedSync(accountID: account, chatID: "other@x", stanzaID: "s1", by: account))
        #expect(try await store.applyDisplayedSync(accountID: account, chatID: peer, stanzaID: "s2", by: account))
        #expect(try await !store.applyDisplayedSync(accountID: account, chatID: peer, stanzaID: "s1", by: account))
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.messageID == "m2")
        // That older item means another device overwrote the node: publish our newer state again until the server holds it.
        #expect(try await store.pendingDisplayedSyncPublications(accountID: account).map(\.stanzaID) == ["s2"])
        #expect(try await !store.applyDisplayedSync(accountID: account, chatID: peer, stanzaID: "s2", by: account))
        #expect(try await store.pendingDisplayedSyncPublications(accountID: account).isEmpty)
        // A room names its messages by the room's own ids.
        let member = StoredMessage(id: "g1", accountID: account, chatID: room, senderID: "member@x", body: "Synthetic group",
                                   sentAt: Date(timeIntervalSince1970: 1_800_000_010), encryptionProfile: "modern", wireID: "origin-g1")
        try await commit(store, digest: "g1", sender: "member@x", message: member, groupRoom: room, roomStanzaID: "room-7")
        #expect(try await !store.applyDisplayedSync(accountID: account, chatID: room, stanzaID: "room-7", by: account))
        #expect(try await store.applyDisplayedSync(accountID: account, chatID: room, stanzaID: "room-7", by: room))
        #expect(try await store.unreadCounts(accountID: account).isEmpty)
    }
}

@Test func localReadsPublishTheNewestIncomingIdOnce() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await commit(store, digest: "d1", message: message("m1", at: 1), archiveStanzaID: "s1")
        try await commit(store, digest: "d2", message: message("m2", at: 2))                      // no id known yet
        try await store.insertMessage(message("mine", at: 3, sender: account, outgoing: true))
        #expect(try await store.markChatRead(accountID: account, chatID: peer))
        // Outgoing messages are never published; the newest incoming message with an id is.
        let publications = try await store.pendingDisplayedSyncPublications(accountID: account)
        #expect(publications == [DisplayedSyncPublication(chatID: peer, stanzaID: "s1", by: account, pointerMessageID: "mine")])
        // A later copy of m2 from our archive binds its id, so the next publication names it.
        try await store.bindArchivedDirectStanzaID(accountID: account, sender: peer, digest: "d2", stanzaID: "s2")
        #expect(try await store.archiveStanzaID(accountID: account, messageID: "m2") == "s2")
        try await store.bindArchivedDirectStanzaID(accountID: account, sender: peer, digest: "d2", stanzaID: "other")
        #expect(try await store.archiveStanzaID(accountID: account, messageID: "m2") == "s2")
        #expect(try await store.pendingDisplayedSyncPublications(accountID: account).map(\.stanzaID) == ["s2"])
        try await store.finishDisplayedSyncPublication(accountID: account, DisplayedSyncPublication(chatID: peer, stanzaID: "s2", by: account, pointerMessageID: "mine"))
        #expect(try await store.pendingDisplayedSyncPublications(accountID: account).isEmpty)
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.publishPending == false)
        // A newer read while a publish was in flight stays pending.
        try await commit(store, digest: "d4", message: message("m4", at: 4), archiveStanzaID: "s4")
        #expect(try await store.markChatRead(accountID: account, chatID: peer))
        try await store.finishDisplayedSyncPublication(accountID: account, DisplayedSyncPublication(chatID: peer, stanzaID: "s2", by: account, pointerMessageID: "mine"))
        #expect(try await store.pendingDisplayedSyncPublications(accountID: account).map(\.stanzaID) == ["s4"])
        // The same id arriving from the server settles it without a publication.
        #expect(try await !store.applyDisplayedSync(accountID: account, chatID: peer, stanzaID: "s4", by: account))
        #expect(try await store.pendingDisplayedSyncPublications(accountID: account).isEmpty)
    }
}

/// A first sign-in is not news: the newest archive page, and whatever backfill later brings from before it, count as
/// read without any pointer (nothing is published). Messages after it are unread and alert. XEP-0490 state older than the
/// baseline does not make history unread again.
@Test func firstArchivePageIsReadHistoryWithoutPublishing() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await commit(store, digest: "d1", message: message("m1", at: 1), archiveStanzaID: "s1")
        try await commit(store, digest: "d2", message: message("m2", at: 2), archiveStanzaID: "s2")
        #expect(try await store.unreadCounts(accountID: account) == [peer: 2])
        try await store.saveNewestArchivePage(accountID: account, archiveID: account, cursor: "c2", oldestID: "c1", complete: false,
                                              historyThrough: Date(timeIntervalSince1970: 1_800_000_002))
        #expect(try await store.unreadCounts(accountID: account).isEmpty)
        #expect(try await store.readPointer(accountID: account, chatID: peer) == nil)
        #expect(try await store.pendingDisplayedSyncPublications(accountID: account).isEmpty)
        // Backfill: a chat first seen in an older page is read, and never alerts.
        try await commit(store, digest: "o1", sender: "old@x", message: message("o1", at: 0.5, chat: "old@x", sender: "old@x"))
        #expect(try await store.unreadCounts(accountID: account).isEmpty)
        #expect(try await store.readNotificationMessageIDs(accountID: account, messageIDs: ["m1", "o1"]) == ["m1", "o1"])
        // A room counts against its own archive's baseline once it has one, the account's before that.
        let member = { (id: String, at: Double) in StoredMessage(id: id, accountID: account, chatID: room, senderID: "member@x", body: "Synthetic group",
                                                                  sentAt: Date(timeIntervalSince1970: 1_800_000_000 + at), encryptionProfile: "modern", wireID: "origin-" + id) }
        try await commit(store, digest: "g1", sender: "member@x", message: member("g1", 2.5), groupRoom: room, roomStanzaID: "room-1")
        #expect(try await store.unreadCounts(accountID: account) == [room: 1])
        try await store.saveNewestArchivePage(accountID: account, archiveID: room, cursor: "r1", oldestID: "r1", complete: true,
                                              historyThrough: Date(timeIntervalSince1970: 1_800_000_002.5))
        #expect(try await store.unreadCounts(accountID: account).isEmpty)
        // Nothing of the history alerts; what follows it does.
        try await commit(store, digest: "d3", message: message("m3", at: 3), archiveStanzaID: "s3")
        try await commit(store, digest: "g2", sender: "member@x", message: member("g2", 4), groupRoom: room, roomStanzaID: "room-2")
        #expect(try await store.unreadCounts(accountID: account) == [peer: 1, room: 1])
        // Another device's older XEP-0490 state sets a pointer but history stays read.
        #expect(try await store.applyDisplayedSync(accountID: account, chatID: peer, stanzaID: "s1", by: account))
        #expect(try await store.unreadCounts(accountID: account) == [peer: 1, room: 1])
        #expect(try await store.pendingNotifications(accountID: account).claimed.count == 2)
    }
}

/// An archive the first walk found empty has no history: its baseline is the earliest possible and stays, so what a
/// later connection's first page holds (it arrived meanwhile) is unread and alerts.
@Test func emptyFirstArchiveKeepsWhatArrivesAfterwardsUnread() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        try await store.recordEmptyArchive(accountID: account, archiveID: account)
        try await commit(store, digest: "d1", message: message("m1", at: 1), archiveStanzaID: "s1")
        try await commit(store, digest: "d2", message: message("m2", at: 2), archiveStanzaID: "s2")
        try await store.saveNewestArchivePage(accountID: account, archiveID: account, cursor: "c2", oldestID: "c1", complete: true,
                                              historyThrough: Date(timeIntervalSince1970: 1_800_000_002))
        #expect(try await store.unreadCounts(accountID: account) == [peer: 2])
        #expect(try await store.pendingNotifications(accountID: account).claimed.count == 2)
    }
}

/// A room joined during a connection is first walked on the next one. The join is its baseline, so what arrived in
/// between, stored or retained for review, stays unread and alerts once that first page brings it, while history from
/// before the join stays read. A room that already has a checkpoint keeps its own baseline.
@Test func joinedRoomCountsWhatArrivesBeforeItsFirstWalk() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        let at = { (second: Double) in Date(timeIntervalSince1970: 1_800_000_000 + second) }
        let member = { (id: String, second: Double) in StoredMessage(id: id, accountID: account, chatID: room, senderID: "member@x", body: "Synthetic group",
                                                                      sentAt: at(second), encryptionProfile: "modern", wireID: "origin-" + id) }
        try await store.upsertChat(accountID: account, chatID: room, title: "Room")
        try await store.recordJoinedRoom(accountID: account, room: room, at: at(2))
        // After the join: one message read live, one held for review.
        try await commit(store, digest: "g3", sender: "member@x", message: member("g3", 3), groupRoom: room, roomStanzaID: "room-3")
        try await store.retainEncryptedIncoming(accountID: account, sender: "member@x", digest: "p4", wire: Data([4]),
                                                notification: PendingNotificationContext(chatID: room, sentAt: at(4)))
        // The next connection's first page also holds history from before the join.
        try await commit(store, digest: "g1", sender: "member@x", message: member("g1", 1), groupRoom: room, roomStanzaID: "room-1")
        try await store.saveNewestArchivePage(accountID: account, archiveID: room, cursor: "room-4", oldestID: "room-1", complete: true,
                                              historyThrough: at(4))
        #expect(try await store.unreadCounts(accountID: account) == [room: 1])
        #expect(Set(try await store.pendingNotifications(accountID: account).claimed) == [.message("g3"), .pending(sender: "member@x", digest: "p4")])

        // Joining a room again once it has been walked changes nothing: its unread message stays unread.
        let other = "other@rooms.x"
        try await store.saveNewestArchivePage(accountID: account, archiveID: other, cursor: "o1", oldestID: "o1", complete: true)
        try await commit(store, digest: "o5", sender: "member@x", message: StoredMessage(id: "o5", accountID: account, chatID: other, senderID: "member@x",
            body: "Synthetic group", sentAt: at(5), encryptionProfile: "modern", wireID: "origin-o5"), groupRoom: other, roomStanzaID: "other-5")
        try await store.recordJoinedRoom(accountID: account, room: other, at: at(6))
        #expect(try await store.unreadCounts(accountID: account)[other] == 1)
    }
}

/// Retained ciphertext waiting for trust or keys is held to the same history rule as a message row: what the
/// first archive page or a later backfill brings from before the baseline never asks for review, and a candidate the
/// first page retained before its baseline existed goes when the baseline is recorded. Newer ciphertext still alerts.
@Test func retainedHistoryCiphertextDoesNotAlert() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        let at = { (second: Double) in Date(timeIntervalSince1970: 1_800_000_000 + second) }
        // First page: one message and one retained ciphertext, both from before this device joined.
        try await commit(store, digest: "d1", message: message("m1", at: 2), archiveStanzaID: "s1")
        try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "p1", wire: Data([1]),
                                                notification: PendingNotificationContext(chatID: peer, sentAt: at(1)))
        #expect(try await store.pendingNotifications(accountID: account).claimed.count == 2)
        try await store.saveNewestArchivePage(accountID: account, archiveID: account, cursor: "c2", oldestID: "c1", complete: false,
                                              historyThrough: at(2))
        #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        // Backfill from further back retains more history: no candidate.
        try await store.retainEncryptedIncoming(accountID: account, sender: "old@x", digest: "p0", wire: Data([2]),
                                                notification: PendingNotificationContext(chatID: "old@x", sentAt: at(0.5)))
        #expect(try await store.pendingNotifications(accountID: account).claimed.isEmpty)
        // News after the baseline still asks for review.
        try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "p3", wire: Data([3]),
                                                notification: PendingNotificationContext(chatID: peer, sentAt: at(3)))
        #expect(try await store.pendingNotifications(accountID: account).claimed == [.pending(sender: peer, digest: "p3")])
    }
}
