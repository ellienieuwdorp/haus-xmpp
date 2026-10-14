import Foundation
import Testing
@testable import MessageStore

private let account = "ellie@example.org", peer = "bob@example.org"
private let link = "https://example.org/news"

private func previewed(_ id: String, body: String = "Read \(link)", _ preview: StoredLinkPreview?) -> StoredMessage {
    StoredMessage(id: id, accountID: account, chatID: peer, senderID: peer, body: body, sentAt: Date(timeIntervalSince1970: 100),
                  wireID: "w-\(id)", linkPreview: preview)
}

/// A preview is part of its message: it loads with it, a repeated insert of the same message is not a conflict, and a
/// row out of the wire's bounds is refused together with its message.
@Test func previewTravelsWithItsMessageWithinTheWireBounds() async throws {
    try await withEncryptedStore(account: account, chats: [(peer, "Bob")]) { store, _ in
        let preview = StoredLinkPreview(url: link, title: "Council approves", summary: "Spring.", imageData: Data(repeating: 1, count: 65_536),
                                        imageType: "image/jpeg", imageAlt: "Dusk", source: .sender)
        let inserted = try await store.insertMessage(previewed("m", preview))
        #expect(inserted)
        #expect(try await store.message(accountID: account, messageID: "m")?.linkPreview == preview)
        #expect(try await store.messages(accountID: account, chatID: peer).map(\.linkPreview) == [preview])
        #expect(try await !store.insertMessage(previewed("m", preview)))

        let refused: [StoredLinkPreview] = [
            StoredLinkPreview(url: "ftp://example.org/x", title: "x", source: .sender),
            StoredLinkPreview(url: link, title: String(repeating: "x", count: 1_025), source: .sender),
            StoredLinkPreview(url: link, summary: String(repeating: "x", count: 2_049), source: .sender),
            StoredLinkPreview(url: link, imageData: Data(repeating: 1, count: 65_537), imageType: "image/jpeg", source: .sender),
            StoredLinkPreview(url: link, imageData: Data([1]), source: .sender),
        ]
        for (index, preview) in refused.enumerated() {
            await #expect(throws: MessageStoreError.invalidValue) { try await store.insertMessage(previewed("bad-\(index)", preview)) }
            #expect(try await store.message(accountID: account, messageID: "bad-\(index)") == nil)
        }
    }
}

/// link-previews.md: a correction carries the full new metadata and replaces the preview, one without removes it,
/// and a retraction deletes the stored row.
@Test func correctionsReplaceThePreviewAndRetractionsDeleteIt() async throws {
    try await withEncryptedStore(account: account, chats: [(peer, "Bob")]) { store, url in
        try await store.insertMessage(previewed("m", StoredLinkPreview(url: link, title: "Old", source: .sender)))
        func shown() async throws -> StoredMessage? {
            let message = try await store.message(accountID: account, messageID: "m")
            return try await message?.applying(store.events(accountID: account, chatID: peer, messageID: "m"))
        }
        let corrected = StoredLinkPreview(url: "https://example.org/b", title: "New", source: .sender)
        try await store.recordEvent(accountID: account, event: MessageEvent(id: "c1", chatID: peer, actorID: peer, targetWireID: "w-m", kind: .correction,
            payload: try MessageEvent.correctionPayload("Now https://example.org/b", linkPreview: corrected), updatedAt: Date(timeIntervalSince1970: 110)))
        #expect(try await shown()?.linkPreview == corrected)
        #expect(try await shown()?.body == "Now https://example.org/b")
        try await store.recordEvent(accountID: account, event: MessageEvent(id: "c2", chatID: peer, actorID: peer, targetWireID: "w-m", kind: .correction,
            payload: try MessageEvent.correctionPayload("No link now"), updatedAt: Date(timeIntervalSince1970: 120)))
        #expect(try await shown()?.linkPreview == nil)

        try await store.recordEvent(accountID: account, event: MessageEvent(id: "r", chatID: peer, actorID: peer, targetWireID: "w-m", kind: .retraction,
                                                                            payload: "{}", updatedAt: Date(timeIntervalSince1970: 130)))
        #expect(sqliteRows(url: url, sql: "SELECT count(*) FROM message_link_previews") == [["0"]])
        #expect(try await shown()?.linkPreview == nil)
    }
}

/// Our own fetches: one entry per account and link, replaced in place; the image paths of entries the store drops are
/// handed back so the caller can delete the files, and a path outside `link-previews/` is refused.
@Test func fetchCacheKeepsOneEntryPerLinkAndHandsBackDroppedImages() async throws {
    try await withEncryptedStore(account: account) { store, _ in
        func entry(_ url: String, at seconds: TimeInterval, path: String? = nil, account: String = account) -> LinkPreviewCacheEntry {
            LinkPreviewCacheEntry(accountID: account, url: url, fetchedAt: Date(timeIntervalSince1970: seconds), status: path == nil ? .failed : .ok,
                                  title: path.map { _ in "Title" }, imagePath: path, imageWidth: path.map { _ in 400 }, imageHeight: path.map { _ in 300 })
        }
        #expect(try await store.saveLinkPreviewCacheEntry(entry("https://a.example/", at: 10, path: "link-previews/a1.jpg")) == nil)
        #expect(try await store.saveLinkPreviewCacheEntry(entry("https://a.example/", at: 20, path: "link-previews/a2.jpg")) == "link-previews/a1.jpg")
        #expect(try await store.saveLinkPreviewCacheEntry(entry("https://a.example/", at: 25, path: "link-previews/a2.jpg")) == nil)
        #expect(try await store.linkPreviewCacheEntry(accountID: account, url: "https://a.example/") == entry("https://a.example/", at: 25, path: "link-previews/a2.jpg"))
        for path in ["attachments/x.jpg", "link-previews/../cache/x.jpg", "/link-previews/x.jpg", "link-previews/"] {
            await #expect(throws: MessageStoreError.invalidValue, "\(path)") { try await store.saveLinkPreviewCacheEntry(entry("https://b.example/", at: 1, path: path)) }
        }

        try await store.saveLinkPreviewCacheEntry(entry("https://old.example/", at: 5, path: "link-previews/old.jpg"))
        try await store.saveLinkPreviewCacheEntry(entry("https://c.example/", at: 30))
        try await store.saveLinkPreviewCacheEntry(entry("https://d.example/", at: 40, path: "link-previews/d.jpg"))
        try await store.saveLinkPreviewCacheEntry(entry("https://other.example/", at: 1, path: "link-previews/o.jpg", account: "other@example.org"))
        // Older than 8 goes (old), then all but the newest two (d at 40, c at 30) go (a): other accounts are untouched.
        let pruned = try await store.pruneLinkPreviewCache(accountID: account, fetchedBefore: Date(timeIntervalSince1970: 8), keeping: 2)
        #expect(Set(pruned) == ["link-previews/old.jpg", "link-previews/a2.jpg"])
        #expect(try await store.linkPreviewCacheEntry(accountID: account, url: "https://a.example/") == nil)
        #expect(try await store.linkPreviewCacheEntry(accountID: account, url: "https://c.example/") != nil)
        #expect(try await store.deleteLinkPreviewCache(accountID: account) == ["link-previews/d.jpg"])
        #expect(try await store.linkPreviewCacheEntry(accountID: "other@example.org", url: "https://other.example/") != nil)
    }
}
