import Foundation

/// A direct chat's address linked, by the user, to a contact in this device's Contacts. Device-local: the identifier
/// only means something in this device's contact store, so the link is never sent anywhere, and nothing the contact
/// holds is written back to the roster, a vCard or PEP. The notification extension reads the cached name and photo and
/// never touches Contacts itself.
public struct ContactLink: Sendable, Equatable, CustomStringConvertible {
    /// How the link was made.
    public enum Source: String, Sendable, Equatable {
        /// The user picked the contact.
        case picker
        /// The user confirmed a suggested contact whose Jabber address equals the chat's.
        case imAddress = "im_address"
        /// The user created the contact (or added the address to one) from the chat.
        case created
    }

    public let accountID: String
    /// The chat's bare JID, in normal form.
    public let jid: String
    /// `CNContact.identifier`: a cache over the contact, meaningful on this device only.
    public var contactIdentifier: String
    public var source: Source
    /// The contact's formatted name when last read; the only address-book text stored.
    public var displayName: String?
    /// SHA-1 of the contact's pre-scaled photo, written with the avatars (`AvatarStore`); nil when it has none.
    public var imageHash: String?
    /// Show the contact's photo even when the peer publishes a verified avatar.
    public var usesContactPhoto: Bool
    /// At the last check this app could read the contact with its current Contacts access. Only then may the system
    /// be told who the person is (`INPerson.contactIdentifier`). False for a link made without access, and for a
    /// contact that was deleted or left the app's limited set.
    public var isReachable: Bool
    public var linkedAt: Date
    public var checkedAt: Date?
    /// The store's number for this link, new for every link and relink and never reused; 0 until saved. Writes that
    /// follow a link name it, so they never land on a link made since.
    public internal(set) var generation = 0

    public init(accountID: String, jid: String, contactIdentifier: String, source: Source, displayName: String? = nil, imageHash: String? = nil,
                usesContactPhoto: Bool = false, isReachable: Bool, linkedAt: Date = Date(), checkedAt: Date? = nil) {
        self.accountID = accountID; self.jid = jid; self.contactIdentifier = contactIdentifier; self.source = source
        self.displayName = displayName; self.imageHash = imageHash; self.usesContactPhoto = usesContactPhoto; self.isReachable = isReachable
        self.linkedAt = linkedAt; self.checkedAt = checkedAt
    }

    public var description: String { "ContactLink(<redacted>)" }

    /// The name a linked chat shows, ahead of its stored title. Name precedence: linked contact, then the stored title
    /// (a roster name or nickname once those exist), then the address's local part (`displayName(for:title:)` callers).
    public var name: String? { displayName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }

    /// The title to present for a chat: the linked contact's name when there is one, else the stored title.
    public static func title(_ stored: String?, link: ContactLink?) -> String? { link?.name ?? stored }

    /// Avatar precedence: the peer's verified avatar, then the contact's photo; the photo first when the user asked.
    public static func avatarHash(verified: String?, link: ContactLink?) -> String? {
        guard let photo = link?.imageHash else { return verified }
        return link?.usesContactPhoto == true ? photo : verified ?? photo
    }

    /// The identifier the system may be given: only for a link the app can currently read.
    public var usableContactIdentifier: String? { isReachable ? contactIdentifier : nil }

    func validate() throws {
        guard !accountID.isEmpty, !jid.isEmpty, jid != accountID, !contactIdentifier.isEmpty, contactIdentifier.utf8.count <= 512,
              (displayName?.utf8.count ?? 0) <= 1_024, imageHash.map(Self.isHash) ?? true,
              linkedAt.timeIntervalSince1970.isFinite, checkedAt.map { $0.timeIntervalSince1970.isFinite } ?? true
        else { throw MessageStoreError.invalidValue }
    }

    /// Lowercase hex SHA-1, as avatar files are named.
    static func isHash(_ hash: String) -> Bool {
        hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// What saving or refreshing a link wrote: the link as stored now, and the one it replaced.
public struct ContactLinkChange: Sendable, Equatable {
    public let saved: ContactLink
    public let replaced: ContactLink?
}

/// A link's photo file, named by account and hash (`AvatarStore` in the app).
public struct ContactLinkPhoto: Sendable, Equatable {
    public let accountID: String
    public let hash: String
}
