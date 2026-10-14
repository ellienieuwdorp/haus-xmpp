import XCTest

/// Explicit physical staging setup, never part of ordinary simulator/UI runs. This uses the
/// primary App Group store because an NSE cannot see the isolated UI-test database. Credentials
/// and the one-device push subscription must belong to generated disposable staging fixtures.
final class PushUITests: XCTestCase {
    @MainActor func testPrepareNotificationInspectionAndEnterBackground() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires opted-in physical staging fixture")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["XMPP_PUSH_DEVICE_TEST"] == "1",
              let expected = environment["XMPP_EXPECTED_MESSAGE"], expected.hasPrefix("Synthetic"), expected.utf8.count <= 100 else {
            throw XCTSkip("Requires explicitly selected synthetic notification fixture")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--inspect-notification", "-staging"]
        app.launchEnvironment = ["XMPP_EXPECTED_MESSAGE": expected]
        if let preference = environment["XMPP_NOTIFICATION_PREVIEWS"] {
            XCTAssertTrue(["0", "1"].contains(preference))
            app.launchEnvironment["XMPP_NOTIFICATION_PREVIEWS"] = preference
        }
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let push = app.switches["pushNotifications"]
        XCTAssertTrue(push.waitForExistence(timeout: 15))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Inspection complete"), object: push)], timeout: 15)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.waitForBackground())
        #endif
    }

    @MainActor func testRegisterStagingPushAndEnterBackground() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical APNs registration requires the opted-in staging iPhone run")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["XMPP_PUSH_DEVICE_TEST"] == "1" else {
            throw XCTSkip("Set XMPP_PUSH_DEVICE_TEST=1 only for a disposable physical staging push run")
        }
        // The app generates its own node and secret and registers them with push.xmpp.haus after sign-in.
        let required = ["HAUS_LAB_USERNAME", "HAUS_LAB_PASSWORD", "XMPP_OMEMO_PEER"]
        guard required.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
            throw XCTSkip("Requires generated staging account environment")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test", "-staging", "-push-diagnostics"]
        app.launchEnvironment = Dictionary(uniqueKeysWithValues: required.map { ($0, environment[$0]!) })
        // Deliberately do not call isolateMessageStorage: the extension shares primary state.
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.buttons["accountSignIn"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        allowSystemPermissionIfPresent()

        // Sign-in asks for notification permission and then enables push by itself.
        allowSystemPermissionIfPresent()
        let push = app.switches["pushNotifications"]
        XCTAssertTrue(push.waitForExistence(timeout: 25), "Staging account must connect and dismiss its sheet")
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", ", On"), object: push)], timeout: 40)

        // App-only screenshot stays in the private xcresult. Never capture SpringBoard,
        // print environment values, or attach push-registration.json to the test report.
        capture(app, "Private staging push registration")
        establishEncryptedRoundTrip(app, peer: environment["XMPP_OMEMO_PEER"]!)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.waitForBackground(),
                      "App must enter the background so its scene releases transport ownership")
        // The peer now sends synthetic encrypted traffic, and APNs and notification extension
        // output are verified separately. Registration alone is not evidence of notification delivery.
        #endif
    }

    @MainActor private func establishEncryptedRoundTrip(_ app: XCUIApplication, peer: String) {
        app.returnToChats()
        app.buttons["newConversation"].tap()
        let address = app.textFields["newChatAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText(peer)
        app.buttons["startChat"].tap()
        let composer = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let marker = "Synthetic push bootstrap \(UUID().uuidString.prefix(8))"
        composer.tap(); composer.typeText(marker)
        app.buttons["sendMessage"].tap()
        let queued = app.textViews.containing(NSPredicate(format: "value == %@", marker))
            .matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "Send must durably enqueue before fingerprint review")
        app.openEncryptionDetails()
        XCTAssertTrue(app.navigationBars["Devices & Encryption"].waitForExistence(timeout: 5))
        // Approval goes through the displayed fingerprint UI for generated fixture devices.
        // Already approved devices on a repeat staging run need no second acceptance.
        app.acceptPendingDevices()
        app.closeEncryptionDetails()
        let bubbles = app.textViews.containing(NSPredicate(format: "value == %@", marker))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: bubbles)], timeout: 40)
        let outgoing = bubbles.matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(outgoing.exists)
        XCTAssertTrue(serverHeldLabel.evaluate(with: outgoing) || outgoing.label.contains("Sending, not yet confirmed"))
        XCTAssertTrue(bubbles.allElementsBoundByIndex.contains { !$0.label.hasPrefix("You:") },
                      "The independent peer must return an authenticated incoming echo")
        capture(app, "Private staging encrypted bootstrap")
    }

    @MainActor private func allowSystemPermissionIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }
}
