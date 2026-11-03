import CryptoKit
import Foundation
#if canImport(Intents)
import Intents
#endif

/// Builds every `INPerson`, so one person has one identity everywhere.
/// - Handle: the bare JID, type unknown. Claiming email or phone would let the system attach an address-book name
///   and photo to whoever controls that address.
/// - `suggestionType`: `.instantMessageAddress` for others (Apple's advice for app-specific handles), `.none` for me.
/// - `customIdentifier`: opaque and account-scoped, so one JID in two accounts stays two people.
/// - `contactIdentifier`: only for a user-made link the app can currently read.
public enum CommunicationPerson {
    /// Separate from `INPerson` because `INPerson.contactIdentifier` reads nil in a process without Contacts access.
    public struct Fields: Sendable, Equatable {
        public let handle: String
        public let displayName: String
        public let contactIdentifier: String?
        public let customIdentifier: String
        public let isMe: Bool
        public let suggestsInstantMessageAddress: Bool
    }

    /// Stable across launches and processes.
    public static func identifier(accountID: String, jid: String) -> String {
        "p1-" + SHA256.hash(data: Data(("haus-person-v1\u{0}" + accountID + "\u{0}" + jid).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func fields(_ person: NotificationCommunication.Person, accountID: String, isMe: Bool = false) -> Fields {
        Fields(handle: person.handle, displayName: person.displayName, contactIdentifier: isMe ? nil : person.contactIdentifier,
               customIdentifier: identifier(accountID: accountID, jid: person.handle), isMe: isMe, suggestsInstantMessageAddress: !isMe)
    }

    #if canImport(Intents)
    /// `image` is pre-scaled bytes; nothing is decoded here.
    public static func person(_ person: NotificationCommunication.Person, accountID: String, isMe: Bool = false, image: Data?) -> INPerson {
        let fields = fields(person, accountID: accountID, isMe: isMe)
        return INPerson(personHandle: INPersonHandle(value: fields.handle, type: .unknown), nameComponents: nil, displayName: fields.displayName,
                        image: image.map { INImage(imageData: $0) }, contactIdentifier: fields.contactIdentifier,
                        customIdentifier: fields.customIdentifier, isMe: fields.isMe,
                        suggestionType: fields.suggestsInstantMessageAddress ? .instantMessageAddress : .none)
    }
    #endif
}
