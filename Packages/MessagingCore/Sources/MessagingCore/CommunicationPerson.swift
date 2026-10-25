import CryptoKit
import Foundation
#if canImport(Intents)
import Intents
#endif

/// The one way a person reaches the system (`INPerson`): incoming communication notifications, outgoing donations and
/// the share extension all call it, so the same person has the same identity everywhere (Apple, "INPerson" and
/// "Implementing communication notifications", accessed 2026-10-25):
///
/// - The handle is the bare JID with type unknown. A JID is not an email address or phone number, and claiming one
///   would let the system put an address-book name and photo on whoever controls that address.
/// - `suggestionType` is `.instantMessageAddress` for others, Apple's advice for app-specific handles; the account
///   itself keeps `.none`.
/// - `customIdentifier` is opaque and account-scoped (`identifier(accountID:jid:)`): the same JID in two accounts stays
///   two people, and the account's address stays out of it.
/// - `contactIdentifier` names a contact only for a link the user made that the app can currently read
///   (`ContactLink.usableContactIdentifier`). With previews off nothing is built at all.
public enum CommunicationPerson {
    /// What the builder sets, separate from `INPerson` so it can be checked anywhere: `INPerson.contactIdentifier`
    /// reads nil in a process without Contacts access.
    public struct Fields: Sendable, Equatable {
        public let handle: String
        public let displayName: String
        public let contactIdentifier: String?
        public let customIdentifier: String
        public let isMe: Bool
        /// True for `.instantMessageAddress`, false for `.none`.
        public let suggestsInstantMessageAddress: Bool
    }

    /// `"p1-"` and the hex SHA-256 of a versioned label, the account and the JID: stable across launches and processes.
    public static func identifier(accountID: String, jid: String) -> String {
        "p1-" + SHA256.hash(data: Data(("haus-person-v1\u{0}" + accountID + "\u{0}" + jid).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func fields(_ person: NotificationCommunication.Person, accountID: String, isMe: Bool = false) -> Fields {
        Fields(handle: person.handle, displayName: person.displayName, contactIdentifier: isMe ? nil : person.contactIdentifier,
               customIdentifier: identifier(accountID: accountID, jid: person.handle), isMe: isMe, suggestsInstantMessageAddress: !isMe)
    }

    #if canImport(Intents)
    /// The person, with `image` already read (pre-scaled bytes; nothing is decoded here).
    public static func person(_ person: NotificationCommunication.Person, accountID: String, isMe: Bool = false, image: Data?) -> INPerson {
        let fields = fields(person, accountID: accountID, isMe: isMe)
        return INPerson(personHandle: INPersonHandle(value: fields.handle, type: .unknown), nameComponents: nil, displayName: fields.displayName,
                        image: image.map { INImage(imageData: $0) }, contactIdentifier: fields.contactIdentifier,
                        customIdentifier: fields.customIdentifier, isMe: fields.isMe,
                        suggestionType: fields.suggestsInstantMessageAddress ? .instantMessageAddress : .none)
    }
    #endif
}
