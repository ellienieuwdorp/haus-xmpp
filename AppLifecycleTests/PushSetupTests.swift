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

    /// The development app's tokens belong to its own APNs topic, so its registrations name it; the released app's
    /// registrations name none and keep the gateway's default.
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

    /// Turned off, a revocation or disable that failed retries silently: Settings keeps saying "Off" under the Off switch.
    func testTurnedOffPushReportsOffWhateverTheCleanupHit() {
        XCTAssertEqual(PushStatus.settled(after: XMPPClientError.timedOut, wanted: false), .off)
        XCTAssertEqual(PushStatus.settled(after: XMPPNotificationError.pushUnavailable, wanted: false), .off)
        XCTAssertEqual(PushStatus.settled(after: XMPPClientError.timedOut, wanted: true), .unreachable)
    }

    /// A subscription enabled before the registration journal existed is only in the saved account: turning it off must
    /// still stage a revocation and a disable, or the switch reads Off while the account server keeps publishing.
    func testTurningOffAnUnjournaledSubscriptionStagesItsCleanup() throws {
        let push = try PushSubscription.generate(serviceJID: PushService.serviceJID)
        let state = try XCTUnwrap(PushRegistrationState.turningOff(accountID: "alice@example.org", saved: nil, enabled: push))
        XCTAssertEqual(state.configuration, push)
        XCTAssertEqual(state.journal.pending?.action, .revoke)
        XCTAssertTrue(state.disablePending)
        XCTAssertNil(try PushRegistrationState.turningOff(accountID: "alice@example.org", saved: nil, enabled: nil))
    }

    /// The account server's disable is stored apart from the gateway revocation: settling the revocation (acknowledged
    /// or abandoned) leaves the disable owed, across a save and load.
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

    /// Items saved by earlier builds have no marker: a staged revocation there still owes its disable, anything else not.
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

    /// Only an answer that proves nothing is left settles stored cleanup; a dropped connection keeps it for next time.
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

    /// A session the app did not set up (the extension, a notification action) re-enables only a subscription whose
    /// gateway registration is settled: never one still being registered, revoked or disabled, nor another one.
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
