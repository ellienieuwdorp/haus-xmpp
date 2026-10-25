import Contacts
import CryptoKit
import ImageIO
import UIKit
import XCTest
@testable import HausXMPP

/// The pieces of contact linking that run without Contacts access: the contact "Add to Contacts" proposes (the Mac
/// saves the same draft), how a contact's Jabber address is read, and the pre-scaled photo the extension reads.
@MainActor final class ContactLinkingTests: XCTestCase {
    func testTheDraftCarriesTheJabberAddressTheXMPPLinkAndTheAvatarOnly() throws {
        let photo = Data([0x89, 0x50, 0x4E, 0x47])
        let draft = ContactDraft.contact(name: "Robin Okafor", jid: "robin@example.org", photo: photo)
        XCTAssertEqual(draft.givenName, "Robin Okafor", "one field, never split or guessed")
        XCTAssertEqual(draft.familyName, "")
        let address = try XCTUnwrap(draft.instantMessageAddresses.first?.value)
        XCTAssertEqual(address.username, "robin@example.org")
        XCTAssertEqual(address.service, CNInstantMessageServiceJabber)
        XCTAssertEqual(draft.urlAddresses.map { $0.value as String }, ["xmpp:robin@example.org"])
        XCTAssertEqual(draft.urlAddresses.first?.label, ContactDraft.urlLabel)
        XCTAssertEqual(draft.imageData, photo)
        XCTAssertTrue(draft.emailAddresses.isEmpty && draft.phoneNumbers.isEmpty)
        // What the Mac's vCard fallback writes is the same contact.
        let card = try CNContactVCardSerialization.data(with: [draft])
        let text = try XCTUnwrap(String(data: card, encoding: .utf8))
        XCTAssertTrue(text.contains("robin@example.org") && text.contains("xmpp:robin@example.org"))
    }

    func testOnlyJabberOrXMPPAddressesCountAndTheyAreReadInNormalForm() {
        func address(_ username: String, _ service: String) -> CNInstantMessageAddress { CNInstantMessageAddress(username: username, service: service) }
        XCTAssertEqual(ContactDirectory.jabberAddress(address("Robin@Example.ORG", CNInstantMessageServiceJabber)), "robin@example.org")
        XCTAssertEqual(ContactDirectory.jabberAddress(address(" xmpp:robin@example.org ", "XMPP")), "robin@example.org")
        XCTAssertNil(ContactDirectory.jabberAddress(address("robin@example.org", CNInstantMessageServiceGoogleTalk)), "a stale Google Talk field is not a match")
        XCTAssertNil(ContactDirectory.jabberAddress(address("not an address@@", CNInstantMessageServiceJabber)))
        let contact = CNMutableContact()
        contact.givenName = "Robin"
        contact.instantMessageAddresses = [CNLabeledValue(label: CNLabelHome, value: address("robin@example.org", CNInstantMessageServiceJabber)),
                                           CNLabeledValue(label: CNLabelWork, value: address("robin", CNInstantMessageServiceSkype))]
        let card = ContactCard(contact)
        XCTAssertEqual(card.name, "Robin")
        XCTAssertEqual(card.jabberAddresses, ["robin@example.org"])
    }

    func testAContactPhotoIsStoredPreScaledBesideTheAvatarsForTheExtension() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "contact-photo-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 900), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 900))
        }
        let hash = try XCTUnwrap(ContactPhoto.save(large, root: root, account: "me@example.org"))
        let bytes = try XCTUnwrap(AvatarStore.notificationImageData(root: root, account: "me@example.org", hash: hash))
        XCTAssertEqual(hash, Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "named by the stored bytes")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil)), 0, nil)
                                       as? [CFString: Any])
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, AvatarStore.thumbnailPixels)
        XCTAssertNil(ContactPhoto.save(Data("not an image".utf8), root: root, account: "me@example.org"))
        ContactPhoto.remove(hash, root: root, account: "me@example.org")
        XCTAssertNil(AvatarStore.notificationImageData(root: root, account: "me@example.org", hash: hash))
    }
}
