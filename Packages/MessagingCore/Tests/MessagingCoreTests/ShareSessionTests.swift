import Foundation
import MessageStore
import OMEMO
import Testing
import XMPPProtocol
@testable import MessagingCore

private func temporaryStore() throws -> (MessageStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try MessageStore(url: directory.appending(path: "messages.sqlite")), directory)
}

private let account = BackgroundAccount(route: .fixed(XMPPEndpoint(host: "localhost", port: 5223, security: .directTLS)),
                                        domain: "localhost", username: "alice", password: "private")

struct ShareSessionTests {
    @Test func theLeaseIsWaitedForBoundedAndNeverTakenFromItsOwner() async throws {
        let (store, directory) = try temporaryStore()
        let url = directory.appending(path: "messages.sqlite")
        // Another process's store on the same file holds the lease (the app, or the notification extension).
        let owner = try MessageStore(url: url, schema: .currentOnly)
        try await owner.acquireTransportOwnership()
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        let session = ShareSession(store: store, encryption: encryption, files: AttachmentFiles(directory: directory, account: account.accountID),
                                   account: account, uploadService: nil)
        let started = ContinuousClock.now
        #expect(await session.acquireLease(waitingUpTo: .milliseconds(600)) == false)
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(250) && waited < .seconds(2))
        // The owner still holds it: nothing was stolen or expired.
        await #expect(throws: MessageStoreError.transportOwnedElsewhere) { try await store.acquireTransportOwnership() }
        // Freed during the wait, it is taken.
        let release = Task { try await Task.sleep(for: .milliseconds(300)); try await owner.releaseTransportOwnership() }
        #expect(await session.acquireLease(waitingUpTo: .seconds(3)))
        try await release.value
        await #expect(throws: MessageStoreError.transportOwnedElsewhere) { try await owner.acquireTransportOwnership() }
        // Ending without a connection releases it, and a second end changes nothing.
        await session.end()
        await session.end()
        try await owner.acquireTransportOwnership()
        try await owner.releaseTransportOwnership()
        // An ended session never takes the lease again.
        #expect(await session.acquireLease(waitingUpTo: .zero) == false)
        try await owner.close()
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func releasingTheLeaseMarksAWriteInFlightUnconfirmed() async throws {
        let (store, directory) = try temporaryStore()
        try await store.upsertChat(accountID: account.accountID, chatID: "bob@localhost", title: "bob@localhost")
        try await OutgoingEnqueue.text("Hi", id: "m1", account: account.accountID, chatID: "bob@localhost", store: store)
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        let session = ShareSession(store: store, encryption: encryption, files: AttachmentFiles(directory: directory, account: account.accountID),
                                   account: account, uploadService: nil)
        #expect(await session.acquireLease(waitingUpTo: .zero))
        #expect(await session.states(["m1"]) == ["m1": .queued])
        // A claim stands for a stanza that may have been written when the extension goes away.
        _ = try #require(try await store.claimNextOutgoing(accountID: account.accountID))
        #expect(await session.states(["m1"]) == ["m1": .sending])
        await session.end()
        let message = try await store.message(accountID: account.accountID, messageID: "m1")
        #expect(message?.transportState == .unconfirmed)
        #expect(ShareItemState(message) == .sending)
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func onlyTheServersAcknowledgementReadsAsSent() {
        func message(_ state: OutgoingTransportState?) -> StoredMessage {
            var message = StoredMessage(id: "m", accountID: "a", chatID: "b", senderID: "a", body: "x", isOutgoing: true)
            message.transportState = state
            return message
        }
        #expect(ShareItemState(message(.queued)) == .queued)
        #expect(ShareItemState(message(.submitting)) == .sending)
        #expect(ShareItemState(message(.unconfirmed)) == .sending)
        #expect(ShareItemState(message(.serverAccepted)) == .sent)
        #expect(ShareItemState(message(.failed)) == .failed)
        #expect(ShareItemState(nil) == .queued)
    }
}
