#if canImport(Intents) && canImport(UserNotifications)
import Foundation
import Intents
import MessageStore
import os
import UserNotifications

/// An incoming `INSendMessageIntent`, donated as an `INInteraction` and applied with
/// `UNNotificationContent.updating(from:)`. Every failure falls back to the plain request built from the same
/// content, never to the gateway's generic alert.
public enum CommunicationNotification {
    /// `avatar` returns pre-scaled image bytes for a verified avatar hash; nothing here decodes an image.
    public static func intent(_ communication: NotificationCommunication, avatar: (String) -> Data?) -> INSendMessageIntent {
        func person(_ value: NotificationCommunication.Person, isMe: Bool = false) -> INPerson {
            CommunicationPerson.person(value, accountID: communication.account.handle, isMe: isMe, image: value.avatarHash.flatMap(avatar))
        }
        let recipients = communication.isGroup ? [person(communication.account, isMe: true)] + communication.otherRecipients.map { person($0) } : nil
        let intent = INSendMessageIntent(recipients: recipients, outgoingMessageType: .outgoingMessageText, content: nil,
                                         speakableGroupName: communication.groupName.map { INSpeakableString(spokenPhrase: $0) },
                                         conversationIdentifier: communication.conversationIdentifier, serviceName: nil,
                                         sender: person(communication.sender), attachments: nil)
        if communication.isGroup, let hash = communication.groupAvatarHash, let data = avatar(hash) {
            #if os(iOS)
            intent.setImage(INImage(imageData: data), forParameterNamed: \.speakableGroupName)
            #elseif os(macOS)
            // The KeyPath form is unavailable on macOS; the string-named Objective-C method it refines is not.
            intent.__setImage(INImage(imageData: data), forParameterNamed: "speakableGroupName")
            #endif
        }
        return intent
    }

    public typealias Donate = @Sendable (INInteraction) async throws -> Void

    public static let systemDonate: Donate = { interaction in
        let box = Unchecked(interaction)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.value.donate { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// The group identifier is the conversation identifier, so a conversation's donations can be deleted together.
    public static func interaction(for intent: INSendMessageIntent) -> INInteraction {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.groupIdentifier = intent.conversationIdentifier
        return interaction
    }

    /// Nil when the update fails; the caller then posts `content` unchanged. Do not mutate the result. A donation that
    /// fails or times out (a cold Intents service) is logged and the communication style is still applied.
    public static func content(_ content: UNNotificationContent, intent: INSendMessageIntent,
                               donate: Donate? = systemDonate,
                               donationTimeout: Duration = .milliseconds(1500), clock: some Clock<Duration> = ContinuousClock(),
                               update: (UNNotificationContent, INSendMessageIntent) throws -> UNNotificationContent = { try $0.updating(from: $1) })
    async -> UNNotificationContent? {
        if let donate {
            let interaction = Unchecked(interaction(for: intent))
            do { try await withTimeout(donationTimeout, clock: clock) { try await donate(interaction.value) } }
            catch { log.notice("communication donation failed: \(Self.describe(error), privacy: .public)") }
        }
        do { return try update(content, intent) }
        catch { log.notice("communication update failed: \(Self.describe(error), privacy: .public)"); return nil }
    }
}

/// Each donation holds a contact's address, name and avatar. Signing out, turning previews off and turning share
/// suggestions off delete them all (the app has one account); blocking, unlinking or relinking a contact deletes that
/// conversation's.
public enum CommunicationHistory {
    public typealias DeleteAll = @Sendable () async throws -> Void

    public static func purgesDonations(from old: AccountPreferences, to new: AccountPreferences) -> Bool {
        old.notificationPreviews && !new.notificationPreviews
    }

    /// Best effort: never blocks sign-out or the setting. False on failure, so turning share suggestions off can wait
    /// until the deletion went through.
    @discardableResult
    public static func deleteAll(_ delete: DeleteAll = { try await INInteraction.deleteAll() }) async -> Bool {
        do { try await delete(); return true }
        catch {
            log.notice("communication history deletion failed: \(CommunicationNotification.describe(error), privacy: .public)")
            return false
        }
    }

    /// Deletes one conversation's donations in both directions.
    public typealias DeleteConversation = @Sendable (_ conversationIdentifier: String) async throws -> Void

    /// Best effort: blocking, leaving a room or unlinking must not wait on the system.
    public static func deleteConversations(_ conversationIdentifiers: [String],
                                           delete: @escaping DeleteConversation = { try await INInteraction.delete(with: $0) }) async {
        for identifier in conversationIdentifiers {
            do { try await delete(identifier) }
            catch { log.notice("conversation donation deletion failed: \(CommunicationNotification.describe(error), privacy: .public)") }
        }
    }

    /// Re-reads the contact link before a donation: none once it is unlinked, relinked or unreadable.
    public static func linkedNow(_ person: NotificationCommunication.Person, accountID: String,
                                 store: MessageStore) async -> NotificationCommunication.Person {
        guard person.contactIdentifier != nil else { return person }
        let stored = (try? await store.contactLink(accountID: accountID, jid: person.handle))?.usableContactIdentifier
        return NotificationCommunication.Person(handle: person.handle, displayName: person.displayName, avatarHash: person.avatarHash,
                                                contactIdentifier: stored)
    }

    /// Run after every donation that named `people`. Unlinking deletes after its commit and this reads after the
    /// donation, so whichever runs last deletes the old association, in any process. A donation that outlived its
    /// own time limit can still land after both.
    public static func withdrawIfRelinked(_ people: [NotificationCommunication.Person], conversation: String, accountID: String,
                                          store: MessageStore,
                                          withdraw: @Sendable (String) async -> Void = { await deleteConversations([$0]) }) async {
        for person in people where person.contactIdentifier != nil {
            guard await linkedNow(person, accountID: accountID, store: store) == person else { return await withdraw(conversation) }
        }
    }
}

private let log = Logger(subsystem: "haus.xmpp.ios", category: "notifications")

extension CommunicationNotification {
    // Domain and code only: never a name, handle or body.
    static func describe(_ error: any Error) -> String {
        if error is NotificationRunError { return "timeout" }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

// `INInteraction` is not Sendable; it is created, donated and dropped by one call.
private struct Unchecked<Value>: @unchecked Sendable { let value: Value; init(_ value: Value) { self.value = value } }
#endif
