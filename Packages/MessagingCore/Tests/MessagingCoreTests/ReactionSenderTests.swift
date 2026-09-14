import Foundation
import Testing
import MessageStore
@testable import MessagingCore

struct ReactionSenderTests {
    private enum Failure: Error { case socket }
    private func fixture(_ body: (MessageStore, OutboxSender) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reaction-sender-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do {
            try await store.upsertChat(accountID: "alice", chatID: "bob", title: "Bob")
            try await store.insertMessage(.init(id: "target", accountID: "alice", chatID: "bob", senderID: "bob", body: "Fixture",
                isOutgoing: false, encryptionProfile: "modern", wireID: "wire-target", wireIDAuthenticated: true))
            try await store.saveEncryptionState(accountID: "alice", expectedRevision: nil, data: Data([1]))
            _ = try await store.enqueueReaction(.init(id: "reaction", accountID: "alice", chatID: "bob", targetMessageID: "target",
                targetWireID: "wire-target", actorID: "alice", reactions: ["👍"]))
            try await store.sealQueuedReaction(accountID: "alice", updateID: "reaction", expectedRevision: 1, state: Data([2]), wire: Data([3]))
            try await body(store, OutboxSender(store: store))
        } catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func finalPreflightRejectionPreservesQueuedReaction() async throws {
        try await fixture { store, sender async throws in
            await #expect(throws: OutboxSendFailure.self) {
                try await sender.drainReactions(accountID: "alice", updateIDs: ["reaction"]) { _ in throw OutboxSendFailure.notAttempted }
            }
            #expect(try await store.reactionUpdate(accountID: "alice", updateID: "reaction")?.transportState == .queued)
            #expect(try await store.encryptedReaction(accountID: "alice", updateID: "reaction") == Data([3]))
        }
    }
    @Test func uncertainWriteIsNotAutomaticallyReplayed() async throws {
        try await fixture { store, sender async throws in
            await #expect(throws: Failure.self) {
                try await sender.drainReactions(accountID: "alice", updateIDs: ["reaction"]) { _ in throw Failure.socket }
            }
            #expect(try await store.reactionUpdate(accountID: "alice", updateID: "reaction")?.transportState == .unconfirmed)
            try await sender.drainReactions(accountID: "alice", updateIDs: ["reaction"]) { _ in Issue.record("Uncertain reaction replayed") }
        }
    }
    @Test func cancellationAfterClaimReleasesWithoutTransport() async throws {
        try await fixture { store, sender async throws in
            let task = Task {
                try await sender.drainReactions(accountID: "alice", updateIDs: ["reaction"], send: { _ in Issue.record("Cancelled reaction sent") },
                    didChange: { withUnsafeCurrentTask { $0?.cancel() } })
            }
            try await task.value
            #expect(try await store.reactionUpdate(accountID: "alice", updateID: "reaction")?.transportState == .queued)
        }
    }
}
