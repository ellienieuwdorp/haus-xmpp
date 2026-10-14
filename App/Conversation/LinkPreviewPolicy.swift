import Foundation
import MessageStore
import XMPPProtocol

/// Whether our own fetch may run, and its cached result show, for a displayed message's link
/// (docs/development/link-previews.md, engineering defaults 3, 4 and 6). A preview the sender attached shows whatever
/// this says; this only decides what our own fetch adds to a bubble.
enum LinkPreviewPolicy {
    /// What this connection's roster says about a sender.
    enum RosterEntry: Equatable {
        /// The roster has not been fetched on this connection (or there is none): nobody counts as a contact yet.
        case notLoaded
        /// Fetched, and the sender is not in it.
        case absent
        case item(XMPPRosterItem.Subscription)
    }

    /// Fetch for `message` only with the setting on, outside the sample conversations, for a contact's message: a
    /// roster item with subscription `to`, `from` or `both`. A pending request (`none` with an ask), a stranger, and a
    /// group occupant who is not such a contact never cause a request. Before the roster has loaded nobody is a
    /// contact: the display that comes after it asks again.
    /// Our own messages (from this or another of our devices) never: their bubble shows what the peer got, which is
    /// only the preview the message carried. The composer fetches for the link being typed on its own path.
    static func mayFetch(for message: StoredMessage, account: String, fetchesPreviews: Bool, isDemo: Bool,
                         roster: (String) -> RosterEntry) -> Bool {
        guard fetchesPreviews, !isDemo, !account.isEmpty else { return false }
        if message.isOutgoing || message.senderID == account { return false }
        // A group sender we only know by nickname (`room@service/nick`) is nobody's contact.
        guard !message.senderID.contains("/"), let sender = JID.normalizedBare(message.senderID) else { return false }
        switch roster(sender) {
        case .item(.to), .item(.from), .item(.both): return true
        case .item, .absent, .notLoaded: return false
        }
    }
}
