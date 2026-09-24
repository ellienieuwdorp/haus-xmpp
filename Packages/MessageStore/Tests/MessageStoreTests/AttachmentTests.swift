import Foundation
import Testing
@testable import MessageStore

private func fixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("messages.sqlite")
}
private func photo(state: StoredAttachment.UploadState? = .pending) -> StoredAttachment {
    StoredAttachment(name: "beach.jpg", mediaType: "image/jpeg", size: 1234, width: 800, height: 600, hash: "ab" + String(repeating: "0", count: 62),
                     secret: Data([1, 2, 3]), uploadState: state)
}
private func media(_ id: String, body: String = "", attachment: StoredAttachment? = photo()) -> StoredMessage {
    StoredMessage(id: id, accountID: "a", chatID: "peer", senderID: "a", body: body, sentAt: Date(timeIntervalSince1970: 100), isOutgoing: true, attachment: attachment)
}

@Test func queuedFileMessageIsNotSendableUntilUploaded() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var store: MessageStore? = try MessageStore(url: url)
    try await store!.acquireTransportOwnership()
    try await store!.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    await #expect(throws: MessageStoreError.self) { try await store!.enqueueOutgoing(media("no-body-no-file", attachment: nil)) }
    await #expect(throws: MessageStoreError.self) { try await store!.enqueueOutgoing(media("inbound-state", attachment: photo(state: nil))) }
    try await store!.upsertChat(accountID: "a", chatID: "other", title: "Other")
    #expect(try await store!.enqueueOutgoing(media("photo")))
    #expect(try await store!.enqueueOutgoing(media("caption", body: "hello", attachment: nil)))
    #expect(try await store!.enqueueOutgoing(StoredMessage(id: "elsewhere", accountID: "a", chatID: "other", senderID: "a", body: "hi", isOutgoing: true)))
    // The caption stays behind the file it follows; another chat is not starved.
    #expect(try await store!.queuedOutgoing(accountID: "a").map(\.id) == ["elsewhere"])
    #expect(try await store!.attachmentsAwaitingUpload(accountID: "a").map(\.id) == ["photo"])
    #expect(try await store!.claimNextOutgoing(accountID: "a")?.message.id == "elsewhere")
    #expect(try await store!.claimNextOutgoing(accountID: "a") == nil)
    // Without a slot there is nothing to mark: the file stays pending.
    try await store!.markAttachmentUploaded(accountID: "a", messageID: "photo")
    #expect(try await store!.attachmentsAwaitingUpload(accountID: "a").count == 1)
    try await store!.setAttachmentUploadTask(accountID: "a", messageID: "photo", taskID: 7, url: "https://u/x")
    store = nil
    // A relaunch sees the same pending file and its task, never a half-sent message.
    let reopened = try MessageStore(url: url)
    try await reopened.acquireTransportOwnership()
    let pending = try #require(await reopened.attachmentsAwaitingUpload(accountID: "a").first)
    #expect(pending.attachment?.uploadTaskID == 7 && pending.attachment?.uploadState == .pending && pending.attachment?.url == "https://u/x")
    #expect(try await reopened.claimNextOutgoing(accountID: "a") == nil)
    try await reopened.markAttachmentUploaded(accountID: "a", messageID: "photo")
    #expect(try await reopened.attachmentsAwaitingUpload(accountID: "a").isEmpty)
    #expect(try await reopened.queuedOutgoing(accountID: "a").map(\.id) == ["photo", "caption"])
    let claimed = try #require(await reopened.claimNextOutgoing(accountID: "a"))
    #expect(claimed.message.id == "photo")
    #expect(claimed.message.attachment == StoredAttachment(name: "beach.jpg", mediaType: "image/jpeg", size: 1234, width: 800, height: 600,
                                                           hash: "ab" + String(repeating: "0", count: 62), secret: Data([1, 2, 3]),
                                                           url: "https://u/x", uploadState: .uploaded))
    // A new slot can no longer replace the URL a peer may already hold.
    try await reopened.setAttachmentUploadTask(accountID: "a", messageID: "photo", taskID: 9, url: "https://u/other")
    #expect(try await reopened.message(accountID: "a", messageID: "photo")?.attachment?.url == "https://u/x")
}

/// The app fails a file whose upload keeps being refused; that must release what was queued behind it, and a retry
/// puts the file back on the upload queue, still unsendable until its PUT succeeds.
@Test func aFailedUploadStopsHoldingItsChatAndCanBeRetried() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    #expect(try await store.enqueueOutgoing(media("photo")))
    #expect(try await store.enqueueOutgoing(media("later", body: "typed later", attachment: nil)))
    #expect(try await store.queuedOutgoing(accountID: "a").isEmpty)
    try await store.failQueuedOutgoing(accountID: "a", messageID: "photo")
    #expect(try await store.attachmentsAwaitingUpload(accountID: "a").isEmpty)
    #expect(try await store.queuedOutgoing(accountID: "a").map(\.id) == ["later"])
    #expect(try await store.claimNextOutgoing(accountID: "a")?.message.id == "later")
    try await store.retryOutgoing(accountID: "a", messageID: "photo")
    #expect(try await store.attachmentsAwaitingUpload(accountID: "a").map(\.id) == ["photo"])
    #expect(try await store.claimNextOutgoing(accountID: "a") == nil)
}

@Test func receivedFileRoundTripsAndReplayIgnoresAttachmentIdentity() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
    let received = StoredMessage(id: "in", accountID: "a", chatID: "peer", senderID: "peer", body: "", sentAt: Date(timeIntervalSince1970: 5),
                                 attachment: StoredAttachment(name: "doc.pdf", mediaType: "application/pdf", size: 10, hash: "ff", secret: Data([9]), url: "https://u/doc"))
    #expect(try await store.insertMessage(received))
    #expect(try await store.messages(accountID: "a", chatID: "peer").first?.attachment == received.attachment)
    var replay = received
    replay.attachment?.secret = Data([8])
    #expect(try await !store.insertMessage(replay), "The same message replayed from the archive is a no-op even if its sealed secret differs")
    #expect(try await store.chats(accountID: "a").first?.lastMessage?.attachment?.kindLabel == "File")
}
