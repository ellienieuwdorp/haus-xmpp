import Contacts
import CryptoKit
import ImageIO
import MessageStore
import UIKit
import XCTest
@testable import HausXMPP

/// The pieces of contact linking that run without Contacts access: the contact "Add to Contacts" proposes (the Mac
/// saves the same draft), how a contact's Jabber address is read, the pre-scaled photo the extension reads, and how
/// `ContactLinkCenter` orders its changes, with synthetic cards in place of Contacts.
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

    // MARK: ContactLinkCenter

    private let me = "me@example.org", robin = "robin@example.org"

    /// Synthetic Contacts: full access, cards by identifier, and an optional gate that holds the next read until the
    /// test lets it go, so a change can be made while a refresh is reading.
    private final class SyntheticContacts: @unchecked Sendable {
        private let lock = NSLock()
        private var cards: [String: ContactCard] = [:]
        private var gate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
        subscript(identifier: String) -> ContactCard? {
            get { lock.withLock { cards[identifier] } }
            set { lock.withLock { cards[identifier] = newValue } }
        }
        func holdNextRead() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
            let gate = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            lock.withLock { self.gate = gate }
            return gate
        }
        func read(_ identifier: String) -> ContactCard? {
            if let gate = lock.withLock({ defer { self.gate = nil }; return self.gate }) { gate.entered.signal(); gate.release.wait() }
            return self[identifier]
        }
        var reader: ContactLinkCenter.Reader { ContactLinkCenter.Reader(access: { .full }, card: { self.read($0) }) }
        /// Blocks a detached task (never the main actor) until the held read has started.
        static func wait(for semaphore: DispatchSemaphore) { semaphore.wait() }
    }

    private func photo(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// A center on a fresh store, loaded for the account, its first refresh done.
    private func center(_ contacts: SyntheticContacts) async throws -> (ContactLinkCenter, MessageStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "contact-center-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MessageStore(url: root.appending(path: "messages.sqlite"))
        addTeardownBlock { try? await store.close(); try? FileManager.default.removeItem(at: root) }
        let center = ContactLinkCenter(reader: contacts.reader)
        await center.load(store: store, account: me, root: root)
        await center.refreshing?.value
        return (center, store, root)
    }

    private func photoFiles(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: AvatarStore.directory(root: root, account: me).path)) ?? []
    }

    /// Asked for in this order, a relink and then an unlink leave the chat unlinked, in the store and on screen.
    func testAnUnlinkAskedForAfterARelinkWinsInTheStoreAndOnScreen() async throws {
        let contacts = SyntheticContacts()
        contacts["A"] = ContactCard(id: "A", name: "Robin Okafor", thumbnail: nil, jabberAddresses: [])
        contacts["B"] = ContactCard(id: "B", name: "Robin Again", thumbnail: photo(.systemBlue), jabberAddresses: [])
        let (center, store, root) = try await center(contacts)
        let linked = await center.link(robin, to: try XCTUnwrap(contacts["A"]), source: .picker)
        XCTAssertTrue(linked)

        let relink = Task { await center.link(robin, to: contacts["B"]!, source: .picker) }
        let unlink = Task { await center.unlink(robin) }
        _ = await relink.value
        await unlink.value
        let stored = try await store.contactLink(accountID: me, jid: robin)
        XCTAssertNil(stored)
        XCTAssertNil(center.links[robin])
        XCTAssertNil(center.photos[robin])
        XCTAssertEqual(photoFiles(root), [], "B's photo went with the unlink")
    }

    /// The photo switch turned on while a refresh reads the contact survives the refresh's write, and the refresh's
    /// name still lands.
    func testThePhotoSwitchSurvivesARefreshThatReadTheLinkBefore() async throws {
        let contacts = SyntheticContacts()
        contacts["A"] = ContactCard(id: "A", name: "Robin Okafor", thumbnail: photo(.systemOrange), jabberAddresses: [])
        let (center, store, _) = try await center(contacts)
        _ = await center.link(robin, to: try XCTUnwrap(contacts["A"]), source: .picker)

        contacts["A"] = ContactCard(id: "A", name: "Robin O.", thumbnail: photo(.systemOrange), jabberAddresses: [])
        let gate = contacts.holdNextRead()
        let refresh = Task { await center.refresh() }
        await Task.detached { SyntheticContacts.wait(for: gate.entered) }.value
        await center.setUsesContactPhoto(true, for: robin)
        gate.release.signal()
        await refresh.value
        let stored = try await store.contactLink(accountID: me, jid: robin)
        XCTAssertEqual(stored?.usesContactPhoto, true)
        XCTAssertEqual(stored?.displayName, "Robin O.")
        XCTAssertEqual(center.links[robin], stored)
    }

    /// A refresh that read the contact before the user unlinked writes nothing and leaves no photo file behind; nor
    /// does a link the store refuses.
    func testARefusedRefreshOrLinkLeavesNoPhotoBehind() async throws {
        let contacts = SyntheticContacts()
        contacts["A"] = ContactCard(id: "A", name: "Robin Okafor", thumbnail: photo(.systemOrange), jabberAddresses: [])
        let (center, store, root) = try await center(contacts)
        _ = await center.link(robin, to: try XCTUnwrap(contacts["A"]), source: .picker)
        XCTAssertEqual(photoFiles(root).count, 2, "the photo and its notification copy")

        contacts["A"] = ContactCard(id: "A", name: "Robin Okafor", thumbnail: photo(.systemGreen), jabberAddresses: [])
        let gate = contacts.holdNextRead()
        let refresh = Task { await center.refresh() }
        await Task.detached { SyntheticContacts.wait(for: gate.entered) }.value
        await center.unlink(robin)
        gate.release.signal()
        await refresh.value
        let stored = try await store.contactLink(accountID: me, jid: robin)
        XCTAssertNil(stored)
        XCTAssertNil(center.links[robin])
        XCTAssertEqual(photoFiles(root), [])

        // An identifier the store refuses (longer than any contact store's).
        let refused = ContactCard(id: String(repeating: "x", count: 600), name: "Robin", thumbnail: photo(.systemPink), jabberAddresses: [])
        let linked = await center.link(robin, to: refused, source: .picker)
        XCTAssertFalse(linked)
        XCTAssertEqual(photoFiles(root), [])
    }

    /// A readable contact's name is taken as it is now, also when it has none; only one that cannot be read keeps the
    /// cached name.
    func testARefreshClearsANameTheContactNoLongerHas() async throws {
        let contacts = SyntheticContacts()
        contacts["A"] = ContactCard(id: "A", name: "Robin Okafor", thumbnail: nil, jabberAddresses: [])
        let (center, store, _) = try await center(contacts)
        _ = await center.link(robin, to: try XCTUnwrap(contacts["A"]), source: .picker)

        contacts["A"] = ContactCard(id: "A", name: "", thumbnail: nil, jabberAddresses: [robin])
        await center.refresh()
        var stored = try await store.contactLink(accountID: me, jid: robin)
        XCTAssertNil(stored?.displayName)
        XCTAssertNil(center.links[robin]?.name)
        XCTAssertEqual(stored?.isReachable, true)

        contacts["A"] = ContactCard(id: "A", name: "Robin Okafor", thumbnail: nil, jabberAddresses: [])
        await center.refresh()
        contacts["A"] = nil
        await center.refresh()
        stored = try await store.contactLink(accountID: me, jid: robin)
        XCTAssertEqual(stored?.displayName, "Robin Okafor", "a contact that cannot be read keeps its cached name")
        XCTAssertEqual(stored?.isReachable, false)
        XCTAssertEqual(center.links[robin]?.name, "Robin Okafor")
    }
}
