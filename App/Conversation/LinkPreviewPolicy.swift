import Foundation
import MessageStore
import XMPPProtocol

/// Whether our own fetch may run for a displayed message's link (docs/development/link-previews.md, engineering
/// defaults 3 and 4). A preview the sender attached shows whatever this says; this only decides our own request.
enum LinkPreviewPolicy {
    /// What this connection's roster says about a sender.
    enum RosterEntry: Equatable {
        /// The roster has not been fetched on this connection (or there is none): nobody counts as a contact yet.
        case notLoaded
        /// Fetched, and the sender is not in it.
        case absent
        case item(XMPPRosterItem.Subscription)
    }

    /// Fetch for `message` only with the setting on, outside the sample conversations, for our own message (from this
    /// or another of our devices) or a contact's: a roster item with subscription `to`, `from` or `both`. A pending
    /// request (`none` with an ask), a stranger, and a group occupant who is not such a contact never cause a request.
    /// Before the roster has loaded nobody is a contact: the display that comes after it asks again.
    static func mayFetch(for message: StoredMessage, account: String, fetchesPreviews: Bool, isDemo: Bool,
                         roster: (String) -> RosterEntry) -> Bool {
        guard fetchesPreviews, !isDemo, !account.isEmpty else { return false }
        if message.isOutgoing || message.senderID == account { return true }
        // A group sender we only know by nickname (`room@service/nick`) is nobody's contact.
        guard !message.senderID.contains("/"), let sender = JID.normalizedBare(message.senderID) else { return false }
        switch roster(sender) {
        case .item(.to), .item(.from), .item(.both): return true
        case .item, .absent, .notLoaded: return false
        }
    }
}
