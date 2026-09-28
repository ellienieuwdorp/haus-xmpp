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

@Test func notificationsCommitWithRatchetAndSurviveReopen() async throws {
    try await notificationFixture { store, url in
        try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
        await #expect(throws: MessageStoreError.invalidTransition) {
            try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "bad",
                expectedRevision: 99, state: Data([2]), message: incoming("bad"))
        }
        #expect(try await store.pendingNotifications(accountID: "a").candidates.isEmpty)
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "good",
            expectedRevision: 1, state: Data([2]), message: incoming("good"))
        try await store.close()
        let reopened = try MessageStore(url: url)
        try await reopened.acquireTransportOwnership()
        let batch = try await reopened.pendingNotifications(accountID: "a")
        #expect(batch.candidates.map(\.key) == [.message("good")] && batch.claimed == [.message("good")])
        #expect(batch.previewsEnabled)
        // Reading claims nothing; only the explicit removal after posting does.
        #expect(try await reopened.pendingNotifications(accountID: "a") == batch)
        try await reopened.removeNotificationCandidates(accountID: "a", keys: batch.claimed)
        #expect(try await reopened.pendingNotifications(accountID: "a").candidates.isEmpty)
        try await reopened.close()
    }
}

@Test func notificationCandidatesExcludePlaintextControlsAndReplays() async throws {
    try await notificationFixture { store, _ in
        try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
        try await store.insertMessage(StoredMessage(id: "plain", accountID: "a", chatID: "peer", senderID: "peer", body: "Untrusted"))
        try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "control",
            expectedRevision: 1, state: Data([2]), message: nil)
        #expect(try await store.pendingNotifications(accountID: "a").candidates.isEmpty)
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "message",
            expectedRevision: 2, state: Data([3]), message: incoming("encrypted"))
        try await store.dismissPendingMessageNotifications(accountID: "a")
        await #expect(throws: MessageStoreError.invalidTransition) {
            try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "message",
                expectedRevision: 3, state: Data([4]), message: incoming("encrypted"))
        }
        #expect(try await store.pendingNotifications(accountID: "a").candidates.isEmpty)
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
            try await nonowner.pendingNotifications(accountID: "a")
        }
        await #expect(throws: MessageStoreError.transportOwnershipRequired) {
            try await nonowner.removeNotificationCandidates(accountID: "a", keys: [.message("message")])
        }
        try await nonowner.close()
        let first = try await store.pendingNotifications(accountID: "a")
        #expect(!first.previewsEnabled && first.candidates.count == 1)
        try await store.removeNotificationCandidates(accountID: "a", keys: first.claimed)
        let second = try await store.pendingNotifications(accountID: "b")
        #expect(second.previewsEnabled && second.candidates.count == 1 && second.candidates[0].accountID == "b")
    }
}

private func commit(_ store: MessageStore, _ message: StoredMessage, sender: String? = nil, groupRoom: String? = nil,
                    correction: Bool = false) async throws {
    if try await store.encryptionStateRevision(accountID: message.accountID) == nil {
        try await store.saveEncryptionState(accountID: message.accountID, expectedRevision: nil, data: Data([1]))
    }
    let revision = try #require(try await store.encryptionStateRevision(accountID: message.accountID))
    try await store.commitEncryptedIncoming(accountID: message.accountID, sender: sender ?? message.senderID, digest: "d-" + message.id,
        expectedRevision: revision, state: Data([UInt8(revision % 250 + 1)]), message: message, groupRoom: groupRoom,
        correctsEarlierMessage: correction)
}

private func message(_ id: String, chat: String, sender: String? = nil, at: TimeInterval, body: String = "Synthetic") -> StoredMessage {
    StoredMessage(id: id, accountID: "a", chatID: chat, senderID: sender ?? chat, body: body,
                  sentAt: Date(timeIntervalSince1970: at), encryptionProfile: "modern")
}

@Test func claimIsBoundedPerChatAndPerRunOldestFirstWithEarlierCounts() async throws {
    try await notificationFixture { store, _ in
        try await store.upsertChat(accountID: "a", chatID: "busy", title: "Busy")
        // 12 in one chat, then 15 single-message chats that are all newer.
        for index in 0..<12 { try await commit(store, message("busy-\(index)", chat: "busy", at: 100 + Double(index))) }
        for index in 0..<15 { try await commit(store, message("solo-\(index)", chat: "solo-\(index)", at: 200 + Double(index))) }
        let batch = try await store.pendingNotifications(accountID: "a")
        // 15 solo chats are newest, then the busy chat's 5 newest fill the total of 20.
        #expect(batch.candidates.count == 20)
        #expect(batch.candidates.map(\.sentAt) == batch.candidates.map(\.sentAt).sorted())
        let busy = batch.candidates.filter { $0.chatID == "busy" }
        #expect(busy.map(\.key) == (7..<12).map { .message("busy-\($0)") })
        #expect(busy.first?.earlierCount == 7 && busy.dropFirst().allSatisfy { $0.earlierCount == 0 })
        #expect(busy.first?.chatTitle == "Busy" && busy.first?.isGroup == false)
        #expect(Set(batch.claimed).count == 27 && batch.deferredCount == 0)

        // The per-chat cap alone: a new chat with 10 selects its newest 8 and folds 2.
        try await store.removeNotificationCandidates(accountID: "a", keys: batch.claimed)
        for index in 0..<10 { try await commit(store, message("burst-\(index)", chat: "burst", at: 300 + Double(index))) }
        let burst = try await store.pendingNotifications(accountID: "a")
        #expect(burst.candidates.map(\.key) == (2..<10).map { .message("burst-\($0)") })
        #expect(burst.candidates.first?.earlierCount == 2 && burst.claimed.count == 10)
    }
}

@Test func chatsBeyondTheTotalCapAreDeferredNotClaimed() async throws {
    try await notificationFixture { store, _ in
        for index in 0..<3 { try await commit(store, message("m-\(index)", chat: "chat-\(index)", at: Double(index))) }
        let batch = try await store.pendingNotifications(accountID: "a", perChat: 8, total: 2)
        #expect(batch.candidates.map(\.key) == [.message("m-1"), .message("m-2")])
        #expect(batch.claimed.count == 2 && batch.deferredCount == 1 && batch.deferredChatCount == 1)
        try await store.removeNotificationCandidates(accountID: "a", keys: batch.claimed)
        #expect(try await store.pendingNotifications(accountID: "a").candidates.map(\.key) == [.message("m-0")])
    }
}

@Test func unsentMessagesAreClaimedWithoutTakingASlotOrLosingEarlierCounts() async throws {
    try await notificationFixture { store, _ in
        // The sender's unsend arrives before the message it names (archive order), so the candidate is already retracted
        // when it is inserted. It was the window's oldest message and would have carried "and 1 more".
        try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "unsend", expectedRevision: 1, state: Data([200]),
            message: nil, event: MessageEvent(id: "r", chatID: "peer", actorID: "peer", targetWireID: "w2", kind: .retraction, payload: "{}", updatedAt: Date()))
        for index in 0..<10 {
            try await commit(store, StoredMessage(id: "m-\(index)", accountID: "a", chatID: "peer", senderID: "peer", body: "Synthetic",
                                                  sentAt: Date(timeIntervalSince1970: Double(index)), encryptionProfile: "modern",
                                                  wireID: "w\(index)", wireIDAuthenticated: true))
        }
        let batch = try await store.pendingNotifications(accountID: "a")
        #expect(batch.candidates.map(\.key) == [1, 3, 4, 5, 6, 7, 8, 9].map { .message("m-\($0)") })
        #expect(batch.candidates.first?.earlierCount == 1 && batch.candidates.dropFirst().allSatisfy { $0.earlierCount == 0 })
        #expect(Set(batch.claimed) == Set((0..<10).map { NotificationCandidateKey.message("m-\($0)") }))
    }
}

@Test func removalDeletesOnlyWhatWasClaimedSoALaterArrivalStillAlerts() async throws {
    try await notificationFixture { store, _ in
        try await commit(store, message("first", chat: "peer", at: 1))
        let batch = try await store.pendingNotifications(accountID: "a")
        try await commit(store, message("second", chat: "peer", at: 2))
        try await store.removeNotificationCandidates(accountID: "a", keys: batch.claimed)
        #expect(try await store.pendingNotifications(accountID: "a").candidates.map(\.key) == [.message("second")])
    }
}

@Test func groupCandidatesNameTheRoomAndSenderAndCorrectionsNeverAlert() async throws {
    try await notificationFixture { store, _ in
        try await store.upsertChat(accountID: "a", chatID: "room@rooms", title: "Book club")
        try await store.upsertChat(accountID: "a", chatID: "bob@x", title: "Bob")
        try await commit(store, message("g1", chat: "room@rooms", sender: "bob@x", at: 1), groupRoom: "room@rooms")
        try await commit(store, message("g2", chat: "room@rooms", sender: "bob@x", at: 2, body: "Fixed"), groupRoom: "room@rooms", correction: true)
        let batch = try await store.pendingNotifications(accountID: "a")
        #expect(batch.candidates.map(\.key) == [.message("g1")])
        #expect(batch.candidates[0].isGroup && batch.candidates[0].chatTitle == "Book club" && batch.candidates[0].senderTitle == "Bob")
        // The correction is still stored as its own row: that projection gap is recorded, not hidden.
        #expect(try await store.messages(accountID: "a", chatID: "room@rooms").count == 2)
    }
}

@Test func retainedCiphertextAlertsUntilItCommitsAndOwnOrContextlessRowsNever() async throws {
    try await notificationFixture { store, _ in
        try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
        let context = PendingNotificationContext(chatID: "peer", sentAt: Date(timeIntervalSince1970: 5))
        try await store.retainEncryptedIncoming(accountID: "a", sender: "peer", digest: "p1", wire: Data([1]), reason: .trustPending, notification: context)
        // Retaining again (a redelivery) never adds a second candidate.
        try await store.retainEncryptedIncoming(accountID: "a", sender: "peer", digest: "p1", wire: Data([1]), reason: .trustPending, notification: context)
        try await store.retainEncryptedIncoming(accountID: "a", sender: "peer", digest: "quiet", wire: Data([2]), reason: .trustPending)
        try await store.retainEncryptedIncoming(accountID: "a", sender: "a", digest: "own", wire: Data([3]), reason: .keysPending,
                                                notification: PendingNotificationContext(chatID: "peer", sentAt: Date()))
        let batch = try await store.pendingNotifications(accountID: "a")
        #expect(batch.candidates.map(\.key) == [.pending(sender: "peer", digest: "p1")])
        #expect(batch.candidates[0].content == .pendingEncrypted && batch.candidates[0].chatID == "peer" && !batch.candidates[0].isGroup)
        // Approval later commits the ciphertext: the review candidate goes with the pending row, the message alerts itself.
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "p1", expectedRevision: 1, state: Data([2]),
                                                message: message("approved", chat: "peer", at: 5))
        #expect(try await store.pendingNotifications(accountID: "a").candidates.map(\.key) == [.message("approved")])
        // A room member's retained message is a group candidate; the foreground dismissal clears both kinds.
        try await store.retainEncryptedIncoming(accountID: "a", sender: "carol@x", digest: "g", wire: Data([4]), reason: .keysPending,
                                                notification: PendingNotificationContext(chatID: "room@rooms", sentAt: Date(timeIntervalSince1970: 9)))
        let group = try await store.pendingNotifications(accountID: "a")
        #expect(group.candidates.last?.isGroup == true && group.candidates.last?.senderID == "carol@x")
        // A row retained without a candidate (a room read was still needed) gets one when classification shows it waits.
        try await store.classifyPendingEncryptedIncoming(accountID: "a", sender: "peer", digest: "quiet", reason: .trustPending,
                                                         notification: PendingNotificationContext(chatID: "peer", sentAt: Date(timeIntervalSince1970: 7)))
        try await store.classifyPendingEncryptedIncoming(accountID: "a", sender: "peer", digest: "gone", reason: .trustPending,
                                                         notification: PendingNotificationContext(chatID: "peer", sentAt: Date(timeIntervalSince1970: 8)))
        #expect(try await store.pendingNotifications(accountID: "a").candidates.map(\.key).contains(.pending(sender: "peer", digest: "quiet")))
        #expect(try await Set(store.retainedEncryptedIncomingKeys(accountID: "a"))
                == [.pending(sender: "peer", digest: "quiet"), .pending(sender: "a", digest: "own"), .pending(sender: "carol@x", digest: "g")])
        try await store.dismissPendingMessageNotifications(accountID: "a")
        #expect(try await store.pendingNotifications(accountID: "a").candidates.isEmpty)
    }
}

@Test func onlyIncomingPlaceholdersFromOthersAlert() async throws {
    try await notificationFixture { store, _ in
        let incoming = UnreadableMessage(accountID: "a", chatID: "peer", senderID: "peer", isOutgoing: false, sentAt: Date(timeIntervalSince1970: 1),
                                         reason: .notForThisDevice, key: .ciphertext(sender: "peer", digest: "u1"))
        let own = UnreadableMessage(accountID: "a", chatID: "peer", senderID: "a", isOutgoing: true, sentAt: Date(timeIntervalSince1970: 2),
                                    reason: .notForThisDevice, key: .ciphertext(sender: "a", digest: "u2"))
        #expect(try await store.recordUnreadableMessage(incoming))
        #expect(try await store.recordUnreadableMessage(own))
        #expect(try await !store.recordUnreadableMessage(incoming))
        let batch = try await store.pendingNotifications(accountID: "a")
        #expect(batch.candidates.map(\.content) == [.unreadable(messageID: incoming.id)])
    }
}

@Test func staleNotificationMessagesAreMissingOrRetracted() async throws {
    try await notificationFixture { store, _ in
        try await store.upsertChat(accountID: "a", chatID: "peer", title: "Peer")
        try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
        let kept = StoredMessage(id: "kept", accountID: "a", chatID: "peer", senderID: "peer", body: "x", encryptionProfile: "modern", wireID: "w1", wireIDAuthenticated: true)
        let unsent = StoredMessage(id: "unsent", accountID: "a", chatID: "peer", senderID: "peer", body: "y", encryptionProfile: "modern", wireID: "w2", wireIDAuthenticated: true)
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "1", expectedRevision: 1, state: Data([2]), message: kept)
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "2", expectedRevision: 2, state: Data([3]), message: unsent)
        try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "3", expectedRevision: 3, state: Data([4]), message: nil,
            event: MessageEvent(id: "r", chatID: "peer", actorID: "peer", targetWireID: "w2", kind: .retraction, payload: "{}", updatedAt: Date()))
        #expect(try await store.staleNotificationMessageIDs(accountID: "a", messageIDs: ["kept", "unsent", "gone"]) == ["unsent", "gone"])
        #expect(try await store.pendingNotifications(accountID: "a").candidates.map(\.key) == [.message("kept")])
    }
}
