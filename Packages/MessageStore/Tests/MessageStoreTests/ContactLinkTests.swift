import Foundation
import Testing
@testable import MessageStore

private let verified = String(repeating: "a", count: 40), photo = String(repeating: "c", count: 40)

private func link(_ jid: String = "bob@x", account: String = "a", identifier: String = "contact-1", name: String? = "Bob Example",
                  imageHash: String? = nil, usesContactPhoto: Bool = false, reachable: Bool = true) -> ContactLink {
    ContactLink(accountID: account, jid: jid, contactIdentifier: identifier, source: .picker, displayName: name, imageHash: imageHash,
                usesContactPhoto: usesContactPhoto, isReachable: reachable, linkedAt: Date(timeIntervalSince1970: 1_000))
}

/// A stored link as it was saved, without the generation the store gave it.
private func unsaved(_ link: ContactLink?) -> ContactLink? {
    link.map { var link = $0; link.generation = 0; return link }
}

private func commit(_ store: MessageStore, _ id: String, chat: String, sender: String? = nil, at: TimeInterval, room: String? = nil) async throws {
    if try await store.encryptionStateRevision(accountID: "a") == nil {
        try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
    }
    let revision = try #require(try await store.encryptionStateRevision(accountID: "a"))
    try await store.commitEncryptedIncoming(accountID: "a", sender: sender ?? chat, digest: "d-" + id, expectedRevision: revision,
        state: Data([UInt8(revision % 250 + 1)]),
        message: StoredMessage(id: id, accountID: "a", chatID: chat, senderID: sender ?? chat, body: "Synthetic",
                               sentAt: Date(timeIntervalSince1970: at), encryptionProfile: "modern"), groupRoom: room)
}

struct ContactLinkTests {
    /// v27 adds the link table: a v26 store (or a branch that stamped 26 again) gains it and keeps its chats.
    @Test func aVersion26StoreGainsTheContactLinkTable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "contact-links-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let old = try MessageStore(url: url)
        try await old.upsertChat(accountID: "a", chatID: "bob@x", title: "bob@x")
        try await old.close()
        #expect(sqliteExecute(url: url, sql: "DROP TABLE contact_links; PRAGMA user_version=26"))

        // The second open is already at 27 and changes nothing.
        for _ in 0..<2 {
            let store = try MessageStore(url: url)
            #expect(try await store.chats(accountID: "a").map(\.id) == ["bob@x"])
            try await store.saveContactLink(link())
            #expect(unsaved(try await store.contactLink(accountID: "a", jid: "bob@x")) == link())
            try await store.close()
        }
        #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["27"]])
    }

    /// The previous release's real store (schema 25) migrates through 26 to 27 and can hold links.
    @Test func aPreviousReleaseStoreMigratesToContactLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "contact-links-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        try writePreviousReleaseStore(at: url, schema: 25)
        let store = try MessageStore(url: url)
        let account = try #require(try await store.storedAccountIDs().sorted().first)
        let chat = try #require(try await store.chats(accountID: account).first { $0.id != account })
        try await store.saveContactLink(link(chat.id, account: account))
        #expect(try await store.contactLinks(accountID: account).map(\.jid) == [chat.id])
        try await store.close()
        #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["\(MessageStore.currentSchemaVersion)"]])
    }

    @Test func linksArePerAccountAndAddressAndRelinkingReplaces() async throws {
        try await withEncryptedStore(account: "a") { store, _ async throws in
            let first = try await store.saveContactLink(link())
            #expect(first.replaced == nil && unsaved(first.saved) == link() && first.saved.generation > 0)
            // The same address in another account is a separate link.
            try await store.saveContactLink(link(account: "b", identifier: "contact-2", name: "Other Bob"))
            #expect(try await store.contactLink(accountID: "b", jid: "bob@x")?.contactIdentifier == "contact-2")
            // Relinking hands back the link it replaced, so its photo can go, and is a new generation.
            let relinked = link(identifier: "contact-3", name: "Robert", imageHash: photo)
            let second = try await store.saveContactLink(relinked)
            #expect(second.replaced == first.saved && second.saved.generation > first.saved.generation)
            #expect(try await store.contactLinks(accountID: "a") == [second.saved])
            #expect(try await store.isAvatarHashInUse(accountID: "a", hash: photo))
            #expect(try await !store.isAvatarHashInUse(accountID: "b", hash: photo))
            // Unlinking one account leaves the other's.
            #expect(try await store.removeContactLink(accountID: "a", jid: "bob@x") == second.saved)
            #expect(try await store.contactLink(accountID: "a", jid: "bob@x") == nil)
            #expect(try await !store.isAvatarHashInUse(accountID: "a", hash: photo))
            #expect(try await store.contactLink(accountID: "b", jid: "bob@x") != nil)
            #expect(try await store.removeContactLink(accountID: "a", jid: "bob@x") == nil)
        }
    }

    /// A refresh that read the contact before the user unlinked or relinked must not touch the new link, even one to
    /// the same contact.
    @Test func aRefreshOnlyUpdatesTheLinkItRead() async throws {
        try await withEncryptedStore(account: "a") { store, _ async throws in
            var refreshed = link()
            refreshed.displayName = "Bob Renamed"; refreshed.isReachable = false; refreshed.checkedAt = Date(timeIntervalSince1970: 2_000)
            #expect(try await store.refreshContactLink(refreshed) == nil)
            #expect(try await store.contactLink(accountID: "a", jid: "bob@x") == nil)
            let saved = try await store.saveContactLink(link()).saved
            refreshed.generation = saved.generation
            let change = try #require(try await store.refreshContactLink(refreshed))
            #expect(change.replaced == saved && change.saved == refreshed)
            #expect(try await store.contactLink(accountID: "a", jid: "bob@x") == refreshed)
            // Unlinked and linked again to the same contact: a new link, which the earlier reading never reaches.
            try await store.removeContactLink(accountID: "a", jid: "bob@x")
            let again = try await store.saveContactLink(link()).saved
            #expect(again.generation > saved.generation)
            #expect(try await store.refreshContactLink(refreshed) == nil)
            #expect(try await store.contactLink(accountID: "a", jid: "bob@x") == again)
            try await store.saveContactLink(link(identifier: "contact-9"))
            refreshed.generation = again.generation
            #expect(try await store.refreshContactLink(refreshed) == nil)
            #expect(try await store.contactLink(accountID: "a", jid: "bob@x")?.contactIdentifier == "contact-9")
        }
    }

    /// A refresh and the photo switch each write only their own fields, so neither undoes the other whichever read
    /// the link first.
    @Test func aRefreshAndThePhotoSwitchNeverUndoEachOther() async throws {
        try await withEncryptedStore(account: "a") { store, _ async throws in
            let saved = try await store.saveContactLink(link(imageHash: photo)).saved
            // The refresh read the link before the user turned the switch on.
            var refreshed = saved
            refreshed.displayName = "Bob Renamed"; refreshed.checkedAt = Date(timeIntervalSince1970: 2_000)
            let switched = try #require(try await store.setContactLinkUsesContactPhoto(true, accountID: "a", jid: "bob@x",
                                                                                       generation: saved.generation))
            #expect(switched.usesContactPhoto)
            let change = try #require(try await store.refreshContactLink(refreshed))
            #expect(change.saved.usesContactPhoto && change.saved.displayName == "Bob Renamed")

            // The switch's caller held the link from before a refresh found the contact unreadable.
            var unreadable = change.saved
            unreadable.isReachable = false
            try await store.refreshContactLink(unreadable)
            let off = try #require(try await store.setContactLinkUsesContactPhoto(false, accountID: "a", jid: "bob@x",
                                                                                  generation: saved.generation))
            #expect(!off.usesContactPhoto && !off.isReachable && off.usableContactIdentifier == nil && off.displayName == "Bob Renamed")

            // A switch for a link that was replaced changes nothing.
            let relinked = try await store.saveContactLink(link(identifier: "contact-2")).saved
            #expect(try await store.setContactLinkUsesContactPhoto(true, accountID: "a", jid: "bob@x", generation: saved.generation) == nil)
            #expect(try await store.contactLink(accountID: "a", jid: "bob@x") == relinked)
            try await store.removeContactLink(accountID: "a", jid: "bob@x")
            #expect(try await store.setContactLinkUsesContactPhoto(true, accountID: "a", jid: "bob@x", generation: relinked.generation) == nil)
            #expect(try await store.contactLink(accountID: "a", jid: "bob@x") == nil)
        }
    }

    @Test func invalidLinksAreRefused() async throws {
        try await withEncryptedStore(account: "a") { store, _ async throws in
            // The account itself is never linked: its Me card is the user.
            await #expect(throws: MessageStoreError.invalidValue) { try await store.saveContactLink(link("a")) }
            await #expect(throws: MessageStoreError.invalidValue) { try await store.saveContactLink(link(identifier: "")) }
            await #expect(throws: MessageStoreError.invalidValue) { try await store.saveContactLink(link(imageHash: "../escape")) }
            #expect(try await store.contactLinks(accountID: "a").isEmpty)
        }
    }

    /// Links go with the account's other local rows.
    @Test func erasingTheAccountRemovesItsLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "contact-links-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.saveContactLink(link())
        try await store.saveContactLink(link(account: "b"))
        try await store.eraseLocalAccount(accountID: "a")
        #expect(try await store.contactLinks(accountID: "a").isEmpty)
        #expect(try await store.contactLinks(accountID: "b").map(\.jid) == ["bob@x"])
        try await store.close()
    }

    /// A transfer's copy loses every account's links, and names the photos only they used; a copy from before
    /// schema 27 has nothing to remove.
    @Test func aTransferCopyLosesEveryAccountsLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "contact-links-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "messages.sqlite")
        let other = String(repeating: "d", count: 40)
        let store = try MessageStore(url: url)
        try await store.upsertChat(accountID: "a", chatID: "bob@x", title: "bob@x")
        try await store.upsertChat(accountID: "b", chatID: "bob@x", title: "bob@x")
        // Account b's link shares its photo with a verified avatar, which stays.
        try await store.setAvatarHash(accountID: "b", chatID: "bob@x", hash: photo)
        try await store.saveContactLink(link(imageHash: photo))
        try await store.saveContactLink(link(account: "b", imageHash: photo))
        try await store.saveContactLink(link("carol@x", account: "b", identifier: "contact-2", imageHash: other))
        try await store.close()

        #expect(try MessageStore.removeContactLinks(fromSnapshotAt: url)
                == [ContactLinkPhoto(accountID: "a", hash: photo), ContactLinkPhoto(accountID: "b", hash: other)])
        #expect(sqliteRows(url: url, sql: "SELECT count(*) FROM contact_links") == [["0"]])
        #expect(try StoreSnapshotSummary(snapshotAt: url).rowCounts["contact_links"] == 0)
        #expect(try MessageStore.removeContactLinks(fromSnapshotAt: url).isEmpty)
        #expect(sqliteExecute(url: url, sql: "DROP TABLE contact_links; PRAGMA user_version=26"))
        #expect(try MessageStore.removeContactLinks(fromSnapshotAt: url).isEmpty)
    }

    @Test func namePrecedenceAndAvatarPrecedence() {
        #expect(ContactLink.title("Bob", link: nil) == "Bob")
        #expect(ContactLink.title("bob@x", link: link()) == "Bob Example")
        // A contact without a name (only a company, say, or blanked) falls back to the stored title.
        #expect(ContactLink.title("bob@x", link: link(name: "  ")) == "bob@x")
        #expect(ContactLink.avatarHash(verified: verified, link: nil) == verified)
        #expect(ContactLink.avatarHash(verified: nil, link: link()) == nil)
        #expect(ContactLink.avatarHash(verified: verified, link: link(imageHash: photo)) == verified)
        #expect(ContactLink.avatarHash(verified: nil, link: link(imageHash: photo)) == photo)
        #expect(ContactLink.avatarHash(verified: verified, link: link(imageHash: photo, usesContactPhoto: true)) == photo)
        #expect(ContactLink.avatarHash(verified: verified, link: link(usesContactPhoto: true)) == verified)
        #expect(link(reachable: false).usableContactIdentifier == nil && link().usableContactIdentifier == "contact-1")
    }

    /// Notifications read the link from the store: the contact's name and photo, and the contact only while reachable.
    @Test func notificationCandidatesCarryTheLinkedContact() async throws {
        try await withEncryptedStore(account: "a", chats: [("bob@x", "bob@x"), ("room@rooms", "Book club")]) { store, _ in
            try await store.setAvatarHash(accountID: "a", chatID: "bob@x", hash: verified)
            try await commit(store, "d1", chat: "bob@x", at: 1)
            var batch = try await store.pendingNotifications(accountID: "a")
            #expect(batch.candidates[0].chatTitle == "bob@x" && batch.candidates[0].senderContactIdentifier == nil)

            try await store.saveContactLink(link(imageHash: photo, usesContactPhoto: true))
            batch = try await store.pendingNotifications(accountID: "a")
            #expect(batch.candidates[0].chatTitle == "Bob Example" && batch.candidates[0].chatAvatarHash == photo)
            #expect(batch.candidates[0].senderAvatarHash == photo && batch.candidates[0].senderContactIdentifier == "contact-1")

            // Unreachable (deleted, or outside the limited set): the cached name and photo and the user's photo choice
            // stay, the system is not told.
            var unreachable = try #require(try await store.contactLink(accountID: "a", jid: "bob@x")); unreachable.isReachable = false
            try await store.refreshContactLink(unreachable)
            batch = try await store.pendingNotifications(accountID: "a")
            #expect(batch.candidates[0].chatTitle == "Bob Example" && batch.candidates[0].chatAvatarHash == photo)
            #expect(batch.candidates[0].senderContactIdentifier == nil)

            // In a room, the member's link names them; the room itself is never linked.
            try await store.saveContactLink(link())
            try await store.removeNotificationCandidates(accountID: "a", keys: batch.claimed)
            try await commit(store, "g1", chat: "room@rooms", sender: "bob@x", at: 2, room: "room@rooms")
            batch = try await store.pendingNotifications(accountID: "a")
            let group = try #require(batch.candidates.first)
            #expect(group.isGroup && group.chatTitle == "Book club" && group.senderTitle == "Bob Example")
            #expect(group.senderContactIdentifier == "contact-1")
        }
    }
}
