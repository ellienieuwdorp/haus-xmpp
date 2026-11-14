import XCTest
import XMPPProtocol
@testable import HausXMPP

// The FAST token store against the real Keychain under a test service: per account, gone on delete, and never written
// while the sign-out tombstone stands.
final class FastTokenKeychainTests: XCTestCase {
    private let token = XMPPFastToken(mechanism: "HT-SHA-256-EXPR", secret: "secret-token:fast-synthetic", expiry: .distantFuture)

    private func store() -> (FastTokenKeychain, URL) {
        let service = "haus.xmpp.tests.fast-token.\(UUID().uuidString)"
        let tombstone = FileManager.default.temporaryDirectory.appending(path: "fast-token-gate-\(UUID().uuidString)")
        addTeardownBlock {
            try? FastTokenKeychain.remove(account: "alice@example.org", service: service)
            try? FastTokenKeychain.remove(account: "bob@example.org", service: service)
            try? FileManager.default.removeItem(at: tombstone)
        }
        return (FastTokenKeychain(service: service, tombstone: { tombstone }), tombstone)
    }

    func testTokensArePerAccountAndDeleted() {
        let (tokens, _) = store()
        tokens.saveFastToken(token, account: "alice@example.org")
        XCTAssertEqual(tokens.fastToken(account: "alice@example.org"), token)
        XCTAssertNil(tokens.fastToken(account: "bob@example.org"))
        let rotated = XMPPFastToken(mechanism: token.mechanism, secret: "secret-token:fast-rotated", expiry: .distantFuture)
        tokens.saveFastToken(rotated, account: "alice@example.org")
        XCTAssertEqual(tokens.fastToken(account: "alice@example.org"), rotated)
        tokens.saveFastToken(nil, account: "alice@example.org")
        XCTAssertNil(tokens.fastToken(account: "alice@example.org"))
    }

    func testNothingIsSavedOrReadWhileTheSignOutTombstoneStands() throws {
        let (tokens, tombstone) = store()
        tokens.saveFastToken(token, account: "alice@example.org")
        try NotificationAccessGate.disable(at: tombstone)
        XCTAssertNil(tokens.fastToken(account: "alice@example.org"))
        tokens.saveFastToken(token, account: "bob@example.org")
        try NotificationAccessGate.enable(at: tombstone)
        XCTAssertNil(tokens.fastToken(account: "bob@example.org"), "a sign-in that outlived the sign-out saved nothing")
        XCTAssertEqual(tokens.fastToken(account: "alice@example.org"), token)
    }
}
