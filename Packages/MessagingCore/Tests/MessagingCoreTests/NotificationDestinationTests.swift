import Foundation
import Testing
import MessageStore
@testable import MessagingCore

@Test func notificationDestinationsContainOnlyScopedOpaqueIdentifiers() throws {
    let id = UUID().uuidString
    let destination = try #require(NotificationDestination(accountID: "alice@example.org", messageID: id))
    #expect(NotificationDestination(payload: destination.payload) == destination)
    #expect(!String(describing: destination.payload).contains("alice@example.org"))
    #expect(NotificationDestination(accountID: "alice@example.org", messageID: "https://evil.example") == nil)
    for mutation in ["version", "account", "message", "extra"] {
        var payload = destination.payload
        payload[mutation] = "invalid"
        #expect(NotificationDestination(payload: payload) == nil)
    }
    let message = StoredMessage(id: id, accountID: "alice@example.org", chatID: "bob@example.org", senderID: "bob@example.org", body: "Secret body", encryptionProfile: "modern")
    let hidden = NotificationPlanner.plan(MessageNotification(candidates: [NotificationCandidate(key: .message(id), accountID: "alice@example.org",
        chatID: "bob@example.org", chatTitle: "Private sender", senderID: "bob@example.org", isGroup: false, sentAt: message.sentAt,
        content: .message(message))], claimed: [.message(id)], previewsEnabled: false)).requests[0]
    #expect(hidden.destination == destination)
    #expect(!String(describing: hidden.userInfo).contains("Secret body"))
    #expect(!String(describing: hidden.userInfo).contains("bob@example.org"))
    #expect(destination.belongs(to: "alice@example.org") && !destination.belongs(to: "other@example.org") && !destination.belongs(to: ""))
}

@Test func notificationResolutionRejectsInactiveOtherAccountMissingAndUnauthenticatedMessages() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try MessageStore(url: directory.appending(path: "notification.sqlite"))
    do {
        try await store.upsertChat(accountID: "alice", chatID: "peer", title: "Peer")
        let id = UUID().uuidString
        let message = StoredMessage(id: id, accountID: "alice", chatID: "peer", senderID: "peer", body: "Synthetic", sentAt: Date(timeIntervalSince1970: 1000), encryptionProfile: "modern")
        try await store.insertMessage(message)
        try await store.upsertChat(accountID: "other", chatID: "different-peer", title: "Other account")
        try await store.insertMessage(StoredMessage(id: id, accountID: "other", chatID: "different-peer", senderID: "different-peer", body: "Other account same local ID", encryptionProfile: "modern"))
        let target = try #require(NotificationDestination(accountID: "alice", messageID: id))
        #expect(try await target.resolve(accountID: "alice", active: true, store: store) == message)
        #expect(try await target.resolve(accountID: "alice", active: false, store: store) == nil)
        #expect(try await target.resolve(accountID: "other", active: true, store: store) == nil)
        let missing = try #require(NotificationDestination(accountID: "alice", messageID: UUID().uuidString))
        #expect(try await missing.resolve(accountID: "alice", active: true, store: store) == nil)
        for outgoing in [false, true] {
            let invalidID = UUID().uuidString
            try await store.insertMessage(StoredMessage(id: invalidID, accountID: "alice", chatID: "peer", senderID: outgoing ? "alice" : "peer", body: "Not a notification target", isOutgoing: outgoing, encryptionProfile: outgoing ? "modern" : nil))
            let invalid = try #require(NotificationDestination(accountID: "alice", messageID: invalidID))
            #expect(try await invalid.resolve(accountID: "alice", active: true, store: store) == nil)
        }
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    } catch {
        try? await store.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
