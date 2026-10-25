#if canImport(Intents)
import Foundation
import Intents
import MessageStore
import os

/// One conversation the user just sent to, as the system's suggestions learn it (Apple, "Supporting suggestions in your
/// app's share extension", accessed 2026-10-25). Local, authenticated state only; never logged.
public struct OutgoingConversation: Sendable, Equatable, CustomStringConvertible {
    /// The account that sent.
    public let accountID: String
    /// The peer's address, or the room's.
    public let chatID: String
    /// `NotificationIdentity.thread`: the same identifier the chat's communication notifications carry, so the share
    /// sheet, the notifications and a preselected chat name one conversation, and its donations delete together.
    public let conversationIdentifier: String
    /// The peer of a direct chat, or the room members this device knows of. Never the account itself. A recipient's
    /// `contactIdentifier` follows the notifications' rule: a link the app can read (`ContactLink.usableContactIdentifier`).
    public let recipients: [NotificationCommunication.Person]
    /// The room's title; nil for a direct chat.
    public let groupName: String?
    public let groupAvatarHash: String?

    public init(accountID: String, chatID: String, recipients: [NotificationCommunication.Person], groupName: String? = nil,
                groupAvatarHash: String? = nil) {
        self.accountID = accountID; self.chatID = chatID; self.recipients = recipients
        conversationIdentifier = NotificationIdentity.thread(accountID: accountID, chatID: chatID)
        self.groupName = groupName; self.groupAvatarHash = groupAvatarHash
    }

    /// A direct chat: the chat is the person.
    public static func direct(accountID: String, chatID: String, displayName: String, avatarHash: String?,
                              contactIdentifier: String? = nil) -> OutgoingConversation {
        OutgoingConversation(accountID: accountID, chatID: chatID, recipients: [.init(handle: chatID, displayName: displayName, avatarHash: avatarHash,
                                                                                      contactIdentifier: contactIdentifier)])
    }

    /// A room: its title and up to eight known members other than the account, as the room's notifications list them.
    public static func room(accountID: String, room: String, title: String, avatarHash: String?,
                            members: [NotificationCommunication.Person]) -> OutgoingConversation {
        OutgoingConversation(accountID: accountID, chatID: room,
                             recipients: Array(members.filter { $0.handle != accountID && $0.handle != room }.prefix(8)),
                             groupName: title, groupAvatarHash: avatarHash)
    }

    public var isGroup: Bool { groupName != nil }
    public var description: String { "OutgoingConversation(<redacted>)" }

    /// The same conversation with each recipient named by a contact as the store links them now, not as the caller
    /// read them (`CommunicationHistory.linkedNow`).
    func linkingContactsAsStored(store: MessageStore) async -> OutgoingConversation {
        var linked: [NotificationCommunication.Person] = []
        for person in recipients { linked.append(await CommunicationHistory.linkedNow(person, accountID: accountID, store: store)) }
        return OutgoingConversation(accountID: accountID, chatID: chatID, recipients: linked, groupName: groupName, groupAvatarHash: groupAvatarHash)
    }
}

/// Outgoing `INSendMessageIntent` donations: one per user send action (a composer send, a notification Reply, a share),
/// donated once the message is durably queued. A donation records that the user wrote to someone, not that anything
/// was delivered, and never carries the message text.
public enum OutgoingDonation {
    /// Whether an account may donate at all: suggestions on, and message previews on, since previews off promises that
    /// no name or avatar stays with the system.
    public static func isAllowed(previews: Bool, suggestions: Bool) -> Bool { previews && suggestions }

    /// Pure mapping from the conversation to the intent. `avatar` returns a pre-scaled image's bytes for a verified hash.
    public static func intent(_ conversation: OutgoingConversation, avatar: (String) -> Data?) -> INSendMessageIntent {
        let intent = INSendMessageIntent(recipients: conversation.recipients.map {
                                             CommunicationPerson.person($0, accountID: conversation.accountID, image: $0.avatarHash.flatMap(avatar))
                                         },
                                         outgoingMessageType: .outgoingMessageText, content: nil,
                                         speakableGroupName: conversation.groupName.map { INSpeakableString(spokenPhrase: $0) },
                                         conversationIdentifier: conversation.conversationIdentifier, serviceName: nil,
                                         sender: nil, attachments: nil)
        if conversation.isGroup, let hash = conversation.groupAvatarHash, let data = avatar(hash) {
            #if os(iOS)
            intent.setImage(INImage(imageData: data), forParameterNamed: \.speakableGroupName)
            #elseif os(macOS)
            intent.__setImage(INImage(imageData: data), forParameterNamed: "speakableGroupName")
            #endif
        }
        return intent
    }

    /// The outgoing interaction, grouped by conversation like the incoming ones (`CommunicationNotification`).
    public static func interaction(for intent: INSendMessageIntent) -> INInteraction {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = intent.conversationIdentifier
        return interaction
    }

    /// Donates one interaction per conversation, best effort. `allowed` is asked right before each donation and again
    /// once the system has finished with it: a donation still in flight while a deletion ran (sign-out, previews or
    /// suggestions off, a block) would otherwise bring back what that deletion removed, so a conversation no longer
    /// allowed by then has its donations deleted again (`delete`). Contacts are handled as for notifications: each
    /// recipient is named by the contact `store` links now, and a link that changed while the donation was in flight
    /// deletes the conversation's donations afterwards (`CommunicationHistory.withdrawIfRelinked`), so an unlinked
    /// contact is never left donated. Each system call is awaited to its end, however long it takes, so callers run
    /// this detached. A failure is logged (domain and code only) and never throws.
    public static func donate(_ conversations: [OutgoingConversation], store: MessageStore, avatar: (String) -> Data?,
                              allowed: @escaping @Sendable (OutgoingConversation) async -> Bool,
                              donate: @escaping CommunicationNotification.Donate = CommunicationNotification.systemDonate,
                              delete: @escaping CommunicationHistory.DeleteConversation = { try await INInteraction.delete(with: $0) }) async {
        let withdraw: @Sendable (String) async -> Void = { await CommunicationHistory.deleteConversations([$0], delete: delete) }
        for planned in conversations {
            guard await allowed(planned) else { continue }
            let conversation = await planned.linkingContactsAsStored(store: store)
            do { try await donate(interaction(for: intent(conversation, avatar: avatar))) }
            catch { log.notice("outgoing donation failed: \(CommunicationNotification.describe(error), privacy: .public)") }
            guard await allowed(conversation) else {
                await withdraw(conversation.conversationIdentifier)
                continue
            }
            await CommunicationHistory.withdrawIfRelinked(conversation.recipients, conversation: conversation.conversationIdentifier,
                                                          accountID: conversation.accountID, store: store, withdraw: withdraw)
        }
    }
}

private let log = Logger(subsystem: "haus.xmpp.ios", category: "notifications")
#endif
