#if canImport(Intents)
import Foundation
import Intents

/// The one place an `INPerson` is built. Incoming communication notifications, outgoing donations and the share
/// extension all call it, so the system sees the same person for a contact wherever the app names them.
public enum CommunicationPerson {
    /// `image` is a pre-scaled image's bytes, already read; nothing here decodes an image. `accountID` is the account the
    /// person is seen from, for identifiers scoped to it.
    public static func person(_ value: NotificationCommunication.Person, accountID: String, isMe: Bool = false, image: Data?) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: value.handle, type: .unknown), nameComponents: nil, displayName: value.displayName,
                 image: image.map { INImage(imageData: $0) }, contactIdentifier: nil,
                 customIdentifier: value.handle, isMe: isMe)
    }
}
#endif
