import Foundation
import Testing
@testable import MessageStore

private func encryptedStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "messages.sqlite")
}

@Test func ciphertextAndRatchetCommitTogetherAndRetryPreservesExactBytes() async throws {
    let url = try encryptedStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: "a", chatID: "b", title: "B")
    try await store.enqueueOutgoing(StoredMessage(id: "m", accountID: "a", chatID: "b", senderID: "a", body: "private", isOutgoing: true, encryptionProfile: "pending"))
    try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await store.sealQueuedOutgoing(accountID: "a", messageID: "m", profile: "legacy", expectedRevision: 0, state: Data([2]), wire: Data([99]))
    }
    #expect(try await store.encryptedOutgoing(accountID: "a", messageID: "m") == nil)
    #expect(try await store.encryptionState(accountID: "a")?.data == Data([1]))
    try await store.sealQueuedOutgoing(accountID: "a", messageID: "m", profile: "legacy", expectedRevision: 1, state: Data([2]), wire: Data([99]))
    let attempt = try #require(await store.claimNextOutgoing(accountID: "a"))
    try await store.finishOutgoingSubmission(attempt)
    try await store.retryOutgoing(accountID: "a", messageID: "m")
    let reopened = try MessageStore(url: url)
    #expect(try await reopened.encryptedOutgoing(accountID: "a", messageID: "m") == Data([99]))
    #expect(try await reopened.encryptionState(accountID: "a")?.data == Data([2]))
    #expect(try await reopened.messages(accountID: "a", chatID: "b").first?.encryptionProfile == "legacy")
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await reopened.sealQueuedOutgoing(accountID: "a", messageID: "m", profile: "legacy", expectedRevision: 2, state: Data([3]), wire: Data([88]))
    }
    #expect(try await reopened.encryptionState(accountID: "a")?.revision == 2)
}

@Test func incomingRollbackRetainsCiphertextAndNeverConsumesRatchetWithoutMessage() async throws {
    let url = try encryptedStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
    try await store.retainEncryptedIncoming(accountID: "a", sender: "b", digest: "hash", wire: Data([99]))
    let invalid = StoredMessage(id: "", accountID: "a", chatID: "b", senderID: "b", body: "secret", encryptionProfile: "modern")
    await #expect(throws: MessageStoreError.self) {
        try await store.commitEncryptedIncoming(accountID: "a", sender: "b", digest: "hash", expectedRevision: 1, state: Data([2]), message: invalid)
    }
    #expect(try await store.encryptionState(accountID: "a")?.revision == 1)
    #expect(try await store.pendingEncryptedIncoming(accountID: "a").count == 1)
    #expect(try await !store.hasEncryptedIncoming(accountID: "a", sender: "b", digest: "hash"))
    let message = StoredMessage(id: "m", accountID: "a", chatID: "b", senderID: "b", body: "secret", encryptionProfile: "modern")
    try await store.commitEncryptedIncoming(accountID: "a", sender: "b", digest: "hash", expectedRevision: 1, state: Data([2]), message: message)
    #expect(try await store.pendingEncryptedIncoming(accountID: "a").isEmpty)
    #expect(try await store.messages(accountID: "a", chatID: "b").count == 1)
    #expect(try await !store.hasEncryptedIncoming(accountID: "c", sender: "b", digest: "hash"))
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await store.commitEncryptedIncoming(accountID: "a", sender: "b", digest: "hash", expectedRevision: 2, state: Data([3]), message: message)
    }
    #expect(try await store.encryptionState(accountID: "a")?.revision == 2)
}

@Test func separateOwnersCannotOverwriteAdvancedState() async throws {
    let url = try encryptedStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try MessageStore(url: url)
    let second = try MessageStore(url: url)
    try await first.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
    let stale = try #require(await second.encryptionState(accountID: "a"))
    try await first.saveEncryptionState(accountID: "a", expectedRevision: stale.revision, data: Data([2]))
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await second.saveEncryptionState(accountID: "a", expectedRevision: stale.revision, data: Data([3]))
    }
    #expect(try await second.encryptionState(accountID: "a")?.data == Data([2]))
}

@Test func senderClaimsOnlyFinitePreparedSetLeavingNewIntentQueued() async throws {
    let url = try encryptedStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: "a", chatID: "b", title: "B")
    for id in ["waiting-for-trust", "prepared", "new-during-drain"] {
        try await store.enqueueOutgoing(StoredMessage(id: id, accountID: "a", chatID: "b", senderID: "a", body: "private", isOutgoing: true, encryptionProfile: "pending"))
    }
    let claimed = try #require(await store.claimNextOutgoing(accountID: "a", messageIDs: ["prepared"]))
    #expect(claimed.message.id == "prepared")
    #expect(try await store.claimNextOutgoing(accountID: "a", messageIDs: ["prepared"]) == nil)
    #expect(try await store.claimNextOutgoing(accountID: "a", messageIDs: []) == nil)
    let waiting = try await store.queuedOutgoing(accountID: "a")
    #expect(waiting.map(\.id) == ["waiting-for-trust", "new-during-drain"])
    #expect(waiting.allSatisfy { $0.transportState == .queued })
}
