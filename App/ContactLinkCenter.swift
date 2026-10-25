import Contacts
import Foundation
import MessageStore
import MessagingCore
import Observation
import os

/// The signed-in account's links between direct chats and contacts (`ContactLink`), for the chat list, the details and
/// the Contacts flows. Owns the photo files it writes and keeps the stored rows current with Contacts: on load, when the
/// app returns to the foreground and when Contacts changes. A link is only ever made or removed by the user.
@MainActor @Observable
final class ContactLinkCenter {
    /// How a link stands for its row in chat details.
    enum Status: Equatable {
        /// The contact is readable: the system is told who the person is.
        case linked
        /// Made, or kept, without Contacts access: the name names the chat in Haus only.
        case nameOnly
        /// Access is there but the contact is not: deleted, its identifier changed, or left out of the limited set.
        case missing
    }

    /// By chat address.
    private(set) var links: [String: ContactLink] = [:]
    /// Linked contacts' photos by chat address, decoded from the pre-scaled files.
    private(set) var photos: [String: PlatformImage] = [:]
    private(set) var access = ContactDirectory.access
    /// A Contact row action asked for from elsewhere (the Mac's chat menus); the chat's row starts it and clears it.
    var request: ContactRowRequest?
    /// Called after links change, so the chat list can rename its rows.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private(set) var account = ""
    @ObservationIgnored private var store: MessageStore?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var refreshedAccount: String?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "contacts")

    init() {
        observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }
    }

    func status(for jid: String) -> Status? {
        guard let link = links[jid] else { return nil }
        if link.isReachable { return .linked }
        return access.readsContacts ? .missing : .nameOnly
    }

    /// Reads the account's links (each chat-list load); the first load for an account also checks them against Contacts.
    func load(store: MessageStore, account: String, root: URL?) async {
        if account != self.account { links = [:]; photos = [:]; refreshedAccount = nil }
        self.store = store; self.account = account; self.root = root
        guard !account.isEmpty, let stored = try? await store.contactLinks(accountID: account), self.account == account else { return }
        apply(stored)
        if refreshedAccount != account { refreshedAccount = account; refreshSoon() }
    }

    /// Signed out, or the store closed: nothing is shown or written for the old account.
    func reset() {
        refreshing?.cancel(); refreshing = nil
        store = nil; account = ""; root = nil; refreshedAccount = nil
        if !links.isEmpty || !photos.isEmpty { links = [:]; photos = [:]; onChange?() }
    }

    func requestAccess() async -> ContactAccess {
        access = await ContactDirectory.requestAccess()
        return access
    }

    /// The unique readable contact whose Jabber address is the chat's, unless it is already the linked one.
    func suggestion(for jid: String) async -> ContactCard? {
        access = ContactDirectory.access
        guard access.readsContacts else { return nil }
        let card = await Task.detached { ContactDirectory().suggestion(for: jid) }.value
        return card?.id == links[jid]?.contactIdentifier && links[jid]?.isReachable == true ? nil : card
    }

    func readableCards() async -> [ContactCard] {
        access = ContactDirectory.access
        return await Task.detached { ContactDirectory().cards() }.value
    }

    /// Links the chat to a contact the user chose. `card` may come from a picker without access: then it names the chat
    /// in Haus only, until access covers it.
    func link(_ jid: String, to card: ContactCard, source: ContactLink.Source) async -> Bool {
        guard let store, !account.isEmpty, jid != account else { return false }
        let account = account
        access = ContactDirectory.access
        // Read again with the app's own access: a picker hands over a contact the app may not be able to read later.
        let readable = await Task.detached { ContactDirectory().card(identifier: card.id) }.value
        let current = readable ?? card
        let previous = links[jid]
        let hash = current.thumbnail.flatMap { thumbnail in root.flatMap { ContactPhoto.save(thumbnail, root: $0, account: account) } }
        let link = ContactLink(accountID: account, jid: jid, contactIdentifier: card.id, source: source,
                               displayName: current.name.isEmpty ? nil : current.name, imageHash: hash,
                               usesContactPhoto: previous?.usesContactPhoto ?? false, isReachable: readable != nil, checkedAt: Date())
        do {
            let replaced = try await store.saveContactLink(link)
            await removePhoto(of: replaced, keeping: hash)
            // Another contact than before: what the system learnt about the old one goes.
            if let replaced, replaced.contactIdentifier != link.contactIdentifier { await deleteDonations(jid) }
        } catch {
            Self.log.error("link failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
        guard self.account == account else { return true }
        set(link)
        return true
    }

    /// Unlinks the chat, removes the contact's photo, and deletes the donations that told the system about the person.
    func unlink(_ jid: String) async {
        guard let store, !account.isEmpty else { return }
        let account = account
        guard let removed = try? await store.removeContactLink(accountID: account, jid: jid) else { return }
        await removePhoto(of: removed, keeping: nil)
        await deleteDonations(jid)
        guard self.account == account else { return }
        links[jid] = nil; photos[jid] = nil
        onChange?()
    }

    func setUsesContactPhoto(_ uses: Bool, for jid: String) async {
        guard let store, var link = links[jid], link.usesContactPhoto != uses else { return }
        link.usesContactPhoto = uses
        guard (try? await store.updateContactLink(link)) != nil, link.accountID == account else { return }
        set(link)
    }

    /// Checks every link against Contacts soon, once: repeated change notifications collapse into one pass.
    func refreshSoon() {
        guard refreshing == nil, store != nil, !account.isEmpty else { return }
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.refresh()
            self?.refreshing = nil
        }
    }

    /// Reads each linked contact again: a changed name or photo is cached, a contact that cannot be read keeps its
    /// cached name and is no longer offered to the system. Never links or unlinks anything.
    func refresh() async {
        guard let store, !account.isEmpty else { return }
        let account = account, root = root
        access = ContactDirectory.access
        let readsContacts = access.readsContacts
        var reachable = 0
        defer { Self.log.notice("contact links checked: \(self.links.count, privacy: .public), readable: \(reachable, privacy: .public)") }
        for var link in links.values.sorted(by: { $0.jid < $1.jid }) {
            let identifier = link.contactIdentifier
            let card = readsContacts ? await Task.detached { ContactDirectory().card(identifier: identifier) }.value : nil
            let before = link
            link.isReachable = card != nil
            if card != nil { reachable += 1 }
            if let card {
                if !card.name.isEmpty { link.displayName = card.name }
                link.imageHash = card.thumbnail.flatMap { thumbnail in root.flatMap { ContactPhoto.save(thumbnail, root: $0, account: account) } }
            }
            link.checkedAt = Date()
            guard let replaced = try? await store.updateContactLink(link) else { continue }
            if replaced.imageHash != link.imageHash { await removePhoto(of: replaced, keeping: link.imageHash) }
            guard self.account == account else { return }
            if before.displayName != link.displayName || before.imageHash != link.imageHash || before.isReachable != link.isReachable {
                set(link)
            } else {
                links[link.jid] = link
            }
        }
    }

    private func apply(_ stored: [ContactLink]) {
        let next = Dictionary(stored.map { ($0.jid, $0) }, uniquingKeysWith: { first, _ in first })
        guard next != links else { return }
        let changedPhotos = next.filter { links[$0.key]?.imageHash != $0.value.imageHash || photos[$0.key] == nil }
        links = next
        for jid in photos.keys where next[jid]?.imageHash == nil { photos[jid] = nil }
        for (jid, link) in changedPhotos { photos[jid] = image(link.imageHash) }
        onChange?()
    }

    private func set(_ link: ContactLink) {
        if links[link.jid]?.imageHash != link.imageHash || photos[link.jid] == nil { photos[link.jid] = image(link.imageHash) }
        links[link.jid] = link
        onChange?()
    }

    private func image(_ hash: String?) -> PlatformImage? {
        guard let hash, let root else { return nil }
        return AvatarStore.image(root: root, account: account, hash: hash).map { PlatformImage(cgImage: $0) }
    }

    /// Removes a replaced link's photo file once nothing names it any more.
    private func removePhoto(of link: ContactLink?, keeping kept: String?) async {
        guard let hash = link?.imageHash, hash != kept, let store, let root, let account = link?.accountID,
              (try? await store.isAvatarHashInUse(accountID: account, hash: hash)) == false else { return }
        ContactPhoto.remove(hash, root: root, account: account)
    }

    private func deleteDonations(_ jid: String) async {
        await CommunicationHistory.delete(conversation: NotificationIdentity.thread(accountID: account, chatID: jid))
    }
}
