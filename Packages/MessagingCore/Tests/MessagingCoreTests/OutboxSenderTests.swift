import Foundation
import Testing
import MessageStore
@testable import MessagingCore

private actor Recorder {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}
private enum Simulated: Error { case lostSocket }

struct OutboxSenderTests {
    private func fixture() async throws -> (MessageStore, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "sender-\(UUID()).sqlite")
        let store = try MessageStore(url: url)
        try await store.acquireTransportOwnership()
        try await store.upsertChat(accountID: "alice", chatID: "bob", title: "Bob")
        try await store.enqueueOutgoing(StoredMessage(id: "wire-1", accountID: "alice", chatID: "bob",
                                                      senderID: "alice", body: "Hello", isOutgoing: true))
        return (store, url)
    }

    @Test func persistsBeforeTransportAndDoesNotReplayUnconfirmed() async throws {
        let (store, _) = try await fixture()
        let sender = OutboxSender(store: store)
        let recorder = Recorder()
        try await sender.drain(accountID: "alice") { message in
            let saved = try await store.messages(accountID: "alice", chatID: "bob")
            #expect(saved.count == 1)
            #expect(saved.first?.transportState == .submitting)
            #expect(saved.first?.id == message.id)
            await recorder.record(message.id)
        }
        #expect(try await store.messages(accountID: "alice", chatID: "bob").first?.transportState == .unconfirmed)
        try await sender.drain(accountID: "alice") { message in await recorder.record(message.id) }
        #expect(await recorder.ids == ["wire-1"])
        try await store.retryOutgoing(accountID: "alice", messageID: "wire-1")
        try await sender.drain(accountID: "alice") { message in await recorder.record(message.id) }
        #expect(await recorder.ids == ["wire-1", "wire-1"])
    }

    @Test func finalTrustRejectionWithoutTransportKeepsQueued() async throws {
        let (store, _) = try await fixture()
        let sender = OutboxSender(store: store)
        await #expect(throws: OutboxSendFailure.self) {
            try await sender.drain(accountID: "alice", messageIDs: ["wire-1"]) { _ in throw OutboxSendFailure.notAttempted }
        }
        #expect(try await store.messages(accountID: "alice", chatID: "bob").first?.transportState == .queued)
    }

    @Test func socketFailureRemainsUnconfirmed() async throws {
        let (store, _) = try await fixture()
        let sender = OutboxSender(store: store)
        await #expect(throws: Simulated.self) {
            try await sender.drain(accountID: "alice") { _ in throw Simulated.lostSocket }
        }
        #expect(try await store.messages(accountID: "alice", chatID: "bob").first?.transportState == .unconfirmed)
    }

    @Test func cancellationBeforeTransportKeepsQueued() async throws {
        let (store, _) = try await fixture()
        let sender = OutboxSender(store: store)
        let recorder = Recorder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await sender.drain(accountID: "alice") { message in await recorder.record(message.id) }
        }
        try await task.value
        #expect(await recorder.ids.isEmpty)
        #expect(try await store.messages(accountID: "alice", chatID: "bob").first?.transportState == .queued)
    }

    @Test func cancellationAfterClaimBeforeSocketReleasesClaim() async throws {
        let (store, _) = try await fixture()
        let sender = OutboxSender(store: store)
        let recorder = Recorder()
        let task = Task {
            try await sender.drain(accountID: "alice", send: { message in
                await recorder.record(message.id)
            }, didChange: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        try await task.value
        #expect(await recorder.ids.isEmpty)
        #expect(try await store.messages(accountID: "alice", chatID: "bob").first?.transportState == .queued)
    }
}
