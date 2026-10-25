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
    private(set) var access: ContactAccess
    /// A Contact row action asked for from elsewhere (the Mac's chat menus); the chat's row starts it and clears it.
    var request: ContactRowRequest?
    /// Called after links change, so the chat list can rename its rows.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private(set) var account = ""
    @ObservationIgnored private var store: MessageStore?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var refreshedAccount: String?
    /// The pending or running `refreshSoon` pass.
    @ObservationIgnored private(set) var refreshing: Task<Void, Never>?
    /// The last change asked for (`serially`).
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "contacts")

    /// How the center reads Contacts: the access it has and one contact by identifier (`ContactDirectory`). Tests read
    /// synthetic cards instead.
    struct Reader: Sendable {
        var access: @Sendable () -> ContactAccess = { ContactDirectory.access }
        var card: @Sendable (_ identifier: String) -> ContactCard? = { ContactDirectory().card(identifier: $0) }
    }
    @ObservationIgnored private let reader: Reader

    init(reader: Reader = Reader()) {
        self.reader = reader
        access = reader.access()
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
        guard !account.isEmpty else { return }
        await serially { [self] in
            guard self.account == account, let stored = try? await store.contactLinks(accountID: account), self.account == account else { return }
            apply(stored)
        }
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
        access = reader.access()
        guard access.readsContacts else { return nil }
        let card = await Task.detached { ContactDirectory().suggestion(for: jid) }.value
        return card?.id == links[jid]?.contactIdentifier && links[jid]?.isReachable == true ? nil : card
    }

    func readableCards() async -> [ContactCard] {
        access = reader.access()
        return await Task.detached { ContactDirectory().cards() }.value
    }

    /// Links the chat to a contact the user chose. `card` may come from a picker without access: then it names the chat
    /// in Haus only, until access covers it.
    func link(_ jid: String, to card: ContactCard, source: ContactLink.Source) async -> Bool {
        guard store != nil, !account.isEmpty, jid != account else { return false }
        let account = account, reader = reader
        access = reader.access()
        return await serially { [self] in
            // Read again with the app's own access: a picker hands over a contact the app may not be able to read later.
            let readable = await Task.detached { reader.card(card.id) }.value
            guard let store, self.account == account else { return false }
            let current = readable ?? card
            let hash = savePhoto(current.thumbnail, account: account)
            let link = ContactLink(accountID: account, jid: jid, contactIdentifier: card.id, source: source,
                                   displayName: current.name.isEmpty ? nil : current.name, imageHash: hash,
                                   usesContactPhoto: links[jid]?.usesContactPhoto ?? false, isReachable: readable != nil, checkedAt: Date())
            let change: ContactLinkChange
            do { change = try await store.saveContactLink(link) } catch {
                Self.log.error("link failed: \(String(describing: type(of: error)), privacy: .public)")
                await removePhoto(hash, account: account)
                return false
            }
            if self.account == account { set(change.saved) }
            await removePhoto(change.replaced?.imageHash, account: account, keeping: hash)
            // Another contact than before: what the system learnt about the old one goes.
            if let replaced = change.replaced, replaced.contactIdentifier != link.contactIdentifier { await deleteDonations(jid, account: account) }
            return true
        }
    }

    /// Unlinks the chat, removes the contact's photo, and deletes the donations that told the system about the person.
    func unlink(_ jid: String) async {
        await serially { [self] in
            guard let store, !account.isEmpty else { return }
            let account = account
            guard let removed = try? await store.removeContactLink(accountID: account, jid: jid) else { return }
            if self.account == account {
                links[jid] = nil; photos[jid] = nil
                onChange?()
            }
            await removePhoto(removed.imageHash, account: account)
            await deleteDonations(jid, account: account)
        }
    }

    func setUsesContactPhoto(_ uses: Bool, for jid: String) async {
        await serially { [self] in
            guard let store, let link = links[jid], link.usesContactPhoto != uses else { return }
            let account = account
            guard let saved = try? await store.setContactLinkUsesContactPhoto(uses, accountID: account, jid: jid, generation: link.generation),
                  self.account == account else { return }
            set(saved)
        }
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
    /// cached name and is no longer offered to the system. Never links or unlinks anything. Contacts is read outside
    /// the queue of changes; each result is written to the link it was read for only (`refreshContactLink`).
    func refresh() async {
        guard store != nil, !account.isEmpty else { return }
        let account = account, reader = reader
        access = reader.access()
        let readsContacts = access.readsContacts
        var reachable = 0
        defer { Self.log.notice("contact links checked: \(self.links.count, privacy: .public), readable: \(reachable, privacy: .public)") }
        for read in links.values.sorted(by: { $0.jid < $1.jid }) {
            let identifier = read.contactIdentifier
            let card = readsContacts ? await Task.detached { reader.card(identifier) }.value : nil
            if card != nil { reachable += 1 }
            let current = await serially { [self] () -> Bool in
                guard let store, self.account == account else { return false }
                var link = read
                link.isReachable = card != nil
                if let card {
                    // What the contact says now, also that it has no name: only a contact that cannot be read keeps its cache.
                    link.displayName = card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : card.name
                    link.imageHash = savePhoto(card.thumbnail, account: account)
                }
                link.checkedAt = Date()
                guard let change = try? await store.refreshContactLink(link) else {
                    // Unlinked or relinked meanwhile: the photo just written may be named by nothing.
                    await removePhoto(link.imageHash, account: account)
                    return true
                }
                let shown = links[link.jid]
                if shown?.displayName != change.saved.displayName || shown?.imageHash != change.saved.imageHash
                    || shown?.isReachable != change.saved.isReachable {
                    set(change.saved)
                } else {
                    links[link.jid] = change.saved
                }
                await removePhoto(change.replaced?.imageHash, account: account, keeping: change.saved.imageHash)
                return true
            }
            guard current else { return }
        }
    }

    /// Runs one change of the links after those asked for before it, in order: linking, unlinking, the photo switch,
    /// a refresh's write and a load never interleave, so each publishes what it committed and no photo file is
    /// removed while another change is about to name it.
    private func serially<T: Sendable>(_ change: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return await change()
        }
        queue = Task { _ = await task.value }
        return await task.value
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

    private func savePhoto(_ thumbnail: Data?, account: String) -> String? {
        guard let thumbnail, let root else { return nil }
        return ContactPhoto.save(thumbnail, root: root, account: account)
    }

    /// Removes a photo file once nothing names it any more: a replaced link's, or one written for a change that did not
    /// commit.
    private func removePhoto(_ hash: String?, account: String, keeping kept: String? = nil) async {
        guard let hash, hash != kept, let store, let root,
              (try? await store.isAvatarHashInUse(accountID: account, hash: hash)) == false else { return }
        ContactPhoto.remove(hash, root: root, account: account)
    }

    private func deleteDonations(_ jid: String, account: String) async {
        await CommunicationHistory.delete(conversation: NotificationIdentity.thread(accountID: account, chatID: jid))
    }
}
