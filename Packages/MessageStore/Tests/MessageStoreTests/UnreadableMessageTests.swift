import Foundation
import Testing
import Darwin
import CSQLite
@testable import MessageStore

private func unreadableStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "messages.sqlite")
}

private func sqliteRows(_ url: URL, _ sql: String) -> [[String]] {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var rows: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
        })
    }
    return rows
}

private let account = "alice@localhost"
private let peer = "bob@localhost"

private func placeholder(_ key: UnreadableMessage.Key, reason: UnreadableReason = .notForThisDevice, outgoing: Bool = false,
                         chat: String = peer, sentAt: Date = Date(timeIntervalSince1970: 1_000)) -> UnreadableMessage {
    UnreadableMessage(accountID: account, chatID: chat, senderID: outgoing ? account : chat, isOutgoing: outgoing,
                      sentAt: sentAt, reason: reason, key: key)
}

@Test func schemaV15AddsColumnsOnceAndKeepsTheCeiling() async throws {
    let url = try unreadableStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await MessageStore(url: url).close()
    // Recreate the v14 shape: neither column, one retained row written before the migration.
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, """
        ALTER TABLE messages DROP COLUMN unreadable_reason;
        ALTER TABLE pending_encrypted_inbox DROP COLUMN reason;
        INSERT INTO pending_encrypted_inbox(account_id,sender,digest,wire) VALUES('\(account)','\(peer)','d',X'01');
        PRAGMA user_version=14;
        """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    #expect(sqliteRows(url, "SELECT name FROM pragma_table_info('messages') WHERE name='unreadable_reason'").isEmpty)

    let migrated = try MessageStore(url: url)
    #expect(try await migrated.pendingEncryptedIncoming(accountID: account).map(\.reason) == [.trustPending])
    try await migrated.close()
    #expect(sqliteRows(url, "SELECT name FROM pragma_table_info('messages') WHERE name='unreadable_reason'") == [["unreadable_reason"]])
    #expect(sqliteRows(url, "SELECT dflt_value,\"notnull\" FROM pragma_table_info('pending_encrypted_inbox') WHERE name='reason'") == [["'trustPending'", "1"]])
    #expect(sqliteRows(url, "PRAGMA user_version") == [["20"]])

    // Reopening is idempotent: no second ALTER, same version.
    try await MessageStore(url: url).close()
    #expect(sqliteRows(url, "SELECT COUNT(*) FROM pragma_table_info('messages') WHERE name='unreadable_reason'") == [["1"]])
    #expect(sqliteRows(url, "PRAGMA user_version") == [["20"]])

    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "PRAGMA user_version=21;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    #expect(throws: MessageStoreError.unsupportedSchema(21)) { _ = try MessageStore(url: url) }
}

@Test func placeholderIsDeterministicIdempotentAndOrderedByStamp() async throws {
    let url = try unreadableStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    let first = placeholder(.ciphertext(sender: peer, digest: "abc"), sentAt: Date(timeIntervalSince1970: 2_000))
    #expect(first.id.hasPrefix("unreadable-") && first.id.count == "unreadable-".count + 64)
    #expect(first.id == placeholder(.ciphertext(sender: peer, digest: "abc")).id)
    #expect(try await store.recordUnreadableMessage(first))
    // A later sighting (for example the archive copy with an older stamp) never rewrites the row.
    #expect(try await !store.recordUnreadableMessage(placeholder(.ciphertext(sender: peer, digest: "abc"), sentAt: Date(timeIntervalSince1970: 500))))
    var rows = try await store.messages(accountID: account, chatID: peer)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == first.id && row.sentAt == Date(timeIntervalSince1970: 2_000) && row.body == "")
    #expect(row.encryptionProfile == "unreadable" && row.unreadableReason == .notForThisDevice)
    #expect(row.wireID == nil && !row.wireIDAuthenticated && !row.isOutgoing && row.senderID == peer && !row.isStarred)

    let archived = placeholder(.archive(archive: account, id: "archive-7"), reason: .malformedContent, outgoing: true,
                               sentAt: Date(timeIntervalSince1970: 1_500))
    #expect(archived.id != first.id)
    // Domain separation: the same strings under the other key kind never collide.
    #expect(placeholder(.archive(archive: peer, id: "abc")).id != first.id)
    #expect(try await store.recordUnreadableMessage(archived))
    #expect(try await !store.recordUnreadableMessage(archived))
    rows = try await store.messages(accountID: account, chatID: peer)
    #expect(rows.map(\.id) == [archived.id, first.id])
    let decoded = try #require(await store.message(accountID: account, messageID: archived.id))
    #expect(decoded.unreadableReason == .malformedContent && decoded.isOutgoing && decoded.senderID == account)
    #expect(try await store.hasUnreadableMessage(accountID: account, id: archived.id))
    #expect(try await !store.hasUnreadableMessage(accountID: account, id: "unreadable-missing"))
    // An archive-keyed placeholder consumes no ciphertext identity.
    #expect(try await !store.hasEncryptedIncoming(accountID: account, sender: peer, digest: "archive-7"))

    await #expect(throws: MessageStoreError.invalidValue) { try await store.recordUnreadableMessage(placeholder(.ciphertext(sender: peer, digest: ""))) }
    await #expect(throws: MessageStoreError.invalidValue) { try await store.recordUnreadableMessage(placeholder(.ciphertext(sender: peer, digest: String(repeating: "a", count: 129)))) }
    await #expect(throws: MessageStoreError.invalidValue) { try await store.recordUnreadableMessage(placeholder(.archive(archive: account, id: ""))) }
    await #expect(throws: MessageStoreError.invalidValue) { try await store.recordUnreadableMessage(placeholder(.archive(archive: account, id: "x"), chat: "bob @localhost")) }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.recordUnreadableMessage(placeholder(.archive(archive: account, id: "y"), sentAt: Date(timeIntervalSince1970: .infinity)))
    }
}

@Test func placeholderConsumesCiphertextIdentityAndClearsPendingRow() async throws {
    let url = try unreadableStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
    try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "d1", wire: Data([9]), reason: .trustPending)
    #expect(try await store.recordUnreadableMessage(placeholder(.ciphertext(sender: peer, digest: "d1"), reason: .decryptFailed)))
    #expect(try await store.pendingEncryptedIncoming(accountID: account).isEmpty)
    #expect(try await store.hasEncryptedIncoming(accountID: account, sender: peer, digest: "d1"))
    // The ciphertext was declared unreadable; it can never be re-decided as content.
    let late = StoredMessage(id: "late", accountID: account, chatID: peer, senderID: peer, body: "x", encryptionProfile: "legacy")
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await store.commitEncryptedIncoming(accountID: account, sender: peer, digest: "d1", expectedRevision: 1, state: Data([2]), message: late)
    }
    #expect(try await store.encryptionState(accountID: account)?.revision == 1)

    // Authenticated first: a placeholder for the same digest is refused without writing anything.
    let real = StoredMessage(id: "real", accountID: account, chatID: peer, senderID: peer, body: "hello", encryptionProfile: "legacy")
    try await store.commitEncryptedIncoming(accountID: account, sender: peer, digest: "d2", expectedRevision: 1, state: Data([2]), message: real)
    #expect(try await !store.recordUnreadableMessage(placeholder(.ciphertext(sender: peer, digest: "d2"))))
    let rows = try await store.messages(accountID: account, chatID: peer)
    #expect(rows.count == 2 && rows.filter { $0.unreadableReason != nil }.count == 1)
    #expect(try await !store.hasUnreadableMessage(accountID: account, id: placeholder(.ciphertext(sender: peer, digest: "d2")).id))
}

@Test func placeholderIsNeverAReactionTargetOrEventHolderButAlertsAsUnreadable() async throws {
    let url = try unreadableStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    let incoming = placeholder(.ciphertext(sender: peer, digest: "d"), reason: .decryptFailed)
    #expect(try await store.recordUnreadableMessage(incoming))
    let id = incoming.id
    #expect(try await store.reactionTarget(accountID: account, chatID: peer, wireID: id) == nil)
    #expect(try await store.events(accountID: account, chatID: peer, messageID: id).isEmpty)
    #expect(try await store.eventsForChat(accountID: account, chatID: peer, messageIDs: [id])[id] == nil)
    #expect(try await store.reactionReference(accountID: account, messageID: id) == nil)
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.enqueueReaction(StoredReactionUpdate(id: "r", accountID: account, chatID: peer, targetMessageID: id, targetWireID: id,
                                                             actorID: account, reactions: ["👍"]))
    }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.enqueueReceipt(accountID: account, chatID: peer, targetMessageID: id, kind: .receipt)
    }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.enqueueReceipt(accountID: account, chatID: peer, targetMessageID: id, kind: .marker)
    }
    // Plan D5: an incoming placeholder alerts as unreadable, never with content, and never as a reaction or receipt target.
    let notification = try await store.pendingNotifications(accountID: account)
    #expect(notification.candidates.map(\.content) == [.unreadable(messageID: id)])
    #expect(notification.claimed == [.message(id)])

    try await store.upsertChat(accountID: account, chatID: peer, title: "Bob")
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.insertMessage(StoredMessage(id: "unreadable-forged", accountID: account, chatID: peer, senderID: peer, body: "x"))
    }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.insertMessage(StoredMessage(id: "m", accountID: account, chatID: peer, senderID: peer, body: "", encryptionProfile: "unreadable"))
    }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.insertMessage(StoredMessage(id: "m2", accountID: account, chatID: peer, senderID: peer, body: "x", unreadableReason: .decryptFailed))
    }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.enqueueOutgoing(StoredMessage(id: "unreadable-out", accountID: account, chatID: peer, senderID: account, body: "x", isOutgoing: true))
    }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.enqueueOutgoing(StoredMessage(id: "out", accountID: account, chatID: peer, senderID: account, body: "x", isOutgoing: true, encryptionProfile: "unreadable"))
    }
    #expect(try await store.messages(accountID: account, chatID: peer).map(\.id) == [id])
}

@Test func placeholderBecomesChatPreviewWithoutStarringOrSearch() async throws {
    let url = try unreadableStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: account, chatID: peer, title: "Bob")
    try await store.insertMessage(StoredMessage(id: "older", accountID: account, chatID: peer, senderID: peer, body: "unreadable couldn't",
                                                sentAt: Date(timeIntervalSince1970: 100)))
    let later = placeholder(.archive(archive: account, id: "a1"), outgoing: true, sentAt: Date(timeIntervalSince1970: 200))
    try await store.recordUnreadableMessage(later)
    let chat = try #require(await store.chats(accountID: account).first)
    #expect(chat.lastMessage?.id == later.id && chat.lastMessage?.unreadableReason == .notForThisDevice)
    #expect(chat.lastMessage?.isStarred == false && chat.lastMessageReceipt == nil)
    #expect(try await store.search(accountID: account, query: "").isEmpty)
    for term in ["unreadable", "couldn", "not", "device", "a"] {
        #expect(try await !store.search(accountID: account, query: term).contains { $0.unreadableReason != nil })
    }
}

@Test func archiveRejectionWhitelistAndPlaceholderCommitTogether() async throws {
    let url = try unreadableStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    for (index, reason) in ["unverifiableEncryptedGroup", "foreignSender", "unsupportedDirectContent", "malformedEncryptedContent"].enumerated() {
        try await store.recordArchiveRejection(accountID: account, archiveID: account, messageID: "r\(index)", reason: reason)
        #expect(try await store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "r\(index)"))
    }
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.recordArchiveRejection(accountID: account, archiveID: account, messageID: "u", reason: "somethingElse")
    }
    #expect(try await !store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "u"))

    let withRow = placeholder(.archive(archive: account, id: "p1"), reason: .unsupportedEncryption)
    try await store.recordArchiveRejection(accountID: account, archiveID: account, messageID: "p1", reason: "unsupportedDirectContent", placeholder: withRow)
    #expect(try await store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "p1"))
    #expect(try await store.hasUnreadableMessage(accountID: account, id: withRow.id))
    // Repeating the page is harmless: both inserts are idempotent.
    try await store.recordArchiveRejection(accountID: account, archiveID: account, messageID: "p1", reason: "unsupportedDirectContent", placeholder: withRow)
    #expect(try await store.messages(accountID: account, chatID: peer).count == 1)

    let invalid = UnreadableMessage(accountID: account, chatID: "", senderID: peer, isOutgoing: false, sentAt: Date(), reason: .malformedContent,
                                    key: .archive(archive: account, id: "p2"))
    await #expect(throws: MessageStoreError.invalidValue) {
        try await store.recordArchiveRejection(accountID: account, archiveID: account, messageID: "p2", reason: "malformedEncryptedContent", placeholder: invalid)
    }
    #expect(try await !store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "p2"))
    #expect(try await !store.hasUnreadableMessage(accountID: account, id: invalid.id))

    // The 1,000-row trim still runs after a placeholder insert.
    for index in 0..<1_000 {
        try await store.recordArchiveRejection(accountID: account, archiveID: account, messageID: "bulk\(index)", reason: "foreignSender")
    }
    let last = placeholder(.archive(archive: account, id: "p3"), reason: .malformedContent)
    try await store.recordArchiveRejection(accountID: account, archiveID: account, messageID: "p3", reason: "malformedEncryptedContent", placeholder: last)
    #expect(try await !store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "p1"))
    #expect(try await !store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "bulk0"))
    #expect(try await store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "p3"))
    #expect(sqliteRows(url, "SELECT COUNT(*) FROM archive_rejections") == [["1000"]])
    // Trimming receipts never removes placeholder rows.
    #expect(try await store.hasUnreadableMessage(accountID: account, id: withRow.id))
}

@Test func pendingReasonsAreStoredClassifiedAndFilterable() async throws {
    let url = try unreadableStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "k", wire: Data([1]), reason: .keysPending)
    try await store.retainEncryptedIncoming(accountID: account, sender: "carol@localhost", digest: "t", wire: Data([2]))
    #expect(try await store.pendingEncryptedIncoming(accountID: account).map(\.reason) == [.keysPending, .trustPending])
    #expect(try await store.pendingEncryptedIncoming(accountID: account, reasons: [.keysPending]).map(\.digest) == ["k"])
    #expect(try await store.pendingEncryptedIncoming(accountID: account, reasons: []).isEmpty)
    #expect(try await store.pendingEncryptedIncoming(accountID: account, reasons: [.trustPending, .keysPending]).count == 2)
    #expect(try await store.pendingEncryptedIncoming(accountID: account, sender: "carol@localhost").map(\.digest) == ["t"])
    #expect(try await store.pendingEncryptedIncoming(accountID: account, reasons: [.keysPending], sender: "carol@localhost").isEmpty)
    // Re-retaining never changes an existing classification.
    try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "k", wire: Data([1]), reason: .trustPending)
    #expect(try await store.pendingEncryptedIncoming(accountID: account, sender: peer).map(\.reason) == [.keysPending])
    try await store.classifyPendingEncryptedIncoming(accountID: account, sender: peer, digest: "k", reason: .trustPending)
    #expect(try await store.pendingEncryptedIncoming(accountID: account, reasons: [.keysPending]).isEmpty)
    #expect(try await store.pendingEncryptedIncoming(accountID: account, reasons: [.trustPending]).count == 2)
    try await store.classifyPendingEncryptedIncoming(accountID: account, sender: peer, digest: "missing", reason: .keysPending)
    #expect(try await store.pendingEncryptedIncoming(accountID: account).count == 2)
}

@Test func undecryptableKeyTransportConsumesIdentityWithoutARow() async throws {
    let url = try unreadableStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "kt", wire: Data([1]))
    try await store.consumeUndecryptableIncoming(accountID: account, sender: peer, digest: "kt")
    try await store.consumeUndecryptableIncoming(accountID: account, sender: peer, digest: "kt")
    #expect(try await store.pendingEncryptedIncoming(accountID: account).isEmpty)
    #expect(try await store.hasEncryptedIncoming(accountID: account, sender: peer, digest: "kt"))
    #expect(try await store.messages(accountID: account, chatID: peer).isEmpty)
    #expect(try await store.chats(accountID: account).isEmpty)
    await #expect(throws: MessageStoreError.invalidValue) { try await store.consumeUndecryptableIncoming(accountID: account, sender: peer, digest: "") }
}
