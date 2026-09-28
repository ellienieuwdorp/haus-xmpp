#if canImport(Intents) && canImport(UserNotifications)
import Foundation
import Intents
import os
import UserNotifications

/// Turns a planned request into a communication notification (Apple, "Implementing communication notifications",
/// accessed 2026-09-28): an incoming `INSendMessageIntent` whose sender carries the contact's name and pre-scaled
/// avatar, donated as an `INInteraction`, then applied with `UNNotificationContent.updating(from:)`. Every failure falls
/// back to the plain request built from the same content, never to the gateway's generic alert.
public enum CommunicationNotification {
    /// Pure mapping from local state to the intent. `avatar` returns the bytes of a pre-scaled image for a verified
    /// avatar hash (the app writes them into the App Group); nothing here decodes an image.
    public static func intent(_ communication: NotificationCommunication, avatar: (String) -> Data?) -> INSendMessageIntent {
        func person(_ value: NotificationCommunication.Person, isMe: Bool = false) -> INPerson {
            INPerson(personHandle: INPersonHandle(value: value.handle, type: .unknown), nameComponents: nil, displayName: value.displayName,
                     image: value.avatarHash.flatMap(avatar).map { INImage(imageData: $0) }, contactIdentifier: nil,
                     customIdentifier: value.handle, isMe: isMe)
        }
        // A group names everyone who received it, the account included; a direct chat needs no recipients.
        let recipients = communication.isGroup ? [person(communication.account, isMe: true)] + communication.otherRecipients.map { person($0) } : nil
        let intent = INSendMessageIntent(recipients: recipients, outgoingMessageType: .outgoingMessageText, content: nil,
                                         speakableGroupName: communication.groupName.map { INSpeakableString(spokenPhrase: $0) },
                                         conversationIdentifier: communication.conversationIdentifier, serviceName: nil,
                                         sender: person(communication.sender), attachments: nil)
        #if os(iOS)
        if communication.isGroup, let hash = communication.groupAvatarHash, let data = avatar(hash) {
            intent.setImage(INImage(imageData: data), forParameterNamed: \.speakableGroupName)
        }
        #endif
        return intent
    }

    /// Donates the incoming interaction (bounded by `donationTimeout`) and returns the content updated from the intent,
    /// or nil when either step fails; the caller then posts `content` as it is. The result is not mutated further.
    public static func content(_ content: UNNotificationContent, intent: INSendMessageIntent, donate: Bool = true,
                               donationTimeout: Duration = .milliseconds(1500)) async -> UNNotificationContent? {
        if donate {
            let interaction = Unchecked(INInteraction(intent: intent, response: nil))
            interaction.value.direction = .incoming
            do { try await withTimeout(donationTimeout) { try await interaction.value.donate() } }
            catch { log.notice("communication donation failed: \(Self.describe(error), privacy: .public)"); return nil }
        }
        do { return try content.updating(from: intent) }
        catch { log.notice("communication update failed: \(Self.describe(error), privacy: .public)"); return nil }
    }
}

private let log = Logger(subsystem: "haus.xmpp.ios", category: "notifications")

extension CommunicationNotification {
    /// Domain and code only: never a name, handle or body.
    static func describe(_ error: any Error) -> String {
        if error is NotificationRunError { return "timeout" }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

/// `INInteraction` is not Sendable; it is created, donated and dropped by one call.
private struct Unchecked<Value>: @unchecked Sendable { let value: Value; init(_ value: Value) { self.value = value } }
#endif
