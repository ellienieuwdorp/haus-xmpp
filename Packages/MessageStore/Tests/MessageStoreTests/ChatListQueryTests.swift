import Foundation
import Testing
@testable import MessageStore

/// `chats(accountID:)` is one statement. These tests hold it to the per-chat loop it replaced,
/// rebuilt here from public API: newest message, its events, the sender's projection, the receipt.

private struct ChatSeed {
    var title: String
    var pinned = false
    var avatar: String? = nil
}

/// The removed loop: `messages(limit: 1)` + `events` per chat, sorted pinned first, then newest
/// last message (none last), then ID.
private func legacyChats(_ store: MessageStore, accountID: String, seeds: [String: ChatSeed]) async throws -> [StoredChat] {
    var result: [StoredChat] = []
    for (chatID, seed) in seeds {
        let last = try await store.messages(accountID: accountID, chatID: chatID, limit: 1).first
        var events: [MessageEvent] = []
        if let last { events = try await store.events(accountID: accountID, chatID: chatID, messageID: last.id) }
        let receipt = last?.isOutgoing != true ? nil : [MessageEventKind.displayed, .delivered].first { kind in events.contains { $0.kind == kind } }
        result.append(StoredChat(id: chatID, accountID: accountID, title: seed.title, isPinned: seed.pinned,
                                 lastMessage: last?.applying(events), avatarHash: seed.avatar, lastMessageReceipt: receipt))
    }
    return result.sorted { lhs, rhs in
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        switch (lhs.lastMessage?.sentAt, rhs.lastMessage?.sentAt) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.id < rhs.id
        }
    }
}

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

private func message(_ id: String, _ chatID: String, account: String = "a", sender: String? = nil, body: String = "Hello", sentAt: TimeInterval,
                     outgoing: Bool = false, reply: MessageReply? = nil, profile: String? = nil, wireID: String? = nil,
                     authenticated: Bool = false, attachment: StoredAttachment? = nil) -> StoredMessage {
    StoredMessage(id: id, accountID: account, chatID: chatID, senderID: sender ?? (outgoing ? account : chatID), body: body, sentAt: at(sentAt),
                  isOutgoing: outgoing, reply: reply, encryptionProfile: profile, wireID: wireID, wireIDAuthenticated: authenticated, attachment: attachment)
}

private func receipt(_ id: String, _ chatID: String, target: String, kind: MessageEventKind, at seconds: TimeInterval) -> MessageEvent {
    MessageEvent(id: id, chatID: chatID, actorID: chatID, targetWireID: target, kind: kind, payload: "{}", updatedAt: at(seconds))
}

private func withChatListStore(_ operation: (MessageStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
    do {
        try await store.acquireTransportOwnership()
        try await operation(store)
        try await store.close()
    } catch {
        try? await store.close()
        throw error
    }
}

private let room = "room@rooms.localhost"
private let incomingRoom = "other-room@rooms.localhost"

/// Seeds account `a` with one chat per case and returns what the test knows about each chat.
private func seedAccountA(_ store: MessageStore) async throws -> [String: ChatSeed] {
    var seeds: [String: ChatSeed] = [:]
    func chat(_ id: String, title: String? = nil) async throws {
        try await store.upsertChat(accountID: "a", chatID: id, title: title ?? id.capitalized)
        seeds[id] = ChatSeed(title: title ?? id.capitalized)
    }

    // 1. plain: three messages, the newest incoming with a wire ID and no events.
    try await chat("plain")
    try await store.insertMessage(message("plain-1", "plain", body: "One", sentAt: 100, wireID: "w-plain-1"))
    try await store.insertMessage(message("plain-2", "plain", body: "Two", sentAt: 200, outgoing: true, wireID: "w-plain-2"))
    try await store.insertMessage(message("plain-3", "plain", body: "Three", sentAt: 300, wireID: "w-plain-3"))

    // 2. tie: equal timestamps, the larger ID is last; a receipt for the other one must not leak onto it.
    try await chat("tie")
    try await store.insertMessage(message("1", "tie", body: "First", sentAt: 400, outgoing: true, wireID: "w-t1"))
    try await store.insertMessage(message("2", "tie", body: "Second", sentAt: 400, outgoing: true, wireID: "w-t2"))
    try await store.recordReceipt(accountID: "a", event: receipt("t-rcpt", "tie", target: "w-t1", kind: .displayed, at: 401))

    // 3. retracted: our own unauthenticated message, unsent.
    try await chat("retracted")
    try await store.insertMessage(message("retracted-1", "retracted", body: "Oops", sentAt: 500, outgoing: true, wireID: "w-r"))
    try await store.enqueueMessageUpdate(accountID: "a", id: "r-1", kind: .retraction, chatID: "retracted", targetMessageID: "retracted-1", createdAt: at(510))

    // 4. corrected: two corrections, the later one shows.
    try await chat("corrected")
    try await store.insertMessage(message("corrected-1", "corrected", body: "Tpyo", sentAt: 600, outgoing: true, wireID: "w-c"))
    try await store.enqueueMessageUpdate(accountID: "a", id: "c-1", kind: .correction, chatID: "corrected", targetMessageID: "corrected-1", body: "Typo?", createdAt: at(610))
    try await store.enqueueMessageUpdate(accountID: "a", id: "c-2", kind: .correction, chatID: "corrected", targetMessageID: "corrected-1", body: "Typo", createdAt: at(620))

    // 5. peerCorrectionIgnored: a correction and a retraction by someone other than the sender.
    try await chat("peerCorrectionIgnored")
    try await store.insertMessage(message("pc-1", "peerCorrectionIgnored", body: "Mine to change", sentAt: 700, wireID: "w-pc"))
    try await store.recordEvent(accountID: "a", event: MessageEvent(id: "pc-c", chatID: "peerCorrectionIgnored", actorID: "a", targetWireID: "w-pc",
                                                                  kind: .correction, payload: try MessageEvent.correctionPayload("Hijacked"), updatedAt: at(710)))
    try await store.recordEvent(accountID: "a", event: MessageEvent(id: "pc-r", chatID: "peerCorrectionIgnored", actorID: "a", targetWireID: "w-pc",
                                                                  kind: .retraction, payload: "{}", updatedAt: at(720)))

    // 6. attachment: an incoming file with an empty caption.
    try await chat("attachment")
    try await store.insertMessage(message("attachment-1", "attachment", body: "", sentAt: 800, attachment: StoredAttachment(
        name: "doc.pdf", mediaType: "application/pdf", size: 10, hash: "ff", secret: Data([9]), url: "https://u/doc")))

    // 7. attachmentRetracted: our own file, unsent, drops its attachment.
    try await chat("attachmentRetracted")
    try await store.insertMessage(message("ar-1", "attachmentRetracted", body: "Look", sentAt: 810, outgoing: true, wireID: "w-ar", attachment: StoredAttachment(
        name: "pic.jpg", mediaType: "image/jpeg", size: 20, width: 4, height: 3, hash: "aa", cipherHash: "bb", secret: Data([1, 2]),
        url: "https://u/pic", uploadState: .uploaded, uploadTaskID: 7)))
    try await store.enqueueMessageUpdate(accountID: "a", id: "ar-r", kind: .retraction, chatID: "attachmentRetracted", targetMessageID: "ar-1", createdAt: at(815))

    // 8. delivered.
    try await chat("delivered")
    try await store.insertMessage(message("d-1", "delivered", body: "Sent", sentAt: 900, outgoing: true, wireID: "w-d"))
    try await store.recordReceipt(accountID: "a", event: receipt("d-rcpt", "delivered", target: "w-d", kind: .delivered, at: 905))

    // 9. displayed wins over delivered. Same timestamp as `delivered`: the ID breaks the tie.
    try await chat("displayed")
    try await store.insertMessage(message("disp-1", "displayed", body: "Seen?", sentAt: 900, outgoing: true, wireID: "w-disp"))
    try await store.recordReceipt(accountID: "a", event: receipt("disp-d", "displayed", target: "w-disp", kind: .delivered, at: 905))
    try await store.recordReceipt(accountID: "a", event: receipt("disp-s", "displayed", target: "w-disp", kind: .displayed, at: 906))

    // 10. incomingReceiptIgnored: the marker arrived before its (incoming) target, so it was retained.
    try await chat("incomingReceiptIgnored")
    try await store.recordReceipt(accountID: "a", event: receipt("inc-s", "incomingReceiptIgnored", target: "w-inc", kind: .displayed, at: 1000))
    try await store.insertMessage(message("inc-1", "incomingReceiptIgnored", body: "Theirs", sentAt: 1000, wireID: "w-inc"))

    // 11. ambiguous: two unauthenticated messages share a wire ID, so neither gets a projection.
    try await chat("ambiguous")
    try await store.insertMessage(message("amb-1", "ambiguous", body: "Old", sentAt: 1100, outgoing: true, wireID: "w-dup"))
    try await store.insertMessage(message("amb-2", "ambiguous", body: "New", sentAt: 1110, outgoing: true, wireID: "w-dup"))
    try await store.recordReceipt(accountID: "a", event: receipt("amb-rcpt", "ambiguous", target: "w-dup", kind: .delivered, at: 1120))

    // 12. authenticatedWins: the authenticated last message owns the shared wire ID.
    try await chat("authenticatedWins")
    try await store.insertMessage(message("aw-1", "authenticatedWins", body: "Peer-claimed", sentAt: 1200, outgoing: true, profile: "legacy", wireID: "w-auth"))
    try await store.insertMessage(message("aw-2", "authenticatedWins", body: "Signed", sentAt: 1210, outgoing: true, profile: "modern", wireID: "w-auth", authenticated: true))
    try await store.recordReceipt(accountID: "a", event: receipt("aw-rcpt", "authenticatedWins", target: "w-auth", kind: .delivered, at: 1220))

    // 12b. authenticatedElsewhere: an older authenticated message owns the ID, so the unauthenticated last gets nothing.
    try await chat("authenticatedElsewhere")
    try await store.insertMessage(message("ae-1", "authenticatedElsewhere", body: "Signed", sentAt: 1230, outgoing: true, profile: "modern", wireID: "w-ae", authenticated: true))
    try await store.insertMessage(message("ae-2", "authenticatedElsewhere", body: "Claimed", sentAt: 1240, outgoing: true, profile: "legacy", wireID: "w-ae"))
    try await store.recordEvent(accountID: "a", event: MessageEvent(id: "ae-r", chatID: "authenticatedElsewhere", actorID: "a", targetWireID: "w-ae",
                                                                  kind: .retraction, payload: "{}", updatedAt: at(1245)))

    // 13. groupReference: modern room messages resolve through the room-assigned stanza-id.
    try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
    // Own room message: sealed without an authenticated wire ID, reconciled from the archive with the room's stanza-id, then unsent.
    try await chat(room, title: "Room")
    try await store.enqueueOutgoing(message("g-own", room, body: "Group hello", sentAt: 1300, outgoing: true))
    try await store.sealQueuedOutgoing(accountID: "a", messageID: "g-own", profile: "modern", expectedRevision: 1, state: Data([2]), wire: Data([3]), authenticateWireID: false)
    #expect(try await store.reconcileArchivedOutgoing(accountID: "a", messageID: "g-own", expectedEncryptedWire: Data([3]), groupRoom: room, roomStanzaID: "room-stanza-own"))
    #expect(try await store.reactionReference(accountID: "a", messageID: "g-own") == "room-stanza-own")
    try await store.enqueueMessageUpdate(accountID: "a", id: "g-own-r", kind: .retraction, chatID: room, targetMessageID: "g-own", createdAt: at(1310))
    // Incoming room message: committed with its ciphertext, bound to a stanza-id afterwards, reacted to by
    // another member; our own retraction of someone else's message is kept but never projected.
    try await chat(incomingRoom, title: "Other room")
    let incoming = message("g-in", incomingRoom, sender: "alice@localhost", body: "From Alice", sentAt: 1350, profile: "modern")
    try await store.commitEncryptedIncoming(accountID: "a", sender: "alice@localhost", digest: "d-g", expectedRevision: 2, state: Data([3]),
                                            message: incoming, groupRoom: incomingRoom)
    try await store.bindArchivedGroupReference(accountID: "a", sender: "alice@localhost", digest: "d-g", room: incomingRoom, stanzaID: "room-stanza-in")
    try await store.commitEncryptedIncoming(accountID: "a", sender: "bob@localhost", digest: "d-r", expectedRevision: 3, state: Data([4]), message: nil,
                                            reaction: AuthenticatedReaction(id: "g-react", chatID: incomingRoom, actorID: "bob@localhost",
                                                                            targetWireID: "room-stanza-in", reactions: ["👍"], updatedAt: at(1360)),
                                            groupRoom: incomingRoom)
    try await store.recordEvent(accountID: "a", event: MessageEvent(id: "g-in-r", chatID: incomingRoom, actorID: "a", targetWireID: "room-stanza-in",
                                                                  kind: .retraction, payload: "{}", updatedAt: at(1370)))

    // 14. queued: the outbox state survives.
    try await chat("queued")
    try await store.enqueueOutgoing(message("q-1", "queued", body: "Pending", sentAt: 1400, outgoing: true))

    // 15. empty: no messages, sorted last among unpinned chats.
    try await chat("empty")

    // 16. pinnedOld sorts first despite its age; a pinned chat without messages follows it.
    try await chat("pinnedOld")
    try await store.insertMessage(message("po-1", "pinnedOld", body: "Ancient", sentAt: 1))
    try await store.setPinned(accountID: "a", chatID: "pinnedOld", pinned: true)
    seeds["pinnedOld"]?.pinned = true
    try await chat("pinnedEmpty")
    try await store.setPinned(accountID: "a", chatID: "pinnedEmpty", pinned: true)
    seeds["pinnedEmpty"]?.pinned = true

    // 17. avatar.
    try await chat("avatar")
    try await store.insertMessage(message("av-1", "avatar", body: "Pic", sentAt: 1500))
    try await store.setAvatarHash(accountID: "a", chatID: "avatar", hash: "abc123")
    seeds["avatar"]?.avatar = "abc123"

    // 18. reply.
    try await chat("reply")
    try await store.insertMessage(message("rep-1", "reply", body: "Quoting", sentAt: 1600, outgoing: true,
                                          reply: MessageReply(messageID: "plain-1", senderID: "plain", body: "One", wireID: "w-plain-1")))

    // 19. unreadable: a placeholder newer than the readable message is the preview, keeps its reason,
    // and the chat sorts by the placeholder's `sent_at`.
    try await chat("unreadable")
    try await store.insertMessage(message("un-1", "unreadable", body: "Readable", sentAt: 1700))
    try await store.recordUnreadableMessage(UnreadableMessage(accountID: "a", chatID: "unreadable", senderID: "a", isOutgoing: true, sentAt: at(1800),
                                                              reason: .notForThisDevice, key: .ciphertext(sender: "a", digest: "abc")))
    return seeds
}

/// A second account reusing chat IDs, message IDs and wire IDs: nothing may leak into account `a`.
private func seedDecoyAccountB(_ store: MessageStore) async throws -> [String: ChatSeed] {
    var seeds: [String: ChatSeed] = [:]
    for id in ["plain", "delivered", "empty", "retracted"] {
        try await store.upsertChat(accountID: "b", chatID: id, title: "B \(id)")
        seeds[id] = ChatSeed(title: "B \(id)")
    }
    try await store.setPinned(accountID: "b", chatID: "empty", pinned: true)
    seeds["empty"]?.pinned = true
    try await store.insertMessage(message("plain-3", "plain", account: "b", body: "Decoy", sentAt: 99_999, outgoing: true, wireID: "w-plain-3",
                                          attachment: StoredAttachment(name: "leak.bin", mediaType: "application/octet-stream", size: 1, hash: "", secret: Data([5]))))
    try await store.insertMessage(message("b-d", "delivered", account: "b", body: "Decoy", sentAt: 99_000, outgoing: true, wireID: "w-d"))
    try await store.recordReceipt(accountID: "b", event: receipt("b-disp", "delivered", target: "w-d", kind: .displayed, at: 99_001))
    try await store.recordReceipt(accountID: "b", event: receipt("b-plain", "plain", target: "w-plain-3", kind: .displayed, at: 99_002))
    try await store.insertMessage(message("b-e", "empty", account: "b", body: "Decoy", sentAt: 50))
    try await store.insertMessage(message("b-r", "retracted", account: "b", body: "Decoy kept", sentAt: 60, outgoing: true, wireID: "w-r"))
    return seeds
}

@Test func chatsMatchesThePerChatLoopOnSeededData() async throws {
    try await withChatListStore { store in
        let seedsA = try await seedAccountA(store)
        let seedsB = try await seedDecoyAccountB(store)

        let chats = try await store.chats(accountID: "a")
        let legacy = try await legacyChats(store, accountID: "a", seeds: seedsA)
        #expect(chats.map(\.id) == legacy.map(\.id))
        #expect(chats.count == legacy.count)
        for (new, old) in zip(chats, legacy) { #expect(new == old, "\(new.id)") }

        let decoy = try await store.chats(accountID: "b")
        #expect(decoy == (try await legacyChats(store, accountID: "b", seeds: seedsB)))
        #expect(decoy.map(\.id) == ["empty", "plain", "delivered", "retracted"])

        // The loop's contract, stated directly so a shared mistake in the reference cannot hide.
        let byID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        #expect(chats.map(\.id) == ["pinnedOld", "pinnedEmpty", "unreadable", "reply", "avatar", "queued", incomingRoom, room,
                                    "authenticatedElsewhere", "authenticatedWins", "ambiguous", "incomingReceiptIgnored",
                                    "delivered", "displayed", "attachmentRetracted", "attachment", "peerCorrectionIgnored",
                                    "corrected", "retracted", "tie", "plain", "empty"])
        let plain = try #require(byID["plain"]?.lastMessage)
        #expect(plain.id == "plain-3" && plain.body == "Three" && plain.attachment == nil && !plain.isOutgoing)
        #expect(byID["plain"]?.lastMessageReceipt == nil)
        #expect(byID["tie"]?.lastMessage?.id == "2" && byID["tie"]?.lastMessageReceipt == nil)
        let retracted = try #require(byID["retracted"]?.lastMessage)
        #expect(retracted.isRetracted && retracted.body.isEmpty && !retracted.isEdited && retracted.attachment == nil)
        let corrected = try #require(byID["corrected"]?.lastMessage)
        #expect(corrected.body == "Typo" && corrected.isEdited && !corrected.isRetracted)
        let ignored = try #require(byID["peerCorrectionIgnored"]?.lastMessage)
        #expect(ignored.body == "Mine to change" && !ignored.isEdited && !ignored.isRetracted)
        #expect(byID["attachment"]?.lastMessage?.attachment == StoredAttachment(name: "doc.pdf", mediaType: "application/pdf", size: 10, hash: "ff",
                                                                             secret: Data([9]), url: "https://u/doc"))
        #expect(byID["attachment"]?.lastMessage?.body == "")
        let attachmentRetracted = try #require(byID["attachmentRetracted"]?.lastMessage)
        #expect(attachmentRetracted.isRetracted && attachmentRetracted.attachment == nil)
        #expect(byID["delivered"]?.lastMessageReceipt == .delivered)
        #expect(byID["displayed"]?.lastMessageReceipt == .displayed)
        #expect(byID["incomingReceiptIgnored"]?.lastMessageReceipt == nil)
        #expect(byID["ambiguous"]?.lastMessage?.id == "amb-2" && byID["ambiguous"]?.lastMessageReceipt == nil)
        #expect(byID["authenticatedWins"]?.lastMessage?.id == "aw-2" && byID["authenticatedWins"]?.lastMessageReceipt == .delivered)
        #expect(byID["authenticatedElsewhere"]?.lastMessage?.id == "ae-2" && byID["authenticatedElsewhere"]?.lastMessage?.isRetracted == false)
        let group = try #require(byID[room]?.lastMessage)
        #expect(group.id == "g-own" && group.isRetracted && group.body.isEmpty && group.encryptionProfile == "modern" && !group.wireIDAuthenticated)
        let incomingGroup = try #require(byID[incomingRoom]?.lastMessage)
        #expect(incomingGroup.id == "g-in" && incomingGroup.body == "From Alice" && !incomingGroup.isRetracted)
        #expect(try await store.events(accountID: "a", chatID: incomingRoom, messageID: "g-in").map(\.kind) == [.reaction])
        #expect(byID["queued"]?.lastMessage?.transportState == .queued)
        #expect(byID["empty"]?.lastMessage == nil && byID["empty"]?.lastMessageReceipt == nil)
        #expect(byID["pinnedOld"]?.isPinned == true && byID["pinnedEmpty"]?.isPinned == true)
        #expect(byID["avatar"]?.avatarHash == "abc123" && byID["plain"]?.avatarHash == nil)
        #expect(byID["reply"]?.lastMessage?.reply == MessageReply(messageID: "plain-1", senderID: "plain", body: "One", wireID: "w-plain-1"))
        #expect(byID["pinnedOld"]?.title == "Pinnedold" && byID[room]?.title == "Room")
        let unreadable = try #require(byID["unreadable"]?.lastMessage)
        #expect(unreadable.unreadableReason == .notForThisDevice && unreadable.sentAt == at(1800) && unreadable.isOutgoing)
        #expect(try await store.chats(accountID: "nobody").isEmpty)
    }
}
