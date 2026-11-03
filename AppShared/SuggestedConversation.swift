import Foundation
import MessageStore
import MessagingCore

// Built the same way by the app and the share extension, named as the chat's notifications name it (a linked contact
// first). `OutgoingDonation.donate` reads each link again before donating.
enum SuggestedConversation {
    static let nameLimit = 40

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
