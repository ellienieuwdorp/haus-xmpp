import XCTest

/// Opt-in drill against infra/local/push-lab: a disposable account on a Prosody with cloud_notify and a stand-in
/// gateway component, which the DEBUG build reaches through `XMPP_PUSH_SERVICE`. Signing in must ask for notification
/// permission once, then register a freshly generated node and enable it without any other step. Uses the primary
/// store on purpose (UI-test stores skip push), so run it only on a disposable simulator.
final class PushOnboardingLabUITests: XCTestCase {
    @MainActor func testSignInRegistersAndEnablesPushByItself() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["HAUS_PUSH_LAB"] == "1", let user = env["HAUS_LAB_USERNAME"], let password = env["HAUS_LAB_PASSWORD"],
              let service = env["XMPP_PUSH_SERVICE"], let ca = env["HAUS_LAB_CA_DER"] else {
            throw XCTSkip("Opt-in push-lab drill: see infra/local/push-lab/README.md")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["HAUS_LAB_USERNAME": user, "HAUS_LAB_PASSWORD": password, "XMPP_PUSH_SERVICE": service,
                                 "HAUS_LAB_CA_DER": ca]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["Connect to local lab"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Connect"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 25), "The first sign-in asks for notification permission")
        allow.tap()

        let push = app.switches["pushNotifications"]
        XCTAssertTrue(push.waitForExistence(timeout: 10))
        let settled = NSPredicate(format: "label ENDSWITH %@ OR label ENDSWITH %@", ", On", ", Couldn't reach the push service")
        wait(for: [XCTNSPredicateExpectation(predicate: settled, object: push)], timeout: 40)
        capture(app, "Settings, push \(push.label.hasSuffix(", On") ? "on" : "unreachable"), light")
        setAppearance(app, "Dark")
        capture(app, "Settings, push, dark")
        setAppearance(app, "Automatic")
        XCTAssertTrue(push.label.hasSuffix(", On"), "Registration and enable must both succeed: \(push.label)")
        XCTAssertEqual(push.value as? String, "1")

        // Turning it off revokes and disables; turning it on again re-registers the same node.
        push.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", ", Off"), object: push)], timeout: 10)
        capture(app, "Settings, push off")
        push.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", ", On"), object: push)], timeout: 40)
    }

    /// The app's own appearance setting, which overrides the system's.
    @MainActor private func setAppearance(_ app: XCUIApplication, _ mode: String) {
        let row = app.buttons["appearanceRow"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons[mode].waitForExistence(timeout: 5))
        app.buttons[mode].tap()
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let push = app.switches["pushNotifications"]
        for _ in 0..<4 where !push.isHittable { app.swipeDown() }
        XCTAssertTrue(push.isHittable)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        // Let an appearance change or a toggle animation finish before the screenshot.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
