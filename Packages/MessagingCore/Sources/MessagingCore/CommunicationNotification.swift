#if canImport(Intents) && canImport(UserNotifications)
import Foundation
import Intents
import MessageStore
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
            CommunicationPerson.person(value, accountID: communication.account.handle, isMe: isMe, image: value.avatarHash.flatMap(avatar))
        }
        // A group names everyone who received it, the account included; a direct chat needs no recipients.
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

    /// Donates one interaction; injectable for tests.
    public typealias Donate = @Sendable (INInteraction) async throws -> Void

    /// The system donation, through its completion handler.
    public static let systemDonate: Donate = { interaction in
        let box = Unchecked(interaction)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.value.donate { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// The incoming interaction donated for one request. Its group identifier is the conversation identifier
    /// (`NotificationIdentity.thread`), so a conversation's donations can be deleted together (`CommunicationHistory`).
    public static func interaction(for intent: INSendMessageIntent) -> INInteraction {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.groupIdentifier = intent.conversationIdentifier
        return interaction
    }

    /// Donates the incoming interaction (bounded by `donationTimeout`), then returns the content updated from the
    /// intent, or nil when the update fails; the caller then posts `content` as it is. The result is not mutated further.
    /// The update does not depend on the donation: a donation that fails or times out (a cold Intents service) is logged
    /// and the communication style is still applied.
    public static func content(_ content: UNNotificationContent, intent: INSendMessageIntent,
                               donate: Donate? = systemDonate,
                               donationTimeout: Duration = .milliseconds(1500),
                               update: (UNNotificationContent, INSendMessageIntent) throws -> UNNotificationContent = { try $0.updating(from: $1) })
    async -> UNNotificationContent? {
        if let donate {
            let interaction = Unchecked(interaction(for: intent))
            do { try await withTimeout(donationTimeout) { try await donate(interaction.value) } }
            catch { log.notice("communication donation failed: \(Self.describe(error), privacy: .public)") }
        }
        do { return try update(content, intent) }
        catch { log.notice("communication update failed: \(Self.describe(error), privacy: .public)"); return nil }
    }
}

/// Deletes donated interactions (Apple, "INInteraction.deleteAll(completion:)", accessed 2026-09-28). Each donation
/// holds a contact's address, name and avatar and the conversation identifier; they feed system suggestions. Signing
/// out, turning previews off and turning share suggestions off delete them all: the app has one account, and previews
/// off means no name or avatar should stay with the system. Blocking a contact deletes that conversation's.
public enum CommunicationHistory {
    /// The deletion the app runs, injectable for tests.
    public typealias DeleteAll = @Sendable () async throws -> Void

    /// Whether a preferences change must delete the donations: previews went from shown to hidden.
    public static func purgesDonations(from old: AccountPreferences, to new: AccountPreferences) -> Bool {
        old.notificationPreviews && !new.notificationPreviews
    }

    /// Best effort: a failure is logged (domain and code only) and never blocks sign-out or the setting. False when the
    /// system reported a failure, so turning share suggestions off can stay on until the deletion went through.
    @discardableResult
    public static func deleteAll(_ delete: DeleteAll = { try await INInteraction.deleteAll() }) async -> Bool {
        do { try await delete(); return true }
        catch {
            log.notice("communication history deletion failed: \(CommunicationNotification.describe(error), privacy: .public)")
            return false
        }
    }

    /// Deletes one conversation's donations by their group identifier (`NotificationIdentity.thread`): after unlinking
    /// a contact, so the system forgets the person it learnt for that chat.
    public typealias DeleteGroup = @Sendable (String) async throws -> Void

    /// Best effort, like `deleteAll`.
    public static func delete(conversation identifier: String,
                              _ delete: DeleteGroup = { try await INInteraction.delete(with: $0) }) async {
        do { try await delete(identifier) }
        catch { log.notice("communication history deletion failed: \(CommunicationNotification.describe(error), privacy: .public)") }
    }

    /// The person as the store links them now, for a donation about to be made: the contact of a link the app can read
    /// (`ContactLink.usableContactIdentifier`), or none once it is unlinked, relinked or unreadable. A person named by
    /// no contact stays so.
    public static func linkedNow(_ person: NotificationCommunication.Person, accountID: String,
                                 store: MessageStore) async -> NotificationCommunication.Person {
        guard person.contactIdentifier != nil else { return person }
        let stored = (try? await store.contactLink(accountID: accountID, jid: person.handle))?.usableContactIdentifier
        return NotificationCommunication.Person(handle: person.handle, displayName: person.displayName, avatarHash: person.avatarHash,
                                                contactIdentifier: stored)
    }

    /// Runs after every donation that named `people`, incoming or outgoing: when one of their links changed while it
    /// was in flight, deletes the conversation's donations. Unlinking and relinking delete them after their commit and
    /// this reads after the donation, so whichever runs last deletes the old association, in this process or another.
    /// (A donation that outlived its own limit can still land after both.)
    public static func withdrawIfRelinked(_ people: [NotificationCommunication.Person], conversation: String, accountID: String,
                                          store: MessageStore,
                                          withdraw: @Sendable (String) async -> Void = { await delete(conversation: $0) }) async {
        for person in people where person.contactIdentifier != nil {
            guard await linkedNow(person, accountID: accountID, store: store) == person else { return await withdraw(conversation) }
        }
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
