import Foundation
import MessageStore
import XMPPProtocol

enum LinkPreviewPolicy {
    enum RosterEntry: Equatable {
        case notLoaded
        case absent
        case item(XMPPRosterItem.Subscription)
    }

    // Own messages show only the preview they carried (what the peer got); before the roster loads nobody is a contact.
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
