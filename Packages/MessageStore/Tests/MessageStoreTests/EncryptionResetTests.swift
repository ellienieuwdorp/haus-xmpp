import Foundation
import Testing
@testable import MessageStore

/// `resetEncryption`: what starting encryption over after a lost wrapping key discards, keeps and creates
/// (docs/development/key-recovery.md).
struct EncryptionResetTests {
    private let account = "alice@localhost"
    private let peer = "bob@localhost"

    private func placeholder(_ digest: String, sender: String? = nil) -> UnreadableMessage {
        UnreadableMessage(accountID: account, chatID: peer, senderID: sender ?? peer, isOutgoing: false,
                          sentAt: Date(timeIntervalSince1970: 1_000), reason: .encryptionReset, key: .ciphertext(sender: sender ?? peer, digest: digest))
    }

    private func photo(_ id: String) -> StoredMessage {
        StoredMessage(id: id, accountID: account, chatID: peer, senderID: account, body: "", sentAt: Date(timeIntervalSince1970: 900), isOutgoing: true,
                      attachment: StoredAttachment(name: "beach.jpg", mediaType: "image/jpeg", size: 1, width: nil, height: nil,
                                                   hash: String(repeating: "0", count: 64), secret: Data([1]), uploadState: .pending))
    }

    @Test func resetRetiresTheOldDeviceDecidesRetainedCiphertextAndWritesTheNewIdentity() async throws {
        try await withEncryptedStore(account: account, chats: [(peer, "Bob"), ("carol@localhost", "Carol")]) { store, url in
            try await store.recordEncryptionDeviceID(accountID: account, deviceID: 111)
            _ = try await store.insertMessage(StoredMessage(id: "kept", accountID: account, chatID: peer, senderID: peer, body: "Hello", isOutgoing: false))
            try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "bubble", wire: Data([1]),
                                                    notification: PendingNotificationContext(chatID: peer, sentAt: Date(timeIntervalSince1970: 1_000)))
            try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "transport", wire: Data([2]))
            #expect(try await store.enqueueOutgoing(photo("photo")))
            #expect(try await store.enqueueOutgoing(StoredMessage(id: "text", accountID: account, chatID: "carol@localhost", senderID: account, body: "Hi", isOutgoing: true)))
            #expect(try await store.encryptionLossCounts(accountID: account) == EncryptionLossCounts(waitingMessages: 2, unsendableFiles: 1))

            try await store.resetEncryption(EncryptionReset(
                discarded: [.init(accountID: account, revision: 1, placeholders: [placeholder("bubble")], consumed: [CiphertextIdentity(sender: peer, digest: "transport")])],
                replacement: .init(accountID: account, deviceID: 222, data: Data([9]))))

            let state = try #require(await store.encryptionState(accountID: account))
            #expect(state.data == Data([9]) && state.deviceID == 222)
            // Above the discarded row's revision, never a revision the old state was read at.
            #expect(state.revision == 2)
            #expect(try await store.retiredOwnDevices(accountID: account, profile: "legacy") == [111])
            #expect(try await store.retiredOwnDevices(accountID: account, profile: "modern") == [111])
            #expect(try await store.pendingEncryptedIncoming(accountID: account).isEmpty)
            // Both identities are consumed: the ciphertext arriving again (archive, resumed stream) never retains anew.
            #expect(try await store.hasEncryptedIncoming(accountID: account, sender: peer, digest: "bubble"))
            #expect(try await store.hasEncryptedIncoming(accountID: account, sender: peer, digest: "transport"))
            let messages = try await store.messages(accountID: account, chatID: peer)
            #expect(messages.map(\.id).contains("kept"))
            #expect(messages.contains { $0.unreadableReason == .encryptionReset && $0.id == placeholder("bubble").id })
            // The placeholder neither alerts nor counts as unread; the old review candidate went with its row.
            #expect(sqliteRows(url: url, sql: "SELECT COUNT(*) FROM notification_candidates") == [["0"]])
            #expect(sqliteRows(url: url, sql: "SELECT COUNT(*) FROM pending_notification_candidates") == [["0"]])
            #expect(try await store.unreadCounts(accountID: account)[peer] == 1) // "kept" only
            #expect(try await store.encryptionLossCounts(accountID: account) == EncryptionLossCounts(waitingMessages: 0, unsendableFiles: 0))
            #expect(sqliteRows(url: url, sql: "SELECT message_id,state,rejection FROM outbox ORDER BY sequence")
                    == [["photo", "failed", MessageStore.encryptionResetRejection], ["text", "queued", "NULL"]])
        }
    }

    /// The failed file's key material is still sealed with the lost key: queued again it could never be sealed and
    /// would sit in the outbox for good, so retry refuses it. A file failed for any other reason can still be retried.
    @Test func aFileFailedByTheResetCannotBeQueuedAgain() async throws {
        try await withEncryptedStore(account: account, chats: [(peer, "Bob")]) { store, url in
            #expect(try await store.enqueueOutgoing(photo("photo")))
            try await store.resetEncryption(EncryptionReset(discarded: [.init(accountID: account, revision: 1, placeholders: [], consumed: [])], replacement: nil))
            await #expect(throws: MessageStoreError.invalidTransition) { try await store.retryOutgoing(accountID: account, messageID: "photo") }
            #expect(sqliteRows(url: url, sql: "SELECT state,rejection FROM outbox") == [["failed", MessageStore.encryptionResetRejection]])
            #expect(try await store.message(accountID: account, messageID: "photo")?.rejection == MessageStore.encryptionResetRejection)

            #expect(try await store.enqueueOutgoing(photo("other")))
            #expect(sqliteExecute(url: url, sql: "UPDATE outbox SET state='failed' WHERE message_id='other'"))
            try await store.retryOutgoing(accountID: account, messageID: "other")
            #expect(sqliteRows(url: url, sql: "SELECT state FROM outbox WHERE message_id='other'") == [["queued"]])
        }
    }

    @Test func resetChangesNothingWhenTheRowMovedOnOrTheNewIDWasUsedBefore() async throws {
        try await withEncryptedStore(account: account, chats: [(peer, "Bob")]) { store, _ in
            try await store.recordEncryptionDeviceID(accountID: account, deviceID: 111)
            try await store.retainEncryptedIncoming(accountID: account, sender: peer, digest: "bubble", wire: Data([1]))
            let before = try await store.encryptionState(accountID: account)
            // Assessed at revision 1, but another write landed since.
            try await store.saveEncryptionState(accountID: account, expectedRevision: 1, data: Data([5]))
            await #expect(throws: MessageStoreError.invalidTransition) {
                try await store.resetEncryption(EncryptionReset(discarded: [.init(accountID: account, revision: 1, placeholders: [placeholder("bubble")], consumed: [])],
                                                                replacement: nil))
            }
            #expect(try await store.encryptionState(accountID: account)?.revision == 2)
            // The new identity may not reuse the discarded device ID: the whole transaction rolls back.
            await #expect(throws: MessageStoreError.invalidTransition) {
                try await store.resetEncryption(EncryptionReset(discarded: [.init(accountID: account, revision: 2, placeholders: [placeholder("bubble")], consumed: [])],
                                                                replacement: .init(accountID: account, deviceID: 111, data: Data([9]))))
            }
            let after = try #require(await store.encryptionState(accountID: account))
            #expect(after.revision == 2 && after.data == Data([5]) && after.deviceID == before?.deviceID)
            #expect(try await store.retiredOwnDevices(accountID: account).isEmpty)
            #expect(try await store.pendingEncryptedIncoming(accountID: account).count == 1)
            // A retained row left undecided would stay undecryptable forever: refused.
            await #expect(throws: MessageStoreError.invalidTransition) {
                try await store.resetEncryption(EncryptionReset(discarded: [.init(accountID: account, revision: 2, placeholders: [], consumed: [])], replacement: nil))
            }
            #expect(try await store.encryptionState(accountID: account) != nil)
        }
    }

    @Test func resetNeedsTheLeaseAndOnlyTouchesTheAccountsItNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([0]))
        try await store.saveEncryptionState(accountID: "other@localhost", expectedRevision: nil, data: Data([7]))
        try await store.recordEncryptionDeviceID(accountID: "other@localhost", deviceID: 333)
        let reset = EncryptionReset(discarded: [.init(accountID: account, revision: 1, placeholders: [], consumed: [])], replacement: nil)
        await #expect(throws: MessageStoreError.transportOwnershipRequired) { try await store.resetEncryption(reset) }
        try await store.acquireTransportOwnership()
        try await store.resetEncryption(reset)
        #expect(try await store.encryptionState(accountID: account) == nil)
        // A row without a recorded device ID retires nothing; the other account keeps its state and ID.
        #expect(try await store.retiredOwnDevices(accountID: account).isEmpty)
        #expect(try await store.encryptionState(accountID: "other@localhost") == EncryptionState(revision: 1, data: Data([7]), deviceID: 333))
        #expect(try await store.retiredOwnDevices(accountID: "other@localhost").isEmpty)
        try await store.close()
    }

    @Test func aRecordedDeviceIDIsNeverRelabelled() async throws {
        try await withEncryptedStore(account: account) { store, _ in
            try await store.recordEncryptionDeviceID(accountID: account, deviceID: 111)
            try await store.recordEncryptionDeviceID(accountID: account, deviceID: 111)
            await #expect(throws: MessageStoreError.conflictingIdentity) { try await store.recordEncryptionDeviceID(accountID: account, deviceID: 112) }
            #expect(try await store.encryptionState(accountID: account)?.deviceID == 111)
            // A later save of the state keeps the recorded ID.
            try await store.saveEncryptionState(accountID: account, expectedRevision: 1, data: Data([4]))
            #expect(try await store.encryptionState(accountID: account)?.deviceID == 111)

            try await store.resetEncryption(EncryptionReset(discarded: [.init(accountID: account, revision: 2, placeholders: [], consumed: [])], replacement: nil))
            #expect(try await store.retiredOwnDevices(accountID: account) == [111])
        }
    }
}
