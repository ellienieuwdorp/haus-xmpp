import Foundation
import Testing
import MessageStore
@testable import MessagingCore

private actor Wire {
    var log: [String] = []
    func write(_ id: String) { log.append(id) }
    func requestAcknowledgement() { log.append("<r/>") }
}
private enum Simulated: Error { case lostSocket }

// A pass asks the server once for an acknowledgement after its writes, not once per stanza; Stream Management acknowledges
// every stanza before the request.
struct OutboxAcknowledgementTests {
    private func store(_ ids: [String]) async throws -> MessageStore {
        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "ack-\(UUID()).sqlite"))
        try await store.acquireTransportOwnership()
        try await store.upsertChat(accountID: "alice", chatID: "bob", title: "Bob")
        for id in ids {
            try await store.enqueueOutgoing(StoredMessage(id: id, accountID: "alice", chatID: "bob", senderID: "alice", body: id, isOutgoing: true))
        }
        return store
    }

    @Test func aBurstIsFollowedByOneRequestInQueueOrder() async throws {
        let store = try await store(["one", "two", "three"])
        let wire = Wire()
        try await OutboxDrain.acknowledging(request: { await wire.requestAcknowledgement() }) { written in
            try await OutboxSender(store: store).drain(accountID: "alice") { message in
                await written.note()
                await wire.write(message.id)
            }
        }
        #expect(await wire.log == ["one", "two", "three", "<r/>"])
        let states = try await store.messages(accountID: "alice", chatID: "bob").map(\.transportState)
        #expect(states == [.unconfirmed, .unconfirmed, .unconfirmed])
    }

    @Test func nothingWrittenAsksForNothing() async throws {
        let store = try await store(["one"])
        let wire = Wire()
        await #expect(throws: OutboxSendFailure.notAttempted) {
            try await OutboxDrain.acknowledging(request: { await wire.requestAcknowledgement() }) { _ in
                try await OutboxSender(store: store).drain(accountID: "alice") { _ in throw OutboxSendFailure.notAttempted }
            }
        }
        try await OutboxDrain.acknowledging(request: { await wire.requestAcknowledgement() }) { _ in }
        #expect(await wire.log.isEmpty)
        #expect(try await store.queuedOutgoing(accountID: "alice").map(\.id) == ["one"])
    }

    // A write that failed may still have reached the server, so what went before it is acknowledged all the same.
    @Test func aRunThatFailsAfterAWriteStillAsks() async throws {
        let store = try await store(["one", "two"])
        let wire = Wire()
        await #expect(throws: Simulated.lostSocket) {
            try await OutboxDrain.acknowledging(request: { await wire.requestAcknowledgement() }) { written in
                try await OutboxSender(store: store).drain(accountID: "alice") { message in
                    await written.note()
                    await wire.write(message.id)
                    if message.id == "two" { throw Simulated.lostSocket }
                }
            }
        }
        #expect(await wire.log == ["one", "two", "<r/>"])
    }
}
