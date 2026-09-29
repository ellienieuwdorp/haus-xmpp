import XCTest
import UserNotifications
import MessagingCore
import XMPPProtocol
@testable import HausXMPP

@MainActor final class PushSetupTests: XCTestCase {
    func testDebugBuildRegistersSandboxTokensWithTheHausGateway() {
        // The test host is the Debug app: project.yml sets HAUS_PUSH_ENVIRONMENT=sandbox for it.
        XCTAssertEqual(PushService.environment, .sandbox)
        XCTAssertEqual(PushService.defaultServiceJID, "push.xmpp.haus")
        XCTAssertEqual(PushService.serviceJID, "push.xmpp.haus")
    }

    func testPermissionGateAsksOnlyWhenInteractive() {
        XCTAssertNil(PushStatus.gate(for: .authorized, interactive: false))
        XCTAssertNil(PushStatus.gate(for: .provisional, interactive: false))
        XCTAssertNil(PushStatus.gate(for: .notDetermined, interactive: true))
        XCTAssertEqual(PushStatus.gate(for: .notDetermined, interactive: false), .off)
        XCTAssertEqual(PushStatus.gate(for: .denied, interactive: true), .notAllowed)
    }

    func testFailuresMapToTheSettingsCopy() {
        XCTAssertEqual(PushStatus.after(XMPPNotificationError.pushUnavailable), .unsupported)
        XCTAssertEqual(PushStatus.after(PushRegistration.Failure.denied), .notAllowed)
        XCTAssertEqual(PushStatus.after(PushRegistration.Failure.unavailable), .unreachable)
        XCTAssertEqual(PushStatus.after(XMPPIQError.stanza(condition: "remote-server-not-found")), .unreachable)
        XCTAssertEqual(PushStatus.after(XMPPNotificationError.invalidConfiguration), .unreachable)
        XCTAssertEqual(PushStatus.unsupported.text, "Your server doesn't support push notifications")
        XCTAssertEqual(PushStatus.notAllowed.text, "Off (not allowed in iOS Settings)")
        XCTAssertEqual(PushStatus.unreachable.text, "Couldn't reach the push service")
        XCTAssertEqual(PushStatus.settingUp.text, "Setting up…")
        XCTAssertEqual(PushStatus.on.text, "On")
    }

    func testStagingSubscriptionIsReplacedAndAHausOneKept() throws {
        let staging = try XMPPPushConfiguration(serviceJID: "push.staging.example.net", node: String(repeating: "n", count: 43),
                                                publishOptions: ["secret": String(repeating: "s", count: 43)])
        XCTAssertEqual(PushSubscription.plan(saved: staging, serviceJID: PushService.serviceJID), .replace(staging))
        let current = try PushSubscription.generate(serviceJID: PushService.serviceJID)
        XCTAssertEqual(PushSubscription.plan(saved: current, serviceJID: PushService.serviceJID), .keep(current))
        XCTAssertEqual(PushSubscription.plan(saved: nil, serviceJID: PushService.serviceJID), .create)
    }

    func testReplacingPushKeepsCredentialsForTheExtension() throws {
        let account = NotificationAccount(accountID: "alice@example.org", host: "example.org", port: 5223, domain: "example.org",
                                          username: "alice", password: "synthetic", push: nil)
        let push = try PushSubscription.generate(serviceJID: PushService.serviceJID)
        let enabled = account.replacingPush(push)
        XCTAssertEqual(enabled.push, push)
        XCTAssertEqual(enabled.replacingPush(nil), account)
        XCTAssertEqual(enabled.password, "synthetic")
    }
}
