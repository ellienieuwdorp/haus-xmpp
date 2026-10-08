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
    try await store.acquireTransportOwnership()
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
    try await store.acquireTransportOwnership()
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

@Test func senderClaimsOnlyFinitePreparedSetLeavingNewIntentQueued() async throws {
    let url = try encryptedStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
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

@Test func pendingRowLookupIsScopedByAccountSenderAndDigest() async throws {
    let url = try encryptedStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
    try await store.retainEncryptedIncoming(accountID: "a", sender: "peer", digest: "d", wire: Data([7, 8]), reason: .keysPending)
    let found = try #require(await store.pendingEncryptedIncoming(accountID: "a", sender: "peer", digest: "d"))
    #expect(found.wire == Data([7, 8]))
    #expect(found.reason == .keysPending)
    #expect(found.sender == "peer" && found.digest == "d")
    #expect(try await store.pendingEncryptedIncoming(accountID: "b", sender: "peer", digest: "d") == nil)
    #expect(try await store.pendingEncryptedIncoming(accountID: "a", sender: "other", digest: "d") == nil)
    #expect(try await store.pendingEncryptedIncoming(accountID: "a", sender: "peer", digest: "e") == nil)
    let message = StoredMessage(id: "m", accountID: "a", chatID: "peer", senderID: "peer", body: "secret", encryptionProfile: "modern")
    try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "d", expectedRevision: 1, state: Data([2]), message: message)
    #expect(try await store.pendingEncryptedIncoming(accountID: "a", sender: "peer", digest: "d") == nil)
}

@Test func pendingSummariesProjectEnvelopeFieldsWithoutTheWire() async throws {
    let url = try encryptedStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    let direct = Data(#"{"from":"alice@localhost/phone","provenance":"receivedCarbon","envelope":{"profile":"modern"},"sentAt":1}"#.utf8)
    let sent = Data(#"{"from":"a@localhost/x","to":"carol@localhost","provenance":"sentCarbon"}"#.utf8)
    let group = Data(#"{"message":{"room":"r@conference.localhost","sender":"carol@localhost"},"sentAt":1}"#.utf8)
    let nested = Data(#"{"from":{"not":"a string"},"to":42}"#.utf8)
    try await store.retainEncryptedIncoming(accountID: "a", sender: "alice@localhost", digest: "1", wire: direct)
    try await store.retainEncryptedIncoming(accountID: "a", sender: "a@localhost", digest: "2", wire: sent, reason: .keysPending)
    try await store.retainEncryptedIncoming(accountID: "a", sender: "carol@localhost", digest: "3", wire: group)
    try await store.retainEncryptedIncoming(accountID: "a", sender: "x@localhost", digest: "4", wire: Data([1]))
    try await store.retainEncryptedIncoming(accountID: "a", sender: "y@localhost", digest: "5", wire: nested)
    try await store.retainEncryptedIncoming(accountID: "other", sender: "alice@localhost", digest: "1", wire: direct)
    let summaries = try await store.pendingEncryptedIncomingSummaries(accountID: "a")
    #expect(summaries == [
        PendingEncryptedSummary(sender: "alice@localhost", digest: "1", reason: "trustPending", room: nil, roomSender: nil,
                                from: "alice@localhost/phone", to: nil, provenance: "receivedCarbon"),
        PendingEncryptedSummary(sender: "a@localhost", digest: "2", reason: "keysPending", room: nil, roomSender: nil,
                                from: "a@localhost/x", to: "carol@localhost", provenance: "sentCarbon"),
        PendingEncryptedSummary(sender: "carol@localhost", digest: "3", reason: "trustPending", room: "r@conference.localhost",
                                roomSender: "carol@localhost", from: nil, to: nil, provenance: nil),
        // Not JSON at all: every projected field is nil rather than an error.
        PendingEncryptedSummary(sender: "x@localhost", digest: "4", reason: "trustPending", room: nil, roomSender: nil,
                                from: nil, to: nil, provenance: nil),
        // JSON, but the fields are not strings: never coerced into an address.
        PendingEncryptedSummary(sender: "y@localhost", digest: "5", reason: "trustPending", room: nil, roomSender: nil,
                                from: nil, to: nil, provenance: nil),
    ])
    #expect(try await store.pendingEncryptedIncomingSummaries(accountID: "nobody").isEmpty)
}

@Test func sealingCanClearAReplyTheSealedContentLeftOut() async throws {
    let url = try encryptedStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.upsertChat(accountID: "a", chatID: "b", title: "B")
    let reply = MessageReply(messageID: "earlier", senderID: "a", body: "Ten it is", wireID: "earlier")
    for id in ["kept", "dropped"] {
        try await store.enqueueOutgoing(StoredMessage(id: id, accountID: "a", chatID: "b", senderID: "a", body: "ok", isOutgoing: true,
                                                      reply: reply, encryptionProfile: "pending"))
    }
    try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
    try await store.sealQueuedOutgoing(accountID: "a", messageID: "kept", profile: "modern", expectedRevision: 1, state: Data([2]), wire: Data([1]))
    try await store.sealQueuedOutgoing(accountID: "a", messageID: "dropped", profile: "legacy", expectedRevision: 2, state: Data([3]), wire: Data([2]), clearReply: true)
    let messages = try await store.messages(accountID: "a", chatID: "b")
    #expect(messages.first { $0.id == "kept" }?.reply == reply)
    #expect(messages.first { $0.id == "dropped" }?.reply == nil)
    #expect(messages.first { $0.id == "dropped" }?.encryptionProfile == "legacy")
}
