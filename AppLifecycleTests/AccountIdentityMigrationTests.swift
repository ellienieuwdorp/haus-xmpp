import XCTest
import XMPPProtocol
import MessagingCore
@testable import HausXMPP

/// An installation signed in as `Ellie@Example.org` before addresses were normalised: everything outside the message
/// store that names the account moves to `ellie@example.org`, and nothing the normal spelling already has is lost.
@MainActor final class AccountIdentityMigrationTests: XCTestCase {
    private let typed = "Ellie@Example.org", account = "ellie@example.org"

    func testPreferencesAndFoldersMoveToTheNormalSpelling() throws {
        let suite = "haus.xmpp.test.identity." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(typed, forKey: "lastAccount")
        defaults.set(true, forKey: "pushOff." + typed)
        defaults.set("old-hash", forKey: "avatar." + typed)
        defaults.set("new-hash", forKey: "avatar." + account)
        defaults.set(["jid": "upload.example.org"], forKey: "uploadService." + typed)
        defaults.set("Ellie", forKey: "groupNickname.\(typed).Team@Rooms.Example.org")

        let spellings = AccountIdentityMigration.migratePreferences(defaults)
        XCTAssertEqual(spellings, [typed])
        XCTAssertEqual(defaults.string(forKey: "lastAccount"), account)
        XCTAssertTrue(defaults.bool(forKey: "pushOff." + account))
        XCTAssertEqual(defaults.string(forKey: "avatar." + account), "new-hash", "the normal spelling's value wins")
        XCTAssertEqual((defaults.dictionary(forKey: "uploadService." + account))?["jid"] as? String, "upload.example.org")
        XCTAssertEqual(defaults.string(forKey: "groupNickname.\(account).team@rooms.example.org"), "Ellie")
        for key in ["pushOff.", "avatar.", "uploadService."] { XCTAssertNil(defaults.object(forKey: key + typed)) }
        XCTAssertEqual(AccountIdentityMigration.migratePreferences(defaults), [], "a second run finds nothing")

        let directory = FileManager.default.temporaryDirectory.appending(path: "identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = AttachmentFiles(directory: directory, account: typed).stagingURL(messageID: "pending-upload")
        try Data([1]).write(to: staged)
        let avatar = AvatarStore.directory(root: directory, account: typed).appending(path: "abc")
        try FileManager.default.createDirectory(at: avatar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([2]).write(to: avatar)
        _ = AttachmentFiles(directory: directory, account: account) // the normal folder may already exist
        AccountIdentityMigration.moveFiles(directory: directory, spellings: spellings)
        XCTAssertEqual(try Data(contentsOf: AttachmentFiles(directory: directory, account: account).stagingURL(messageID: "pending-upload")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: AvatarStore.directory(root: directory, account: account).appending(path: "abc")), Data([2]))
    }

    func testSavedCredentialsAreReadInNormalFormWithEveryOtherFieldKept() throws {
        let legacy = #"{"accountID":"Ellie@Example.org","host":"xmpp.example.org","port":5223,"domain":"Example.org","username":"Ellie","password":"synthetic","futureField":true}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: NotificationAccount.normalizingIdentity(Data(legacy.utf8))) as? [String: Any])
        XCTAssertEqual(object["accountID"] as? String, account)
        XCTAssertEqual(object["username"] as? String, "ellie")
        XCTAssertEqual(object["domain"] as? String, "example.org")
        XCTAssertEqual(object["host"] as? String, "xmpp.example.org")
        XCTAssertEqual(object["futureField"] as? Bool, true)
        let decoded = try JSONDecoder().decode(NotificationAccount.self, from: NotificationAccount.normalizingIdentity(Data(legacy.utf8)))
        XCTAssertEqual(decoded.accountID, decoded.username + "@" + decoded.domain)
    }

    func testPushRegistrationSavedUnderTheTypedSpellingMovesToTheNormalKey() throws {
        let local = "P0Test" + UUID().uuidString.prefix(8)
        let typed = local + "@Example.org", normal = local.lowercased() + "@example.org"
        let push = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "synthetic-node")
        var saved = PushRegistrationState(accountID: typed, configuration: push, journal: .init())
        saved.disablePending = true
        try saved.save()
        PushRegistrationState.normalizeSavedAccounts()
        let moved = try XCTUnwrap(PushRegistrationState.load(accountID: normal))
        XCTAssertEqual(moved.configuration, push)
        XCTAssertTrue(moved.disablePending)
        XCTAssertNil(try PushRegistrationState.load(accountID: typed))
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "haus.xmpp.push-registration",
                       kSecAttrAccount as String: normal] as CFDictionary)
    }
}
