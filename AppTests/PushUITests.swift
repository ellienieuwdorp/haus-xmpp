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
        XCTAssertTrue(app.staticTexts["Status, Inspection complete"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
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
        let required = ["XMPP_LAB_USERNAME", "XMPP_LAB_PASSWORD", "XMPP_PUSH_NODE", "XMPP_PUSH_SECRET", "XMPP_OMEMO_PEER"]
        guard required.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
            throw XCTSkip("Requires generated staging account and push subscription environment")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test", "-staging", "-push-diagnostics"]
        app.launchEnvironment = Dictionary(uniqueKeysWithValues: required.map { ($0, environment[$0]!) })
        // Deliberately do not call isolateMessageStorage: the extension shares primary state.
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.buttons["Connect to local lab"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        allowSystemPermissionIfPresent()

        let enable = app.buttons["enableNotifications"]
        XCTAssertTrue(enable.waitForExistence(timeout: 25), "Staging account must connect and dismiss its sheet")
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: enable)], timeout: 30)
        enable.tap()
        allowSystemPermissionIfPresent()
        // The physical failure's AX hierarchy exposes SwiftUI LabeledContent as one row:
        // `Status, Enabled for staging`, not a standalone value StaticText.
        XCTAssertTrue(app.staticTexts["Status, Enabled for staging"].waitForExistence(timeout: 25),
                      "APNs registration and server push IQ must both succeed")

        // App-only screenshot stays in the private xcresult. Never capture SpringBoard,
        // print environment values, or attach push-registration.json to the test report.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Private staging push registration"
        attachment.lifetime = .keepAlways
        add(attachment)
        establishEncryptedRoundTrip(app, peer: environment["XMPP_OMEMO_PEER"]!)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended,
                      "App must enter the background so its scene releases transport ownership")
        // The orchestrator now sends synthetic encrypted traffic and verifies actual APNs/NSE
        // output separately. Registration alone is not evidence of notification delivery.
        #endif
    }

    @MainActor private func establishEncryptedRoundTrip(_ app: XCUIApplication, peer: String) {
        app.buttons["Chats"].tap()
        app.buttons["newConversation"].tap()
        let address = app.textFields["name@server"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText(peer)
        app.buttons["Create conversation"].tap()
        let composer = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let marker = "Synthetic push bootstrap \(UUID().uuidString.prefix(8))"
        composer.tap(); composer.typeText(marker)
        app.buttons["sendMessage"].tap()
        let queued = app.textViews.containing(NSPredicate(format: "value == %@", marker))
            .matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "Send must durably enqueue before fingerprint review")
        app.buttons["encryptionDetails"].tap()
        XCTAssertTrue(app.navigationBars["Encryption"].waitForExistence(timeout: 5))
        let devices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "encryptionDevice."))
        XCTAssertTrue(devices.firstMatch.waitForExistence(timeout: 20))
        // Approval goes through the displayed fingerprint UI for generated fixture devices.
        // Already approved devices on a repeat staging run need no second acceptance.
        for _ in 0..<20 {
            let pending = devices.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
            if !pending.exists { break }
            for _ in 0..<5 { if pending.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(pending.isHittable)
            pending.tap()
            let accept = app.buttons["Accept without verifying"]
            XCTAssertTrue(accept.waitForExistence(timeout: 5))
            accept.tap()
            XCTAssertTrue(app.navigationBars["Encryption"].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(devices.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch.exists)
        app.buttons["Done"].tap()
        let bubbles = app.textViews.containing(NSPredicate(format: "value == %@", marker))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: bubbles)], timeout: 40)
        let outgoing = bubbles.matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(outgoing.exists)
        XCTAssertTrue(outgoing.label.contains("Accepted by server") || outgoing.label.contains("Delivery unconfirmed"))
        XCTAssertTrue(bubbles.allElementsBoundByIndex.contains { !$0.label.hasPrefix("You:") },
                      "The independent peer must return an authenticated incoming echo")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Private staging encrypted bootstrap"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func allowSystemPermissionIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }
}
