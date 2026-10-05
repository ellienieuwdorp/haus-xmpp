import XCTest
import XMPPProtocol
@testable import HausXMPP

@MainActor final class NotificationAccountTests: XCTestCase {
    func testReconnectPreservesSubscriptionAndNewCredentials() throws {
        let push = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "synthetic-node", publishOptions: ["secret": "synthetic-secret"])
        let previous = account(username: "alice", password: "old", push: push)
        let replacement = account(username: "alice", password: "new")
        let restored = AppModel.retainingSavedState(previous: previous, replacement: replacement)
        XCTAssertEqual(restored.push, push)
        XCTAssertEqual(restored.password, "new")
        XCTAssertEqual(restored.accountID, replacement.accountID)
    }

    func testSubscriptionCannotCrossAccountsOrReplaceExplicitNewRegistration() throws {
        let old = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "old-node")
        let new = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "new-node")
        let previous = account(username: "alice", password: "synthetic", push: old)
        let different = AppModel.retainingSavedState(previous: previous, replacement: account(username: "bob", password: "synthetic"))
        XCTAssertNil(different.push)
        let explicit = AppModel.retainingSavedState(previous: previous, replacement: account(username: "alice", password: "synthetic", push: new))
        XCTAssertEqual(explicit.push, new)
    }

    /// Typing the password again must not lift downgrade protection or forget the endpoint that worked.
    func testReEnteredCredentialsKeepTheSCRAMPinAndTheWorkingEndpoint() {
        let working = XMPPEndpoint(host: "xmpp.example.net", port: 443, security: .directTLS)
        let previous = account(username: "alice", password: "old", discovers: true)
            .connected(XMPPConnectedSession(endpoint: working, authenticatedWithSCRAM: true))
        let retyped = AppModel.retainingSavedState(previous: previous, replacement: account(username: "alice", password: "new", discovers: true))
        XCTAssertTrue(retyped.requiresSCRAM)
        XCTAssertEqual(retyped.route, .discover(preferred: working))
        XCTAssertEqual(retyped.password, "new")
        let manual = XMPPEndpoint(host: "example.org", port: 5222, security: .startTLS)
        let typedServer = AppModel.retainingSavedState(previous: previous, replacement: account(username: "alice", password: "new", endpoint: manual))
        XCTAssertEqual(typedServer.route, .fixed(manual))
        XCTAssertTrue(typedServer.requiresSCRAM)
        XCTAssertFalse(AppModel.retainingSavedState(previous: previous, replacement: account(username: "bob", password: "new", discovers: true)).requiresSCRAM)
        // A discovering account that never connected has no endpoint to prefer, and cannot be saved.
        XCTAssertEqual(account(username: "carol", password: "new", discovers: true).route, .discover(preferred: nil))
        XCTAssertThrowsError(try account(username: "carol", password: "new", discovers: true).save())
    }

    /// Records saved before this change were direct TLS to one fixed endpoint, authenticated with PLAIN.
    func testRecordsWithoutEndpointFieldsDecodeAsTheFixedDirectTLSEndpoint() throws {
        let legacy = #"{"accountID":"alice@example.org","host":"example.org","port":5223,"domain":"example.org","username":"alice","password":"synthetic"}"#
        let decoded = try JSONDecoder().decode(NotificationAccount.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.route, .fixed(XMPPEndpoint(host: "example.org", port: 5223, security: .directTLS)))
        XCTAssertFalse(decoded.requiresSCRAM)
        let pinned = decoded.connected(XMPPConnectedSession(endpoint: decoded.endpoint, authenticatedWithSCRAM: true))
        XCTAssertEqual(try JSONDecoder().decode(NotificationAccount.self, from: try JSONEncoder().encode(pinned)), pinned)
    }

    private func account(username: String, password: String, push: XMPPPushConfiguration? = nil, discovers: Bool = false,
                         endpoint: XMPPEndpoint = XMPPEndpoint(host: "example.org", port: 5223, security: .directTLS)) -> NotificationAccount {
        NotificationAccount(accountID: username + "@example.org", host: discovers ? "" : endpoint.host, port: discovers ? 0 : endpoint.port,
            security: endpoint.security, discoversEndpoint: discovers, domain: "example.org", username: username, password: password, push: push)
    }
}
