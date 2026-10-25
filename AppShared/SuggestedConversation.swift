import Foundation
import MessagingCore

/// The conversation an outgoing donation names, built the same way by the app and the share extension from what the
/// store holds: the chat's title and avatar, and for a room the members this device knows of, named like their chats.
enum SuggestedConversation {
    /// Names are bounded as a notification's are.
    static let nameLimit = 40

    /// `roomMembers` is nil for a direct chat; `titles` maps the account's chats to their stored titles.
    static func outgoing(accountID: String, chatID: String, title: String?, avatarHash: String?, roomMembers: [String]?,
                         titles: [String: String]) -> OutgoingConversation {
        let name = String(ContactName.display(for: chatID, title: title).prefix(nameLimit))
        guard let roomMembers else { return .direct(accountID: accountID, chatID: chatID, displayName: name, avatarHash: avatarHash) }
        let members = roomMembers.map { member in
            NotificationCommunication.Person(handle: member, displayName: String(ContactName.display(for: member, title: titles[member]).prefix(nameLimit)),
                                             avatarHash: nil)
        }
        return .room(accountID: accountID, room: chatID, title: name, avatarHash: avatarHash, members: members)
    }
}
