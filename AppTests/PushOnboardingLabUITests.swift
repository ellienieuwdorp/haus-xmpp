import XCTest

/// Opt-in drill against a push lab that is not part of this repository: a disposable account on a Prosody with
/// cloud_notify and a stand-in gateway component, which the DEBUG build reaches through `XMPP_PUSH_SERVICE`. Signing
/// in must ask for notification permission once, then register a freshly generated node and enable it without any
/// other step. Uses the primary store on purpose (UI-test stores skip push), so run it only on a disposable simulator.
final class PushOnboardingLabUITests: XCTestCase {
    @MainActor func testSignInRegistersAndEnablesPushByItself() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["HAUS_PUSH_LAB"] == "1", let user = env["HAUS_LAB_USERNAME"], let password = env["HAUS_LAB_PASSWORD"],
              let service = env["XMPP_PUSH_SERVICE"], let ca = env["HAUS_LAB_CA_DER"] else {
            throw XCTSkip("Opt-in push-lab drill: needs HAUS_PUSH_LAB=1 and a push gateway lab; see AppTests/README.md")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["HAUS_LAB_USERNAME": user, "HAUS_LAB_PASSWORD": password, "XMPP_PUSH_SERVICE": service,
                                 "HAUS_LAB_CA_DER": ca]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["accountSignIn"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Connect"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 25), "The first sign-in asks for notification permission")
        // Push setup runs after the sign-in returns: the sheet closes while the prompt is still up, not after the
        // gateway answered.
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Connect"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "The sign-in sheet must not wait for the permission prompt")
        XCTAssertTrue(allow.exists)
        allow.tap()

        let push = app.switches["pushNotifications"]
        XCTAssertTrue(push.waitForExistence(timeout: 10))
        let settled = NSPredicate(format: "label ENDSWITH %@ OR label ENDSWITH %@", ", On", ", Couldn't reach the push service")
        wait(for: [XCTNSPredicateExpectation(predicate: settled, object: push)], timeout: 40)
        attach(app, "Settings, push \(push.label.hasSuffix(", On") ? "on" : "unreachable"), light")
        setAppearance(app, "Dark")
        attach(app, "Settings, push, dark")
        setAppearance(app, "Automatic")
        XCTAssertTrue(push.label.hasSuffix(", On"), "Registration and enable must both succeed: \(push.label)")
        XCTAssertEqual(push.value as? String, "1")

        // Turning it off revokes and disables; turning it on again re-registers the same node.
        push.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", ", Off"), object: push)], timeout: 10)
        attach(app, "Settings, push off")
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

    /// Lets an appearance change or a toggle animation finish before a review capture.
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) { capture(app, name, settle: 1.5) }
}
