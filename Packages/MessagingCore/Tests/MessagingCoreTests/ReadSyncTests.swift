import Foundation
import Testing
import MessageStore
import XMPPProtocol
import OMEMO
@testable import MessagingCore

struct ReadSyncTests {
    private let account = "alice@localhost", peer = "bob@localhost"

    private func fixture() async throws -> (MessageStore, OMEMOService) {
        let store = try MessageStore(url: FileManager.default.temporaryDirectory.appending(path: "readsync-\(UUID()).sqlite"))
        try await store.acquireTransportOwnership()
        try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([0]))
        for (index, id) in ["m1", "m2"].enumerated() {
            let message = StoredMessage(id: id, accountID: account, chatID: peer, senderID: peer, body: "Synthetic",
                                        sentAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), encryptionProfile: "modern", wireID: id)
            try await store.commitEncryptedIncoming(accountID: account, sender: peer, digest: id, expectedRevision: index + 1, state: Data([UInt8(index + 1)]),
                                                    message: message, archiveStanzaID: "s-" + id)
        }
        return (store, OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32))))
    }

    @Test func pullAppliesOwnItemsAndIgnoresUnknownOrRefused() async throws {
        let (store, encryption) = try await fixture()
        let sync = ReadSync(store: store)
        // A server without the node, or one that refuses: nothing changes, nothing fails.
        #expect(try await !sync.pull(account: account, encryption: encryption, fetch: { throw XMPPIQError.stanza(condition: "feature-not-implemented") }))
        // Nor does a slow or lost connection: the pull is best effort wherever it runs.
        #expect(try await !sync.pull(account: account, encryption: encryption, fetch: { throw XMPPClientError.timedOut }))
        #expect(try await !sync.pull(account: account, encryption: encryption, fetch: { throw XMPPClientError.notConnected }))
        #expect(try await !sync.pull(account: account, encryption: encryption, fetch: { throw XMPPClientError.connectionClosed }))
        await #expect(throws: CancellationError.self) { try await sync.pull(account: account, encryption: encryption, fetch: { throw CancellationError() }) }
        #expect(try await !sync.pull(account: account, encryption: encryption, fetch: { [XMPPDisplayedItem(chat: "bob@localhost", stanzaID: "unknown", by: "alice@localhost")] }))
        #expect(try await store.pendingNotifications(accountID: account).claimed.count == 2)
        try await store.commitEncryptedIncoming(accountID: account, sender: peer, digest: "m3", expectedRevision: 3, state: Data([3]),
            message: StoredMessage(id: "m3", accountID: account, chatID: peer, senderID: peer, body: "Synthetic", sentAt: Date(timeIntervalSince1970: 1_800_000_010),
                                   encryptionProfile: "modern", wireID: "m3"), archiveStanzaID: "s-m3")
        #expect(try await sync.pull(account: account, encryption: encryption, fetch: { [XMPPDisplayedItem(chat: "bob@localhost", stanzaID: "s-m3", by: "alice@localhost")] }))
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.messageID == "m3")
        // Read on another device before this run's claim: nothing is left to alert.
        #expect(try await store.pendingNotifications(accountID: account).claimed.count == 0)
    }

    @Test func pushPublishesLocalReadsOnceAndKeepsFailuresPending() async throws {
        let (store, _) = try await fixture()
        let sync = ReadSync(store: store)
        #expect(try await store.markRead(accountID: account, chatID: peer, throughMessageID: "m1"))
        struct Refused: Error {}
        await #expect(throws: Refused.self) { try await sync.push(account: account, publish: { _ in throw Refused() }) }
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.publishPending == true)
        let published = Published()
        #expect(try await sync.push(account: account, publish: { await published.add($0) }) == 1)
        #expect(await published.items == [XMPPDisplayedItem(chat: peer, stanzaID: "s-m1", by: account)])
        #expect(try await sync.push(account: account, publish: { await published.add($0) }) == 0)
        #expect(try await store.markRead(accountID: account, chatID: peer, throughMessageID: "m2"))
        #expect(try await sync.push(account: account, publish: { await published.add($0) }) == 1)
        #expect(await published.items.map(\.stanzaID) == ["s-m1", "s-m2"])
    }

    @Test func processorAppliesDisplayedSyncEvents() async throws {
        let (store, encryption) = try await fixture()
        let processor = InboundProcessor(encryption: encryption, client: XMPPClient(labCertificateAuthority: nil), account: account)
        #expect(try await processor.process(.displayedSync([XMPPDisplayedItem(chat: peer, stanzaID: "s-m2", by: account)])) == .stored)
        #expect(try await store.readPointer(accountID: account, chatID: peer)?.messageID == "m2")
        #expect(try await store.unreadCounts(accountID: account).isEmpty)
    }
}

private actor Published {
    var items: [XMPPDisplayedItem] = []
    func add(_ item: XMPPDisplayedItem) { items.append(item) }
}
