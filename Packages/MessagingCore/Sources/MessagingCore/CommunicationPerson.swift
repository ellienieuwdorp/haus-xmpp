#if canImport(Intents)
import Foundation
import Intents

/// The one place an `INPerson` is built. Incoming communication notifications, outgoing donations and the share
/// extension all call it, so the system sees the same person for a contact wherever the app names them.
public enum CommunicationPerson {
    /// `avatar` returns a pre-scaled image's bytes for a verified avatar hash; nothing here decodes an image.
    public static func person(_ value: NotificationCommunication.Person, avatar: (String) -> Data?, isMe: Bool = false) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: value.handle, type: .unknown), nameComponents: nil, displayName: value.displayName,
                 image: value.avatarHash.flatMap(avatar).map { INImage(imageData: $0) }, contactIdentifier: nil,
                 customIdentifier: value.handle, isMe: isMe)
    }
}
#endif
