import Foundation
import MessageStore
import MessagingCore

/// The conversation an outgoing donation names, built the same way by the app and the share extension from what the
/// store holds, and named as the chat's notifications name it: the chat's title and avatar with a linked contact's
/// name and photo first (`ContactLink`), and for a room the members this device knows of, named like their chats. A
/// person carries their contact only for a link the app can read (`ContactLink.usableContactIdentifier`);
/// `OutgoingDonation.donate` reads each link again before donating.
enum SuggestedConversation {
    /// Names are bounded as a notification's are.
    static let nameLimit = 40

    /// `roomMembers` is nil for a direct chat; `titles` maps the account's chats to their stored titles and `links` its
    /// contact links, both by address.
    static func outgoing(accountID: String, chatID: String, title: String?, avatarHash: String?, roomMembers: [String]?,
                         titles: [String: String], links: [String: ContactLink]) -> OutgoingConversation {
        guard let roomMembers else {
            let link = links[chatID]
            let name = String(ContactName.display(for: chatID, title: ContactLink.title(title, link: link)).prefix(nameLimit))
            return .direct(accountID: accountID, chatID: chatID, displayName: name, avatarHash: ContactLink.avatarHash(verified: avatarHash, link: link),
                           contactIdentifier: link?.usableContactIdentifier)
        }
        let members = roomMembers.map { member in
            let link = links[member]
            let name = String(ContactName.display(for: member, title: ContactLink.title(titles[member], link: link)).prefix(nameLimit))
            return NotificationCommunication.Person(handle: member, displayName: name, avatarHash: nil, contactIdentifier: link?.usableContactIdentifier)
        }
        let name = String(ContactName.display(for: chatID, title: title).prefix(nameLimit))
        return .room(accountID: accountID, room: chatID, title: name, avatarHash: avatarHash, members: members)
    }
}
