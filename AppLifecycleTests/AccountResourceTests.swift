import XCTest
import Foundation
import XMPPProtocol
@testable import HausXMPP

// The declarations in `AccountResource` against the code that handles each resource: what a transfer packs, what
// sign-out forgets, which folders travel, and that each declared key is the one its writer uses.
final class AccountResourceTests: XCTestCase {
    private let account = "alice@example.org"

    private func suite(_ name: String) throws -> UserDefaults {
        let suite = "haus.xmpp.tests.resources.\(name).\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private var preferences: [(AccountResource, [AccountResource.Domain], String)] {
        AccountResource.allCases.compactMap { resource in
            guard case let .preference(domains, key) = resource.policy.location else { return nil }
            return (resource, domains, key(account))
        }
    }

    func testATransferPacksExactlyThePreferencesDeclaredToCopy() {
        XCTAssertFalse(preferences.isEmpty)
        for (resource, _, key) in preferences {
            XCTAssertEqual(AccountTransfer.isTransferable(preference: key), resource.policy.transfer == .copy,
                           "\(resource) (`\(key)`) is declared \(resource.policy.transfer); change AccountTransfer.installOnlyPrefixes or the declaration")
        }
    }

    func testSignOutForgetsExactlyThePreferencesDeclaredToDelete() throws {
        let app = try suite("app"), group = try suite("group"), other = "bob@example.org"
        for (_, domains, key) in preferences {
            for domain in domains { (domain == .app ? app : group).set("seeded", forKey: key) }
        }
        let others = AccountResource.allCases.compactMap { resource -> String? in
            guard case let .preference(_, key) = resource.policy.location, key(other) != key(account) else { return nil }
            return key(other)
        }
        for key in others { app.set("other", forKey: key); group.set("other", forKey: key) }

        AccountResource.forgetPreferencesAtSignOut(of: account, app: app, group: group)

        for (resource, domains, key) in preferences {
            for domain in domains {
                let value = (domain == .app ? app : group).object(forKey: key)
                switch resource.policy.signOut {
                case .delete: XCTAssertNil(value, "sign-out is declared to forget \(resource) (`\(key)`, \(domain)); forgetPreferencesAtSignOut keeps it")
                case .keep: XCTAssertNotNil(value, "sign-out is declared to keep \(resource) (`\(key)`, \(domain)); forgetPreferencesAtSignOut removes it")
                }
            }
        }
        for key in others { XCTAssertEqual(app.string(forKey: key), "other", key); XCTAssertEqual(group.string(forKey: key), "other", key) }
    }

    // Transfers and pre-upgrade copies both carry `PreUpgradeSnapshot.folders`.
    func testTheDeclaredFoldersAreTheOnesTransfersAndBackupsCarry() {
        let folders = AccountResource.allCases.compactMap { resource -> String? in
            guard case let .folder(name) = resource.policy.location else { return nil }
            XCTAssertEqual(resource.policy.transfer, .copy, "\(resource): every folder in PreUpgradeSnapshot.folders is packed")
            return name
        }
        XCTAssertEqual(Set(folders), Set(PreUpgradeSnapshot.folders))
    }

    // Every key the writers leave is one the declarations spell.
    func testTheDeclaredKeysAreTheOnesTheWritersUse() throws {
        let app = try suite("app"), group = try suite("group")
        BlockedAddresses.save(XMPPBlocklist(["spam@example.org"]), accountID: account, defaults: group)
        ShareSuggestionSetting.set(false, accountID: account, defaults: group)
        _ = SharedSession.resource(accountID: account, defaults: group)
        _ = UploadServiceMemory(defaults: app, mirror: group)
            .settle(account: account, previous: nil, discovery: .success(XMPPUploadService(jid: "upload.example.org", maximumFileSize: 1)))
        let profiles = ServerProfileMemory(defaults: app)
        profiles.discovered(["urn:xmpp:mam:2"], account: account)
        profiles.carbonsEnabled(account: account, stream: "stream-1")

        let declared = { (domain: AccountResource.Domain) in Set(self.preferences.filter { $0.1.contains(domain) }.map(\.2)) }
        for (domain, defaults) in [(AccountResource.Domain.app, app), (.group, group)] {
            let written = Set(defaults.dictionaryRepresentation().keys.filter { $0.contains(account) })
            XCTAssertFalse(written.isEmpty)
            XCTAssertEqual(written.subtracting(declared(domain)), [], "\(domain) keys no AccountResource declares")
        }
    }
}
