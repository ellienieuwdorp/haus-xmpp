import Foundation
import Testing
@testable import MessageStore

private func notificationFixture(_ operation: (MessageStore, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "messages.sqlite")
    let store = try MessageStore(url: url)
    do {
        try await store.acquireTransportOwnership()
        try await operation(store, url)
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    } catch {
        try? await store.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private func incoming(_ id: String, account: String = "a") -> StoredMessage {
    StoredMessage(id: id, accountID: account, chatID: "peer", senderID: "peer",
                  body: "Synthetic notification", encryptionProfile: "modern")
}

@Test func plaintextAndControlsQueueNoNotificationAndDismissClearsPending() async throws {
    try await notificationFixture { store, _ in
        try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
        try await store.insertMessage(StoredMessage(id: "plain", accountID: "a", chatID: "peer", senderID: "peer", body: "Untrusted"))
        try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "control",
            expectedRevision: 1, state: Data([2]), message: nil)
        #expect(try await store.takeMessageNotification(accountID: "a").messageCount == 0)
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "message",
            expectedRevision: 2, state: Data([3]), message: incoming("encrypted"))
        try await store.dismissPendingMessageNotifications(accountID: "a")
        #expect(try await store.takeMessageNotification(accountID: "a").messageCount == 0)
    }
}

@Test func notificationPrivacyAndClaimsAreAccountAndOwnerScoped() async throws {
    try await notificationFixture { store, url in
        for account in ["a", "b"] {
            try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
            try await store.commitEncryptedIncoming(accountID: account, sender: "peer", digest: "message",
                expectedRevision: 1, state: Data([2]), message: incoming("message", account: account))
        }
        try await store.setNotificationPreviews(accountID: "a", enabled: false)
        let nonowner = try MessageStore(url: url)
        await #expect(throws: MessageStoreError.transportOwnershipRequired) {
            try await nonowner.setNotificationPreviews(accountID: "a", enabled: true)
        }
        #expect(try await store.notificationPreviewsEnabled(accountID: "a") == false)
        await #expect(throws: MessageStoreError.transportOwnershipRequired) {
            try await nonowner.takeMessageNotification(accountID: "a")
        }
        try await nonowner.close()
        let first = try await store.takeMessageNotification(accountID: "a")
        #expect(!first.previewsEnabled && first.messageCount == 1)
        #expect(try await store.takeMessageNotification(accountID: "a").messageCount == 0)
        let second = try await store.takeMessageNotification(accountID: "b")
        #expect(second.previewsEnabled && second.messageCount == 1)
    }
}
