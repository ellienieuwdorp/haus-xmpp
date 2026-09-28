import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// XEP-0490 Message Displayed Synchronization for one connection: `pull` applies what other devices of the account
/// published (after bind and archive catch-up, so the ids resolve), `push` publishes reads made on this device.
/// Pointers only move forward; unknown ids are ignored. Both the app and the notification extension pull; only the
/// app pushes, because only the app reads.
public struct ReadSync: Sendable {
    private let store: MessageStore
    public init(store: MessageStore) { self.store = store }

    /// Best effort: a server without the node, a refusal, a timeout or a lost connection changes nothing. Only a
    /// storage failure or cancellation propagates. `timeout` bounds the query. Returns true when any chat's pointer moved.
    @discardableResult
    public func pull(account: String, client: XMPPClient, encryption: OMEMOService, timeout: Duration = XMPPClient.iqTimeout) async throws -> Bool {
        try await pull(account: account, encryption: encryption, fetch: { try await client.fetchDisplayedSync(timeout: timeout) })
    }

    func pull(account: String, encryption: OMEMOService, fetch: @Sendable () async throws -> [XMPPDisplayedItem]) async throws -> Bool {
        let items: [XMPPDisplayedItem]
        do { items = try await fetch() }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return false }
        return try await encryption.receiveDisplayedSync(account: account, items: items)
    }

    /// Publishes every pending local read. Stops at the first failure; what is left stays pending for the next call.
    /// Returns how many items were published.
    @discardableResult
    public func push(account: String, client: XMPPClient) async throws -> Int {
        try await push(account: account, publish: { try await client.publishDisplayedSync($0) })
    }

    func push(account: String, publish: @Sendable (XMPPDisplayedItem) async throws -> Void) async throws -> Int {
        var published = 0
        for publication in try await store.pendingDisplayedSyncPublications(accountID: account) {
            try Task.checkCancellation()
            try await publish(XMPPDisplayedItem(chat: publication.chatID, stanzaID: publication.stanzaID, by: publication.by))
            try await store.finishDisplayedSyncPublication(accountID: account, publication)
            published += 1
        }
        return published
    }
}
