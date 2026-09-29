import Foundation
import Testing
@testable import MessageStore

private let account = "alice@localhost"
private let limits = MessageStore.pendingLimits

/// A message in `chat` (created if needed), for the evidence that makes a sender known.
private func write(_ store: MessageStore, _ message: StoredMessage) async throws {
    try await store.upsertChat(accountID: account, chatID: message.chatID, title: message.chatID)
    _ = try await store.insertMessage(message)
}

private func limitStore() async throws -> (MessageStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
    try await store.acquireTransportOwnership()
    return (store, directory)
}

private func overflow(_ sender: String, _ digest: String, chat: String? = nil, bubble: Bool = true, approved: Bool = false) -> RetentionOverflow {
    let chatID = chat ?? sender
    return RetentionOverflow(chatID: chatID, placeholder: bubble ? UnreadableMessage(accountID: account, chatID: chatID, senderID: sender, isOutgoing: sender == account,
        sentAt: Date(timeIntervalSince1970: 1_000), reason: .retentionLimit, key: .ciphertext(sender: sender, digest: digest)) : nil, senderApproved: approved)
}

/// Offers `count` new ciphertexts from `sender` in `chat`, each waiting for review with an alert (or, `approved`, for a
/// retry of an approved device's copy); returns how many were kept.
private func offer(_ store: MessageStore, _ sender: String, count: Int, chat: String? = nil, tag: String = "", approved: Bool = false) async throws -> Int {
    var kept = 0
    for index in 0..<count {
        let digest = "\(sender)-\(tag)\(index)"
        if try await store.retainEncryptedIncoming(accountID: account, sender: sender, digest: digest, wire: Data([1]),
                                                   notification: PendingNotificationContext(chatID: chat ?? sender, sentAt: Date(timeIntervalSince1970: 1_000)),
                                                   overflow: overflow(sender, digest, chat: chat, approved: approved)) { kept += 1 }
    }
    return kept
}

/// Only durable evidence that the account knows the sender lifts the stranger quota: the account itself, a conversation or
/// direct chat the account wrote in, or an authenticated message from the sender in their direct chat or (decrypted) in
/// the room. A placeholder or a plaintext room line from them is no evidence. An approved device's copy, waiting for a
/// retry rather than a review, is not held to a stranger's quota at all.
@Test func strangerQuotaAppliesUntilTheAccountKnowsTheSender() async throws {
    let room = "room@conference.localhost"
    let cases: [(sender: String, chat: String?, approved: Bool, known: Bool, setUp: @Sendable (MessageStore, String) async throws -> Void)] = [
        ("stranger@localhost", nil, false, false, { _, _ in }),
        (account, "bob@localhost", false, true, { _, _ in }),
        ("wrote@localhost", nil, false, true, { store, sender in
            try await write(store, StoredMessage(id: "out", accountID: account, chatID: sender, senderID: account, body: "Hi", isOutgoing: true)) }),
        ("member@localhost", room, false, true, { store, _ in
            try await write(store, StoredMessage(id: "out", accountID: account, chatID: room, senderID: account, body: "Hi all", isOutgoing: true)) }),
        ("approved@localhost", nil, false, true, { store, sender in
            try await write(store, StoredMessage(id: "in", accountID: account, chatID: sender, senderID: sender, body: "Hello", encryptionProfile: "modern")) }),
        ("read-member@localhost", room, false, true, { store, sender in
            try await write(store, StoredMessage(id: "in", accountID: account, chatID: room, senderID: sender, body: "Hello room", encryptionProfile: "modern")) }),
        ("plain-member@localhost", room, false, false, { store, sender in
            try await write(store, StoredMessage(id: "in", accountID: account, chatID: room, senderID: sender, body: "Plain hello")) }),
        ("unreadable@localhost", nil, false, false, { store, sender in
            _ = try await store.recordUnreadableMessage(UnreadableMessage(accountID: account, chatID: sender, senderID: sender, isOutgoing: false,
                sentAt: Date(timeIntervalSince1970: 1), reason: .notForThisDevice, key: .archive(archive: account, id: "a1"))) }),
        ("retrying@localhost", room, true, true, { _, _ in }),
    ]
    for entry in cases {
        let (store, directory) = try await limitStore()
        try await entry.setUp(store, entry.sender)
        let kept = try await offer(store, entry.sender, count: limits.perStranger + 1, chat: entry.chat, approved: entry.approved)
        #expect(kept == limits.perStranger + (entry.known ? 1 : 0), "\(entry.sender)")
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }
}

/// Each limit in turn: the ciphertext it refuses becomes a final outcome in the same transaction (a quiet placeholder for
/// a would-be bubble, the consumed replay identity otherwise), never an error, never a pending row or an alert.
@Test func everyLimitTurnsOverflowIntoAQuietFinalOutcome() async throws {
    let (store, directory) = try await limitStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    func expectFinal(_ sender: String, _ digest: String, placeholder: Bool) async throws {
        #expect(try await store.pendingEncryptedIncoming(accountID: account, sender: sender, digest: digest) == nil)
        #expect(try await store.hasEncryptedIncoming(accountID: account, sender: sender, digest: digest))
        let row = try await store.message(accountID: account, messageID: overflow(sender, digest).placeholder!.id)
        #expect(row?.unreadableReason == (placeholder ? .retentionLimit : nil))
        #expect(row?.body ?? "" == "")
    }
    // A known sender's quota (the account's own devices).
    #expect(try await offer(store, account, count: limits.perKnownSender, chat: "bob@localhost") == limits.perKnownSender)
    #expect(try await offer(store, account, count: 1, chat: "bob@localhost", tag: "over") == 0)
    try await expectFinal(account, "\(account)-over0", placeholder: true)
    // Past the stranger ceiling a first-time stranger is not kept, while known senders still are.
    #expect(limits.perKnownSender >= limits.strangerCeiling)
    #expect(try await offer(store, "stranger@localhost", count: 1) == 0)
    try await expectFinal("stranger@localhost", "stranger@localhost-0", placeholder: true)
    // The account ceiling refuses even a known sender; a non-bubble only consumes its identity.
    var known = 0
    while try await store.pendingEncryptedIncoming(accountID: account).count < limits.perAccount {
        let sender = "known-\(known)@localhost"
        try await write(store, StoredMessage(id: "wrote-\(known)", accountID: account, chatID: sender, senderID: account, body: "Hi", isOutgoing: true))
        _ = try await offer(store, sender, count: min(limits.perKnownSender, limits.perAccount - (try await store.pendingEncryptedIncoming(accountID: account).count)))
        known += 1
    }
    let sender = "known-0@localhost"
    #expect(try await !store.retainEncryptedIncoming(accountID: account, sender: sender, digest: "update", wire: Data([1]),
                                                     overflow: overflow(sender, "update", bubble: false)))
    try await expectFinal(sender, "update", placeholder: false)
    // An approved device's copy meets the account ceiling too.
    #expect(try await offer(store, "retrying@localhost", count: 1, approved: true) == 0)
    try await expectFinal("retrying@localhost", "retrying@localhost-0", placeholder: true)
    #expect(try await store.pendingEncryptedIncoming(accountID: account).count == limits.perAccount)
    // Nothing refused alerted: every candidate is a kept row's review alert.
    let alerts = try await store.pendingNotifications(accountID: account, perChat: 64, total: 64).candidates
    #expect(!alerts.contains { if case .unreadable = $0.content { true } else { false } })
    try await store.close()
}

/// A quiet outcome stays quiet in the chat list too: a blocked device's or an over-limit placeholder never counts as
/// unread (so never raises the app badge), while a placeholder that alerts still does.
@Test func quietPlaceholdersDoNotCountAsUnread() async throws {
    let (store, directory) = try await limitStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = "peer@localhost"
    for (index, reason) in UnreadableReason.allCases.enumerated() {
        _ = try await store.recordUnreadableMessage(UnreadableMessage(accountID: account, chatID: peer, senderID: peer, isOutgoing: false,
            sentAt: Date(timeIntervalSince1970: 1_000 + Double(index)), reason: reason, key: .ciphertext(sender: peer, digest: "d\(index)")))
    }
    // Not for this device, unsupported, malformed and failed decrypt; not blocked device or retention limit.
    #expect(try await store.unreadCounts(accountID: account) == [peer: 4])
    try await store.close()
}
