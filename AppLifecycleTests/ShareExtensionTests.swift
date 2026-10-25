import ImageIO
import MessageStore
import MessagingCore
import UIKit
import UniformTypeIdentifiers
import XCTest
import XMPPProtocol
@testable import HausXMPP

/// The share extension's pure decisions: what a provider is taken as, what the picker lists and offers, what the share
/// sheet activates for, and the shared copies the app writes for the extension.
final class ShareExtensionTests: XCTestCase {
    // MARK: Intake

    func testProvidersAreTakenAsTheirMostUsefulKind() {
        XCTAssertEqual(SharedItemIntake.kind(of: ["public.heic", "com.apple.live-photo"]), .image, "a Live Photo goes as its still")
        XCTAssertEqual(SharedItemIntake.kind(of: ["com.apple.quicktime-movie"]), .video)
        XCTAssertEqual(SharedItemIntake.kind(of: ["public.jpeg", "public.file-url"]), .image)
        XCTAssertEqual(SharedItemIntake.kind(of: ["com.adobe.pdf", "public.url"]), .file, "Safari's PDF is the file, not its address")
        XCTAssertEqual(SharedItemIntake.kind(of: ["public.file-url"]), .file)
        XCTAssertEqual(SharedItemIntake.kind(of: ["public.url", "public.plain-text"]), .link)
        XCTAssertEqual(SharedItemIntake.kind(of: ["com.apple.webarchive", "public.url"]), .link, "a page's archive is not a file to send")
        XCTAssertEqual(SharedItemIntake.kind(of: ["public.zip-archive"]), .file)
        XCTAssertEqual(SharedItemIntake.kind(of: ["public.plain-text"]), .text)
        XCTAssertNil(SharedItemIntake.kind(of: ["public.data"]), "nothing concrete to send")
        XCTAssertNil(SharedItemIntake.kind(of: ["com.apple.property-list"]))
        XCTAssertEqual(SharedItemIntake.preferredType(for: .image, registeredTypes: ["com.apple.live-photo", "public.heic"]), .heic)
        XCTAssertEqual(SharedItemIntake.preferredType(for: .file, registeredTypes: ["public.file-url", "com.adobe.pdf"]), .pdf)
    }

    func testSafarisPageAndPreviewShareOnlyTheLink() {
        let page = NSExtensionItem()
        page.attachments = [NSItemProvider(item: URL(string: "https://example.org/a")! as NSURL, typeIdentifier: UTType.url.identifier)]
        let preview = NSExtensionItem()
        preview.attachments = [NSItemProvider(item: Data([1]) as NSData, typeIdentifier: UTType.png.identifier)]
        XCTAssertEqual(SharedItemIntake.providers(of: [page, preview]).count, 1)
        XCTAssertEqual(SharedItemIntake.providers(of: [preview]).count, 1, "a single item keeps everything it carries")
        XCTAssertEqual(SharedItemIntake.safeName("a/b:c.jpg"), "a-b-c.jpg")
        XCTAssertEqual(SharedItemIntake.safeName(String(repeating: "é", count: 200)).utf8.count, 254)
    }

    func testIntakeCopiesFilesOneByOneAndStopsAtTheFileLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "share-intake-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder); SharedItemIntake.discardAll() }
        let photo = folder.appending(path: "IMG_0001.png")
        try XCTUnwrap(Self.png(width: 40, height: 30)).write(to: photo)
        var providers = (0..<(SharedItemIntake.maximumFiles + 1)).map { _ in NSItemProvider(contentsOf: photo)! }
        providers.append(NSItemProvider(item: "Look at this" as NSString, typeIdentifier: UTType.plainText.identifier))
        providers.append(NSItemProvider(item: URL(string: "https://example.org/x")! as NSURL, typeIdentifier: UTType.url.identifier))
        let result = await SharedItemIntake.load(providers)
        XCTAssertEqual(result.items.filter(\.isFile).count, SharedItemIntake.maximumFiles)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.items.filter { !$0.isFile }.map(\.kind), [.text, .link], "text after the file limit still comes")
        let first = try XCTUnwrap(result.items.first)
        XCTAssertEqual(first.kind, .image)
        XCTAssertNotEqual(first.file, photo, "a copy of our own")
        XCTAssertTrue(first.file?.path.hasPrefix(SharedItemIntake.root.path) == true)
        XCTAssertEqual(first.size, try photo.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(ShareRules.initialText(from: result.items), "Look at this\nhttps://example.org/x")
        // Preparing it re-encodes the still as JPEG within the limit; one over the limit says so.
        let prepared = try await AttachmentPreparer.prepare(fileURL: try XCTUnwrap(first.file), name: first.name, type: first.type, limit: 1 << 20)
        XCTAssertEqual(prepared.mediaType, "image/jpeg")
        XCTAssertEqual((prepared.name as NSString).pathExtension, "jpg")
        XCTAssertEqual(prepared.width, 40)
        do {
            _ = try await AttachmentPreparer.prepare(fileURL: try XCTUnwrap(first.file), name: first.name, type: first.type, limit: 10)
            XCTFail("over the limit")
        } catch AttachmentPreparer.Failure.tooLarge {}
        SharedItemIntake.discardAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: SharedItemIntake.root.path))
    }

    /// ImageIO replaced `UIImage.jpegData` for the composer's photos: the same pixels at the same quality come out the
    /// same size within a few percent.
    func testImageIOJPEGMatchesUIKitOutput() throws {
        let image = try XCTUnwrap(Self.gradient(width: 1600, height: 1200))
        let imageIO = try XCTUnwrap(AttachmentPreparer.jpegData(image, quality: 0.85))
        let uikit = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.85))
        XCTAssertEqual(Double(imageIO.count), Double(uikit.count), accuracy: Double(uikit.count) * 0.05)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(imageIO as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(decoded.width, 1600)
    }

    // MARK: Picker

    private func chat(_ id: String, group: Bool = false, pinned: Bool = false, at seconds: TimeInterval? = nil,
                      encryption: ChatCapabilities.Encryption = .encrypted(verified: false)) -> ShareRules.Chat {
        ShareRules.Chat(id: id, title: id, isGroup: group, isPinned: pinned, avatarHash: nil,
                        lastActivity: seconds.map { Date(timeIntervalSince1970: $0) }, encryption: encryption)
    }

    func testPickerListsPinnedThenRecentAndSearchesEverything() {
        var chats = (0..<40).map { chat("c\($0)@x", at: TimeInterval($0)) }
        chats.append(chat("old-pinned@x", pinned: true, at: 0))
        let listed = ShareRules.listed(chats, search: "")
        XCTAssertEqual(listed.first?.id, "old-pinned@x")
        XCTAssertEqual(listed[1].id, "c39@x")
        XCTAssertEqual(listed.count, 1 + ShareRules.recentChats)
        XCTAssertEqual(ShareRules.listed(chats, search: "c3").map(\.id).sorted(), (["c3@x"] + (30..<40).map { "c\($0)@x" }).sorted(),
                       "a search reaches chats beyond the recent ones")
    }

    /// The picker names and pictures a chat as the app does: a linked contact's name first, its photo after a verified
    /// avatar unless the user chose the photo. A name-only link names the chat too; a room is never linked.
    func testThePickerNamesAndPicturesALinkedChatAsTheAppDoes() {
        let verified = String(repeating: "a", count: 40), photo = String(repeating: "b", count: 40)
        var link = ContactLink(accountID: "me@x", jid: "bob@x", contactIdentifier: "C-1", source: .picker, displayName: "Robin Okafor",
                               imageHash: photo, isReachable: false)
        func listed(_ link: ContactLink?, id: String = "bob@x", group: Bool = false, avatar: String? = verified) -> ShareRules.Chat {
            ShareRules.chat(id: id, storedTitle: id, isGroup: group, isPinned: false, verifiedAvatarHash: avatar, lastActivity: nil, link: link)
        }
        XCTAssertEqual(listed(nil).displayTitle, "bob")
        XCTAssertEqual(listed(link).displayTitle, "Robin Okafor")
        XCTAssertEqual(listed(link).avatarHash, verified)
        XCTAssertEqual(listed(link, avatar: nil).avatarHash, photo)
        link.usesContactPhoto = true
        XCTAssertEqual(listed(link).avatarHash, photo)
        let room = listed(link, id: "room@muc.x", group: true)
        XCTAssertEqual(room.title, "room@muc.x")
        XCTAssertEqual(room.avatarHash, verified)
    }

    func testChatsThatCannotTakeTheShareSayWhy() {
        let direct = chat("a@x"), room = chat("room@muc.x", group: true)
        XCTAssertNil(ShareRules.unavailableReason(direct, hasFiles: true, filesAccepted: true, isBlocked: false))
        XCTAssertEqual(ShareRules.unavailableReason(room, hasFiles: true, filesAccepted: true, isBlocked: false), "Files can't be sent to groups yet")
        XCTAssertNil(ShareRules.unavailableReason(room, hasFiles: false, filesAccepted: nil, isBlocked: false), "groups take text and links")
        XCTAssertEqual(ShareRules.unavailableReason(direct, hasFiles: true, filesAccepted: false, isBlocked: false), "Your server doesn't accept files")
        XCTAssertEqual(ShareRules.unavailableReason(direct, hasFiles: true, filesAccepted: nil, isBlocked: false), "Haus XMPP hasn't checked this server for files yet")
        XCTAssertEqual(ShareRules.unavailableReason(direct, hasFiles: false, filesAccepted: true, isBlocked: true), "Blocked")
        XCTAssertEqual(ShareRules.unavailableReason(chat("b@x", encryption: .unavailable("No compatible encryption devices")), hasFiles: false,
                                                    filesAccepted: true, isBlocked: false), "No compatible encryption devices",
                       "nothing is ever sent unencrypted, so such a chat cannot take it")
        // A chat waiting for a review takes the share; the drain holds it until the user decides in the app.
        XCTAssertNil(ShareRules.unavailableReason(chat("c@x", encryption: .needsReview), hasFiles: true, filesAccepted: true, isBlocked: false))
        XCTAssertNil(ShareRules.unavailableReason(chat("d@x", encryption: .pending), hasFiles: true, filesAccepted: true, isBlocked: false))
    }

    func testOnlyThatAccountsSuggestionPreselectsItsChat() {
        let chats = [chat("a@x"), chat("b@x")]
        let identifier = NotificationIdentity.thread(accountID: "me@x", chatID: "b@x")
        XCTAssertEqual(ShareRules.suggestedChat(conversationIdentifier: identifier, accountID: "me@x", chats: chats)?.id, "b@x")
        XCTAssertNil(ShareRules.suggestedChat(conversationIdentifier: identifier, accountID: "other@x", chats: chats))
        XCTAssertNil(ShareRules.suggestedChat(conversationIdentifier: nil, accountID: "me@x", chats: chats))
        XCTAssertNil(ShareRules.suggestedChat(conversationIdentifier: NotificationIdentity.thread(accountID: "me@x", chatID: "gone@x"),
                                              accountID: "me@x", chats: chats))
    }

    func testSendNeedsContentAChatAndAtMostFiveChats() {
        XCTAssertTrue(ShareRules.canSend(files: 1, unsendableFiles: 0, text: "", recipients: 1))
        XCTAssertTrue(ShareRules.canSend(files: 0, unsendableFiles: 0, text: "Hi", recipients: ShareRules.maximumRecipients))
        XCTAssertFalse(ShareRules.canSend(files: 0, unsendableFiles: 0, text: " \n", recipients: 1))
        XCTAssertFalse(ShareRules.canSend(files: 1, unsendableFiles: 0, text: "", recipients: 0))
        XCTAssertFalse(ShareRules.canSend(files: 1, unsendableFiles: 0, text: "", recipients: ShareRules.maximumRecipients + 1))
        XCTAssertFalse(ShareRules.canSend(files: 0, unsendableFiles: 0, text: String(repeating: "a", count: OutgoingEnqueue.maximumTextBytes + 1),
                                          recipients: 1))
    }

    func testAFileThatCouldNotBePreparedHoldsSendUntilRemoved() {
        XCTAssertFalse(ShareRules.canSend(files: 1, unsendableFiles: 1, text: "", recipients: 1), "a readable PDF beside an oversized one")
        XCTAssertFalse(ShareRules.canSend(files: 0, unsendableFiles: 1, text: "Caption", recipients: 1), "a caption beside a file that can't go")
        XCTAssertTrue(ShareRules.canSend(files: 1, unsendableFiles: 0, text: "Caption", recipients: 1), "once it is removed")
    }

    func testOneChatsResultIsSentOnlyWhenTheServerAcknowledgedAllOfIt() {
        XCTAssertEqual(ShareRules.delivery([.sent, .sent], finished: true), .sent)
        XCTAssertEqual(ShareRules.delivery([.sent, .sending], finished: true), .queued, "unacknowledged at the end stays with the app")
        XCTAssertEqual(ShareRules.delivery([.sent, .queued], finished: false), .sending)
        XCTAssertEqual(ShareRules.delivery([.sent, .failed], finished: true), .failed)
    }

    func testAnItemThatCouldNotBeSavedIsReportedWhateverBecameOfTheRest() {
        let promise = "Haus XMPP will finish sending. Open it if a device needs your review."
        let missing = "Some of this couldn't be saved. Share what's missing again."
        // The caption was saved, the photo was not; the caption is queued, sending or sent.
        for (rest, note) in [(ShareItemState.queued, missing + " " + promise), (.sending, missing + " " + promise), (.sent, missing)] {
            let outcome = ShareRules.outcome(["a@x": [rest]], unsaved: ["a@x"])
            XCTAssertEqual(outcome.deliveries, ["a@x": .incomplete], "\(rest)")
            XCTAssertEqual(outcome.note, note, "never only the promise that the app finishes it")
        }
        // Another chat got everything and is told so; the line still names what is missing.
        let mixed = ShareRules.outcome(["a@x": [.sent], "b@x": [.sent, .sent]], unsaved: ["a@x"])
        XCTAssertEqual(mixed.deliveries, ["a@x": .incomplete, "b@x": .sent])
        XCTAssertEqual(mixed.note, missing)
        // Nothing saved for any chat.
        let nothing = ShareRules.outcome(["a@x": [], "b@x": []], unsaved: ["a@x", "b@x"])
        XCTAssertEqual(nothing.deliveries, ["a@x": .failed, "b@x": .failed])
        XCTAssertEqual(nothing.note, "Nothing could be saved. Share it again.")
        // Everything saved: a refused row has Retry in the chat, an unacknowledged one is the app's to finish.
        XCTAssertEqual(ShareRules.outcome(["a@x": [.sent, .failed]], unsaved: []).note, "Some of this wasn't sent. Open Haus XMPP to retry it.")
        XCTAssertEqual(ShareRules.outcome(["a@x": [.sending]], unsaved: []).deliveries, ["a@x": .queued])
        XCTAssertEqual(ShareRules.outcome(["a@x": [.sending]], unsaved: []).note, promise)
        XCTAssertNil(ShareRules.outcome(["a@x": [.sent]], unsaved: []).note)
    }

    // MARK: Authorization

    /// A sheet opened for one account checks again at Send and before connecting: another account, none, a move or a
    /// restore refuses it, and the record it goes on with is the one saved now.
    func testASheetLeftOpenRefusesAnAccountThatSignedOutOrWasReplaced() throws {
        let group = FileManager.default.temporaryDirectory.appending(path: "share-authorization-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: group) }
        func record(_ account: String, password: String = "synthetic") -> NotificationAccount {
            NotificationAccount(accountID: account, host: "localhost", port: 5223, domain: "localhost", username: String(account.prefix { $0 != "@" }),
                                password: password, push: nil)
        }
        func check(_ saved: NotificationAccount?, opened: String? = "a@localhost") -> Result<NotificationAccount, ShareAuthorization.Refusal> {
            ShareAuthorization.check(groupRoot: group, accountID: opened) { saved }
        }
        XCTAssertEqual(check(nil, opened: nil), .failure(.signedOut), "nobody signed in when the sheet opens")
        XCTAssertEqual(check(record("a@localhost"), opened: nil), .success(record("a@localhost")))
        XCTAssertEqual(check(nil), .failure(.signedOutSinceOpening), "signed out while the sheet was open")
        XCTAssertEqual(check(record("b@localhost")), .failure(.signedOutSinceOpening), "another account signed in meanwhile")
        XCTAssertEqual(check(record("a@localhost", password: "changed")), .success(record("a@localhost", password: "changed")),
                       "the same account goes on with the password saved now")
        XCTAssertEqual(ShareAuthorization.check(groupRoot: group, accountID: "a@localhost") { throw CocoaError(.fileReadNoPermission) },
                       .failure(.unreadable))

        let moved = TransferHold.directory(groupRoot: group)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: moved.appending(path: TransferHold.markerName))
        XCTAssertEqual(check(record("a@localhost")), .failure(.moved))
        try FileManager.default.removeItem(at: moved)

        let restore = PreUpgradeHold.directory(groupRoot: group)
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: restore.appending(path: PreUpgradeHold.journalName))
        XCTAssertEqual(check(record("a@localhost")), .failure(.restoring))
    }

    // MARK: Activation rule

    /// The rule is a predicate over dictionaries shaped like the system's (Apple's App Extension Programming Guide).
    private func activates(_ items: [[String]]) -> Bool {
        let input: [String: Any] = ["extensionItems": items.map { types in
            ["attachments": types.map { ["registeredTypeIdentifiers": [$0]] }]
        }]
        return NSPredicate(format: ShareRules.activationRule).evaluate(with: input)
    }

    func testTheShareSheetOffersHausForWhatItCanSendAndUpToTenFiles() throws {
        XCTAssertTrue(activates([["public.jpeg"]]))
        XCTAssertTrue(activates([Array(repeating: "public.heic", count: 10)]))
        XCTAssertFalse(activates([Array(repeating: "public.heic", count: 11)]), "more than the composer's tray")
        XCTAssertTrue(activates([["public.url"], ["public.png"]]), "Safari's page and preview")
        XCTAssertTrue(activates([["public.plain-text"]]))
        XCTAssertTrue(activates([["com.adobe.pdf"]]))
        XCTAssertTrue(activates([["public.file-url"]]))
        XCTAssertFalse(activates([]))
        XCTAssertFalse(activates([["public.url"], ["public.url"], ["public.url"]]))
        // The Info.plists carry the same string, and never the development-only catch-all.
        let plist = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appending(path: "HausShare.appex/Info.plist"))
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        let attributes = (info["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
        XCTAssertEqual(attributes?["NSExtensionActivationRule"] as? String, ShareRules.activationRule)
        XCTAssertEqual(attributes?["IntentsSupported"] as? [String], ["INSendMessageIntent"])
        XCTAssertFalse(ShareRules.activationRule.contains("TRUEPREDICATE"))
    }

    // MARK: What the app shares with the extension

    func testTheAppMirrorsItsUploadAnswerForTheExtension() throws {
        let suite = "haus.xmpp.tests.uploads.\(UUID().uuidString)", mirrorSuite = suite + ".mirror"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), mirror = try XCTUnwrap(UserDefaults(suiteName: mirrorSuite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            UserDefaults(suiteName: mirrorSuite)?.removePersistentDomain(forName: mirrorSuite)
        }
        let app = UploadServiceMemory(defaults: defaults, mirror: mirror), reader = UploadServiceMemory(defaults: mirror)
        let account = "alice@example.org", service = XMPPUploadService(jid: "upload.example.org", maximumFileSize: 1_000)
        app.publish(account: account)
        XCTAssertFalse(reader.hasAnswer(account: account), "no discovery yet: the extension cannot say the server refuses files")
        _ = app.settle(account: account, previous: nil, discovery: .success(service))
        XCTAssertEqual(reader.load(account: account), service)
        _ = app.settle(account: account, previous: service, discovery: .success(nil))
        XCTAssertTrue(reader.hasAnswer(account: account))
        XCTAssertNil(reader.load(account: account), "none offered is an answer")
        XCTAssertNil(app.load(account: account))
        app.forget(account: account)
        XCTAssertFalse(reader.hasAnswer(account: account))
        // A store kept before the mirror existed is copied once the account loads.
        let older = UploadServiceMemory(defaults: defaults)
        _ = older.settle(account: account, previous: nil, discovery: .success(service))
        XCTAssertFalse(reader.hasAnswer(account: account))
        app.publish(account: account)
        XCTAssertEqual(reader.load(account: account), service)
    }

    func testSuggestionsAreOnByDefaultForEveryAccountUntilTurnedOff() throws {
        let suite = "haus.xmpp.tests.suggestions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ShareSuggestionSetting.isEnabled(accountID: "a@x", defaults: defaults), "existing accounts included")
        ShareSuggestionSetting.set(false, accountID: "a@x", defaults: defaults)
        XCTAssertFalse(ShareSuggestionSetting.isEnabled(accountID: "a@x", defaults: defaults))
        XCTAssertTrue(ShareSuggestionSetting.isEnabled(accountID: "b@x", defaults: defaults), "per account")
        ShareSuggestionSetting.forget(accountID: "a@x", defaults: defaults)
        XCTAssertTrue(ShareSuggestionSetting.isEnabled(accountID: "a@x", defaults: defaults))
        XCTAssertFalse(ShareSuggestionSetting.isEnabled(accountID: "", defaults: defaults))
    }

    func testSuggestionAvatarsAreAtLeast360PixelsAndTheNotificationCopyStaysSmall() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "share-avatars-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hash = String(repeating: "ab", count: 20)
        try AvatarStore.save(try XCTUnwrap(Self.png(width: 1024, height: 1024)), root: root, account: "a@x", hash: hash)
        XCTAssertTrue(AvatarStore.saveNotificationImage(root: root, account: "a@x", hash: hash))
        func side(_ data: Data?) -> Int? {
            data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyPixelWidth] as? Int
        }
        XCTAssertEqual(side(AvatarStore.notificationImageData(root: root, account: "a@x", hash: hash)), AvatarStore.thumbnailPixels)
        let suggestion = try XCTUnwrap(side(AvatarStore.suggestionImageData(root: root, account: "a@x", hash: hash)))
        XCTAssertGreaterThanOrEqual(suggestion, 360)
        // An avatar whose suggestion copy is missing falls back to the notification copy.
        try FileManager.default.removeItem(at: AvatarStore.suggestionImageURL(root: root, account: "a@x", hash: hash))
        XCTAssertEqual(side(AvatarStore.suggestionImageData(root: root, account: "a@x", hash: hash)), AvatarStore.thumbnailPixels)
    }

    func testTheSuggestedConversationNamesTheChatAndRoomMembersLikeTheirChats() {
        let direct = SuggestedConversation.outgoing(accountID: "me@x", chatID: "bob@x", title: "bob@x", avatarHash: "h", roomMembers: nil,
                                                    titles: [:], links: [:])
        XCTAssertEqual(direct.recipients.map(\.displayName), ["bob"])
        XCTAssertEqual(direct.recipients.first?.avatarHash, "h")
        XCTAssertEqual(direct.recipients.first?.contactIdentifier, nil)
        XCTAssertFalse(direct.isGroup)
        let room = SuggestedConversation.outgoing(accountID: "me@x", chatID: "room@muc.x", title: "Book club", avatarHash: nil,
                                                  roomMembers: ["me@x", "carol@x"], titles: ["carol@x": "Carol"], links: [:])
        XCTAssertEqual(room.groupName, "Book club")
        XCTAssertEqual(room.recipients.map(\.displayName), ["Carol"])
        XCTAssertEqual(room.conversationIdentifier, NotificationIdentity.thread(accountID: "me@x", chatID: "room@muc.x"))
    }

    /// An outgoing donation names a linked person as their notifications do: the contact's name, its photo after a
    /// verified avatar, and the contact itself only for a link the app can read. Room members carry their own links.
    func testTheSuggestedConversationCarriesContactLinksAsNotificationsDo() {
        let verified = String(repeating: "a", count: 40), photo = String(repeating: "b", count: 40)
        func link(_ jid: String, _ contact: String, reachable: Bool = true) -> ContactLink {
            ContactLink(accountID: "me@x", jid: jid, contactIdentifier: contact, source: .picker, displayName: "Robin Okafor", imageHash: photo,
                        isReachable: reachable)
        }
        func bob(_ links: [String: ContactLink], avatar: String? = verified) -> NotificationCommunication.Person? {
            SuggestedConversation.outgoing(accountID: "me@x", chatID: "bob@x", title: "bob@x", avatarHash: avatar, roomMembers: nil, titles: [:],
                                           links: links).recipients.first
        }
        XCTAssertEqual(bob(["bob@x": link("bob@x", "C-1")]),
                       NotificationCommunication.Person(handle: "bob@x", displayName: "Robin Okafor", avatarHash: verified, contactIdentifier: "C-1"))
        XCTAssertEqual(bob(["bob@x": link("bob@x", "C-1")], avatar: nil)?.avatarHash, photo)
        // Made without access, or the contact went: the cached name in Haus, no contact for the system.
        let nameOnly = bob(["bob@x": link("bob@x", "C-1", reachable: false)])
        XCTAssertEqual(nameOnly?.displayName, "Robin Okafor")
        XCTAssertNil(nameOnly?.contactIdentifier)
        // Another chat's link names nobody here.
        XCTAssertNil(bob(["carol@x": link("carol@x", "C-2")])?.contactIdentifier)

        let room = SuggestedConversation.outgoing(accountID: "me@x", chatID: "room@muc.x", title: "Book club", avatarHash: nil,
                                                  roomMembers: ["carol@x", "dave@x"], titles: ["dave@x": "Dave"],
                                                  links: ["carol@x": link("carol@x", "C-2"), "room@muc.x": link("room@muc.x", "C-3")])
        XCTAssertEqual(room.groupName, "Book club")
        XCTAssertEqual(room.recipients.map(\.displayName), ["Robin Okafor", "Dave"])
        XCTAssertEqual(room.recipients.map(\.contactIdentifier), ["C-2", nil])
        XCTAssertEqual(room.recipients.map(\.avatarHash), [nil, nil])
    }

    // MARK: Fixtures

    private static func gradient(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: CGFloat((x ^ y) % 256) / 255, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return context.makeImage()
    }

    private static func png(width: Int, height: Int) -> Data? {
        guard let image = gradient(width: width, height: height) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
