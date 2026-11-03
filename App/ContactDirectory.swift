import Contacts
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XMPPProtocol

// iOS 18 limited access reads only contacts the user shared with the app or it created. The Mac has full or none.
enum ContactAccess: Equatable, Sendable {
    case notDetermined, limited, full, denied

    init(_ status: CNAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .notDetermined: self = .notDetermined
        #if os(iOS)
        case .limited: self = .limited
        #endif
        default: self = .denied
        }
    }

    var readsContacts: Bool { self == .full || self == .limited }
}

// Reads no emails, phone numbers or notes.
struct ContactCard: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let thumbnail: Data?
    let jabberAddresses: [String]

    init(id: String, name: String, thumbnail: Data?, jabberAddresses: [String]) {
        self.id = id; self.name = name; self.thumbnail = thumbnail; self.jabberAddresses = jabberAddresses
    }

    // A picker's contact may lack some keys; reads only those it was fetched with.
    init(_ contact: CNContact) {
        id = contact.identifier
        name = ContactDirectory.name(of: contact)
        thumbnail = contact.isKeyAvailable(CNContactThumbnailImageDataKey) ? contact.thumbnailImageData : nil
        jabberAddresses = contact.isKeyAvailable(CNContactInstantMessageAddressesKey)
            ? contact.instantMessageAddresses.compactMap { ContactDirectory.jabberAddress($0.value) } : []
    }
}

// Synchronous; callers run them off the main actor. Nothing read here leaves the device or reaches a log.
struct ContactDirectory: Sendable {
    static var access: ContactAccess { ContactAccess(CNContactStore.authorizationStatus(for: .contacts)) }

    static func requestAccess() async -> ContactAccess {
        guard access == .notDetermined else { return access }
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        return access
    }

    static var keys: [any CNKeyDescriptor] { [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactIdentifierKey as NSString,
        CNContactOrganizationNameKey as NSString, CNContactNicknameKey as NSString,
        CNContactInstantMessageAddressesKey as NSString, CNContactThumbnailImageDataKey as NSString
    ] }
    private static var listKeys: [any CNKeyDescriptor] { [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactIdentifierKey as NSString,
        CNContactOrganizationNameKey as NSString, CNContactNicknameKey as NSString, CNContactInstantMessageAddressesKey as NSString
    ] }

    func card(identifier: String) -> ContactCard? {
        guard Self.access.readsContacts else { return nil }
        return (try? CNContactStore().unifiedContact(withIdentifier: identifier, keysToFetch: Self.keys)).map(ContactCard.init)
    }

    func cards() -> [ContactCard] {
        guard Self.access.readsContacts else { return [] }
        let request = CNContactFetchRequest(keysToFetch: Self.listKeys)
        request.sortOrder = .userDefault
        var cards: [ContactCard] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in cards.append(ContactCard(contact)) }
        return cards
    }

    // Nil when several contacts claim the address, so an old or shared address never picks one for the user.
    func suggestion(for jid: String) -> ContactCard? {
        let matches = cards().filter { $0.jabberAddresses.contains(jid) }
        guard matches.count == 1, let match = matches.first else { return nil }
        return card(identifier: match.id) ?? match
    }

    static func name(of contact: CNContact) -> String {
        if let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty { return name }
        if contact.isKeyAvailable(CNContactOrganizationNameKey), !contact.organizationName.isEmpty { return contact.organizationName }
        if contact.isKeyAvailable(CNContactNicknameKey), !contact.nickname.isEmpty { return contact.nickname }
        return ""
    }

    static func jabberAddress(_ address: CNInstantMessageAddress) -> String? {
        let service = address.service.lowercased()
        guard service == CNInstantMessageServiceJabber.lowercased() || service == "xmpp" else { return nil }
        var username = address.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.lowercased().hasPrefix("xmpp:") { username.removeFirst(5) }
        return JID.normalizedBare(username)
    }
}

// Stored beside the verified avatars with the pre-scaled copy the notification extension reads. App only.
enum ContactPhoto {
    static func save(_ thumbnail: Data, root: URL, account: String) -> String? {
        guard let source = CGImageSourceCreateWithData(thumbnail as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= AvatarStore.maximumPixels, height <= AvatarStore.maximumPixels,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: AvatarStore.thumbnailPixels,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= AvatarStore.maximumNotificationImageBytes else { return nil }
        let png = data as Data
        let hash = Insecure.SHA1.hash(data: png).map { String(format: "%02x", $0) }.joined()
        guard (try? AvatarStore.save(png, root: root, account: account, hash: hash)) != nil,
              AvatarStore.saveNotificationImage(root: root, account: account, hash: hash) else { return nil }
        return hash
    }

    static func remove(_ hash: String, root: URL, account: String) {
        for file in AvatarStore.files(root: root, account: account, hash: hash) { try? FileManager.default.removeItem(at: file) }
    }
}

// The user sees and edits it (system editor on iPhone, a confirmation on Mac) before anything is written.
enum ContactDraft {
    static let urlLabel = "XMPP"

    static func contact(name: String, jid: String, photo: Data?) -> CNMutableContact {
        let contact = CNMutableContact()
        // A name is never split or guessed from an address.
        contact.givenName = name
        contact.instantMessageAddresses = [CNLabeledValue(label: CNLabelOther,
                                                          value: CNInstantMessageAddress(username: jid, service: CNInstantMessageServiceJabber))]
        contact.urlAddresses = [CNLabeledValue(label: urlLabel, value: "xmpp:\(jid)" as NSString)]
        contact.imageData = photo
        return contact
    }
}
