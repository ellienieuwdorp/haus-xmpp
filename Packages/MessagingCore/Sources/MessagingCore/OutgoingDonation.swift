#if canImport(Intents)
import Foundation
import Intents
import MessageStore
import os

/// A conversation the user just sent to, for share-sheet suggestions. Local, authenticated state only; never logged.
public struct OutgoingConversation: Sendable, Equatable, CustomStringConvertible {
    public let accountID: String
    public let chatID: String
    /// `NotificationIdentity.thread`, so the share sheet and the notifications name one conversation and its
    /// donations delete together.
    public let conversationIdentifier: String
    /// Never the account itself.
    public let recipients: [NotificationCommunication.Person]
    /// Nil for a direct chat.
    public let groupName: String?
    public let groupAvatarHash: String?

    public init(accountID: String, chatID: String, recipients: [NotificationCommunication.Person], groupName: String? = nil,
                groupAvatarHash: String? = nil) {
        self.accountID = accountID; self.chatID = chatID; self.recipients = recipients
        conversationIdentifier = NotificationIdentity.thread(accountID: accountID, chatID: chatID)
        self.groupName = groupName; self.groupAvatarHash = groupAvatarHash
    }

    public static func direct(accountID: String, chatID: String, displayName: String, avatarHash: String?,
                              contactIdentifier: String? = nil) -> OutgoingConversation {
        OutgoingConversation(accountID: accountID, chatID: chatID, recipients: [.init(handle: chatID, displayName: displayName, avatarHash: avatarHash,
                                                                                      contactIdentifier: contactIdentifier)])
    }

    /// Up to eight known members other than the account, as the room's notifications list them.
    public static func room(accountID: String, room: String, title: String, avatarHash: String?,
                            members: [NotificationCommunication.Person]) -> OutgoingConversation {
        OutgoingConversation(accountID: accountID, chatID: room,
                             recipients: Array(members.filter { $0.handle != accountID && $0.handle != room }.prefix(8)),
                             groupName: title, groupAvatarHash: avatarHash)
    }

    public var isGroup: Bool { groupName != nil }
    public var description: String { "OutgoingConversation(<redacted>)" }

    func linkingContactsAsStored(store: MessageStore) async -> OutgoingConversation {
        var linked: [NotificationCommunication.Person] = []
        for person in recipients { linked.append(await CommunicationHistory.linkedNow(person, accountID: accountID, store: store)) }
        return OutgoingConversation(accountID: accountID, chatID: chatID, recipients: linked, groupName: groupName, groupAvatarHash: groupAvatarHash)
    }
}

/// One outgoing `INSendMessageIntent` per user send action, donated once the message is durably queued. It records
/// that the user wrote to someone, not that anything was delivered, and never carries the message text.
public enum OutgoingDonation {
    /// Previews off promises that no name or avatar stays with the system.
    public static func isAllowed(previews: Bool, suggestions: Bool) -> Bool { previews && suggestions }

    /// `avatar` returns a pre-scaled image's bytes for a verified hash.
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

    public static func interaction(for intent: INSendMessageIntent) -> INInteraction {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = intent.conversationIdentifier
        return interaction
    }

    /// Best effort; never throws. `allowed` is asked before and again after each donation, because one in flight
    /// during a deletion (sign-out, previews or suggestions off, a block) would restore what it removed; a
    /// conversation no longer allowed is deleted again. A contact link that changed in flight deletes the
    /// conversation's donations too. System calls are awaited however long they take, so run this detached.
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
