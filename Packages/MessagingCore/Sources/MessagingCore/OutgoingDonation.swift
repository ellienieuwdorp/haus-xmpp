#if canImport(Intents)
import Foundation
import Intents
import os

/// One conversation the user just sent to, as the system's suggestions learn it (Apple, "Supporting suggestions in your
/// app's share extension", accessed 2026-10-25). Local, authenticated state only; never logged.
public struct OutgoingConversation: Sendable, Equatable, CustomStringConvertible {
    /// The account that sent.
    public let accountID: String
    /// `NotificationIdentity.thread`: the same identifier the chat's communication notifications carry, so the share
    /// sheet, the notifications and a preselected chat name one conversation, and its donations delete together.
    public let conversationIdentifier: String
    /// The peer of a direct chat, or the room members this device knows of. Never the account itself.
    public let recipients: [NotificationCommunication.Person]
    /// The room's title; nil for a direct chat.
    public let groupName: String?
    public let groupAvatarHash: String?

    public init(accountID: String, conversationIdentifier: String, recipients: [NotificationCommunication.Person], groupName: String? = nil,
                groupAvatarHash: String? = nil) {
        self.accountID = accountID; self.conversationIdentifier = conversationIdentifier; self.recipients = recipients
        self.groupName = groupName; self.groupAvatarHash = groupAvatarHash
    }

    /// A direct chat: the chat is the person.
    public static func direct(accountID: String, chatID: String, displayName: String, avatarHash: String?) -> OutgoingConversation {
        OutgoingConversation(accountID: accountID, conversationIdentifier: NotificationIdentity.thread(accountID: accountID, chatID: chatID),
                             recipients: [.init(handle: chatID, displayName: displayName, avatarHash: avatarHash)])
    }

    /// A room: its title and up to eight known members other than the account, as the room's notifications list them.
    public static func room(accountID: String, room: String, title: String, avatarHash: String?,
                            members: [NotificationCommunication.Person]) -> OutgoingConversation {
        OutgoingConversation(accountID: accountID, conversationIdentifier: NotificationIdentity.thread(accountID: accountID, chatID: room),
                             recipients: Array(members.filter { $0.handle != accountID && $0.handle != room }.prefix(8)),
                             groupName: title, groupAvatarHash: avatarHash)
    }

    public var isGroup: Bool { groupName != nil }
    public var description: String { "OutgoingConversation(<redacted>)" }
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

    /// Donates one interaction per conversation, best effort and bounded: a failure is logged (domain and code only)
    /// and never holds back the send.
    public static func donate(_ conversations: [OutgoingConversation], avatar: (String) -> Data?,
                              donate: @escaping CommunicationNotification.Donate = CommunicationNotification.systemDonate,
                              timeout: Duration = .milliseconds(1500)) async {
        for conversation in conversations {
            let interaction = UncheckedInteraction(value: interaction(for: intent(conversation, avatar: avatar)))
            do { try await withTimeout(timeout) { try await donate(interaction.value) } }
            catch { log.notice("outgoing donation failed: \(CommunicationNotification.describe(error), privacy: .public)") }
        }
    }
}

extension CommunicationHistory {
    /// Deletes one conversation's donations, in both directions (`groupIdentifier` is its conversation identifier).
    public typealias DeleteConversation = @Sendable (_ conversationIdentifier: String) async throws -> Void

    /// Best effort, like `deleteAll`: blocking a contact or leaving a room must not wait on the system.
    public static func deleteConversations(_ conversationIdentifiers: [String],
                                           delete: @escaping DeleteConversation = { try await INInteraction.delete(with: $0) }) async {
        for identifier in conversationIdentifiers {
            do { try await delete(identifier) }
            catch { log.notice("conversation donation deletion failed: \(CommunicationNotification.describe(error), privacy: .public)") }
        }
    }
}

private let log = Logger(subsystem: "haus.xmpp.ios", category: "notifications")

/// `INInteraction` is not Sendable; it is created, donated and dropped by one call.
private struct UncheckedInteraction: @unchecked Sendable { let value: INInteraction }
#endif
