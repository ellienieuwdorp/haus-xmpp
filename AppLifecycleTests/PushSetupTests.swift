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

    // The development app's tokens belong to its own APNs topic; the released app's registrations keep the gateway's
    // default.
    func testRegistrationsNameTheAPNsTopicUnlessItIsTheGatewayDefault() {
        XCTAssertEqual(PushService.topic, Bundle.main.bundleIdentifier)
        XCTAssertNotEqual(PushService.topic, PushService.gatewayDefaultTopic)
        XCTAssertNil(PushService.topic(bundleIdentifier: "haus.xmpp.ios"))
        XCTAssertEqual(PushService.topic(bundleIdentifier: "haus.xmpp.ios.dev"), "haus.xmpp.ios.dev")
    }

    func testPermissionGateAsksOnlyWhenInteractive() {
        XCTAssertNil(PushStatus.gate(for: .authorized, interactive: false))
        XCTAssertNil(PushStatus.gate(for: .provisional, interactive: false))
        XCTAssertNil(PushStatus.gate(for: .notDetermined, interactive: true))
        XCTAssertEqual(PushStatus.gate(for: .notDetermined, interactive: false), .off)
        XCTAssertEqual(PushStatus.gate(for: .denied, interactive: true), .notAllowed)
    }

    // Under quiet delivery macOS skips the extension, so a push would add the gateway's generic text beside the app's
    // own notification.
    func testMacGateNeedsAlerts() {
        XCTAssertNil(PushStatus.gate(for: .authorized, alertStyle: .banner, interactive: false))
        XCTAssertNil(PushStatus.gate(for: .authorized, alertStyle: .alert, interactive: false))
        XCTAssertEqual(PushStatus.gate(for: .authorized, alertStyle: .none, interactive: false), .notAllowed)
        XCTAssertEqual(PushStatus.gate(for: .provisional, alertStyle: .none, interactive: false), .notAllowed)
        XCTAssertEqual(PushStatus.gate(for: .denied, alertStyle: .none, interactive: true), .notAllowed)
        XCTAssertNil(PushStatus.gate(for: .notDetermined, alertStyle: .none, interactive: true))
        XCTAssertEqual(PushStatus.gate(for: .notDetermined, alertStyle: .none, interactive: false), .off)
    }

    // A reconnect stops at Off while the prompt is unanswered; an answer from Settings, even a no, finishes that setup.
    // A switch turned off, a setup not stopped, an unanswered prompt or a build without push start nothing.
    func testAnsweredPromptResumesOnlyASetupStoppedForIt() {
        for answer: UNAuthorizationStatus in [.authorized, .provisional, .denied] {
            XCTAssertTrue(PushStatus.resumesSetup(after: answer, status: .off, wanted: true, offered: true), "\(answer.rawValue)")
        }
        XCTAssertFalse(PushStatus.resumesSetup(after: .authorized, status: .off, wanted: false, offered: true), "turned off")
        XCTAssertFalse(PushStatus.resumesSetup(after: .notDetermined, status: .off, wanted: true, offered: true), "unanswered")
        XCTAssertFalse(PushStatus.resumesSetup(after: .authorized, status: .off, wanted: true, offered: false), "no push in this build")
        for status: PushStatus in [.on, .settingUp, .notAllowed, .unsupported, .unreachable] {
            XCTAssertFalse(PushStatus.resumesSetup(after: .authorized, status: status, wanted: true, offered: true), "\(status)")
        }
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

    // Settings keeps saying "Off" while a failed revocation or disable retries silently.
    func testTurnedOffPushReportsOffWhateverTheCleanupHit() {
        XCTAssertEqual(PushStatus.settled(after: XMPPClientError.timedOut, wanted: false), .off)
        XCTAssertEqual(PushStatus.settled(after: XMPPNotificationError.pushUnavailable, wanted: false), .off)
        XCTAssertEqual(PushStatus.settled(after: XMPPClientError.timedOut, wanted: true), .unreachable)
    }

    // A subscription with no journal entry is only in the saved account; without staged cleanup the switch would read
    // Off while the account server keeps publishing.
    func testTurningOffAnUnjournaledSubscriptionStagesItsCleanup() throws {
        let push = try PushSubscription.generate(serviceJID: PushService.serviceJID)
        let state = try XCTUnwrap(PushRegistrationState.turningOff(accountID: "alice@example.org", saved: nil, enabled: push))
        XCTAssertEqual(state.configuration, push)
        XCTAssertEqual(state.journal.pending?.action, .revoke)
        XCTAssertTrue(state.disablePending)
        XCTAssertNil(try PushRegistrationState.turningOff(accountID: "alice@example.org", saved: nil, enabled: nil))
    }

    // The disable is stored apart from the gateway revocation and stays owed across a save and load.
    func testSettledRevocationStillOwesTheDisable() throws {
        let push = try PushSubscription.generate(serviceJID: PushService.serviceJID)
        var registered = PushRegistrationState(accountID: "alice@example.org", configuration: push, journal: PushRegistrationJournal())
        let register = try registered.journal.stageFreshRegistration(deviceToken: "abcd")
        XCTAssertTrue(registered.journal.abandonPending(register))
        var state = try XCTUnwrap(PushRegistrationState.turningOff(accountID: "alice@example.org", saved: registered, enabled: push))
        XCTAssertEqual(state.journal.pending?.revision, 2)
        XCTAssertTrue(state.journal.abandonPending(try XCTUnwrap(state.journal.pending)))
        let reloaded = try JSONDecoder().decode(PushRegistrationState.self, from: JSONEncoder().encode(state))
        XCTAssertNil(reloaded.journal.pending)
        XCTAssertTrue(reloaded.disablePending)
    }

    // Items saved without the marker owe a disable only with a staged revocation.
    func testEarlierSavedStateOwesADisableOnlyWithAStagedRevocation() throws {
        let push = try PushSubscription.generate(serviceJID: PushService.serviceJID)
        var journal = PushRegistrationJournal()
        try journal.stageRevocation()
        for (journal, owed) in [(journal, true), (PushRegistrationJournal(), false)] {
            let current = PushRegistrationState(accountID: "alice@example.org", configuration: push, journal: journal, disablePending: !owed)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
            XCTAssertNotNil(object.removeValue(forKey: "disablePending"))
            let earlier = try JSONDecoder().decode(PushRegistrationState.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(earlier.disablePending, owed)
        }
    }

    // Only an answer that proves nothing is left settles stored cleanup.
    func testCleanupSettlesOnAnswersNotOnLostConnections() {
        let current = false, retired = true
        XCTAssertTrue(PushCleanup.revocationSettles(XMPPIQError.stanza(condition: "item-not-found"), retired: current))
        XCTAssertTrue(PushCleanup.revocationSettles(XMPPIQError.stanza(condition: "forbidden"), retired: current))
        XCTAssertFalse(PushCleanup.revocationSettles(XMPPIQError.stanza(condition: "remote-server-not-found"), retired: current))
        XCTAssertFalse(PushCleanup.revocationSettles(XMPPClientError.timedOut, retired: current))
        XCTAssertTrue(PushCleanup.revocationSettles(XMPPIQError.stanza(condition: "service-unavailable"), retired: retired))
        XCTAssertTrue(PushCleanup.revocationSettles(XMPPClientError.timedOut, retired: retired))
        for lost: any Error in [XMPPClientError.connectionClosed, XMPPClientError.notConnected, CancellationError()] {
            XCTAssertFalse(PushCleanup.revocationSettles(lost, retired: retired))
            XCTAssertFalse(PushCleanup.revocationSettles(lost, retired: current))
            XCTAssertFalse(PushCleanup.disableSettles(lost))
        }
        XCTAssertTrue(PushCleanup.disableSettles(XMPPIQError.stanza(condition: "item-not-found")))
        XCTAssertTrue(PushCleanup.disableSettles(XMPPNotificationError.pushUnavailable))
        XCTAssertFalse(PushCleanup.disableSettles(XMPPClientError.timedOut))
    }

    // A session the app did not set up (the extension, a notification action) never re-enables a subscription that is
    // still being registered, revoked or disabled.
    func testOnlyASettledRegistrationIsReenabledAfterAFreshBind() throws {
        let push = try PushSubscription.generate(serviceJID: PushService.serviceJID)
        var settled = PushRegistrationState(accountID: "alice@example.org", configuration: push, journal: PushRegistrationJournal())
        let register = try settled.journal.stageFreshRegistration(deviceToken: "abcd")
        XCTAssertNil(PushRegistrationState.sessionSubscription(saved: push, state: settled), "registration pending")
        XCTAssertTrue(settled.journal.acknowledge(try XMPPPushRegistrationResult(revision: register.revision, action: .register), for: register))
        XCTAssertEqual(PushRegistrationState.sessionSubscription(saved: push, state: settled), push)

        XCTAssertNil(PushRegistrationState.sessionSubscription(saved: nil, state: settled), "turned off")
        XCTAssertNil(PushRegistrationState.sessionSubscription(saved: push, state: nil), "unjournaled")
        let other = try PushSubscription.generate(serviceJID: PushService.serviceJID)
        XCTAssertNil(PushRegistrationState.sessionSubscription(saved: other, state: settled), "another subscription")
        var owed = settled
        owed.disablePending = true
        XCTAssertNil(PushRegistrationState.sessionSubscription(saved: push, state: owed), "disable owed")
        let revoking = try XCTUnwrap(PushRegistrationState.turningOff(accountID: "alice@example.org", saved: settled, enabled: push))
        XCTAssertNil(PushRegistrationState.sessionSubscription(saved: push, state: revoking), "revocation pending")
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
