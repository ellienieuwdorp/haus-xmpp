import XCTest
import XMPPProtocol
@testable import HausXMPP

@MainActor final class NotificationAccountTests: XCTestCase {
    func testReconnectPreservesSubscriptionAndNewCredentials() throws {
        let push = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "synthetic-node", publishOptions: ["secret": "synthetic-secret"])
        let previous = account(username: "alice", password: "old", push: push)
        let replacement = account(username: "alice", password: "new")
        let restored = AppModel.retainingPushSubscription(previous: previous, replacement: replacement)
        XCTAssertEqual(restored.push, push)
        XCTAssertEqual(restored.password, "new")
        XCTAssertEqual(restored.accountID, replacement.accountID)
    }

    func testSubscriptionCannotCrossAccountsOrReplaceExplicitNewRegistration() throws {
        let old = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "old-node")
        let new = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "new-node")
        let previous = account(username: "alice", password: "synthetic", push: old)
        let different = AppModel.retainingPushSubscription(previous: previous, replacement: account(username: "bob", password: "synthetic"))
        XCTAssertNil(different.push)
        let explicit = AppModel.retainingPushSubscription(previous: previous, replacement: account(username: "alice", password: "synthetic", push: new))
        XCTAssertEqual(explicit.push, new)
    }

    private func account(username: String, password: String, push: XMPPPushConfiguration? = nil) -> NotificationAccount {
        NotificationAccount(accountID: username + "@example.org", host: "example.org", port: 5223,
            domain: "example.org", username: username, password: password, push: push)
    }
}
