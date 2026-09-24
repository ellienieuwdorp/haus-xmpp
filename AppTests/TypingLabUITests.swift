import XCTest

/// The echo peer run with `--typing` sends `<composing/>`, waits eight seconds, then echoes with `<active/>`:
/// the dots appear at the end of the chat and give way to the echoed message.
final class TypingLabUITests: XCTestCase {
    @MainActor func testPeerTypingShowsDotsThatGiveWayToItsMessage() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let user = env["XMPP_LAB_USERNAME"], let password = env["XMPP_LAB_PASSWORD"], let peer = env["XMPP_OMEMO_PEER"] else {
            throw XCTSkip("Requires disposable local OMEMO echo peer started with --typing")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["XMPP_LAB_USERNAME": user, "XMPP_LAB_PASSWORD": password]
        app.isolateMessageStorage()
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons["Connect to local lab"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Connect"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected")).firstMatch.waitForExistence(timeout: 25))
        app.returnToChats(); app.buttons["newConversation"].tap()
        app.textFields["newChatAddress"].tap(); app.textFields["newChatAddress"].typeText(peer)
        app.buttons["startChat"].tap()
        let composer = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let marker = "Are you typing \(UUID().uuidString.prefix(4))"
        composer.tap(); composer.typeText(marker); app.buttons["sendMessage"].tap()
        app.openEncryptionDetails()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "encryptionDevice."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<20 {
            let pending = rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
            if !pending.exists { break }
            if !pending.isHittable { app.swipeUp() }
            pending.tap()
            XCTAssertTrue(app.buttons["Accept without verifying"].waitForExistence(timeout: 5))
            app.buttons["Accept without verifying"].tap()
            XCTAssertTrue(app.navigationBars["Devices & Encryption"].waitForExistence(timeout: 5))
        }
        app.closeEncryptionDetails()
        let indicator = app.otherElements["typingIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 25))
        XCTAssertTrue(indicator.label.hasSuffix("is typing…"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Peer typing"; shot.lifetime = .keepAlways; add(shot)
        let echoed = app.textViews.containing(NSPredicate(format: "value == %@", marker)).matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", "You:")).firstMatch
        XCTAssertTrue(echoed.waitForExistence(timeout: 25))
        // The `active` riding on the echo clears the dots with the load that shows it.
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: indicator)], timeout: 5)
        // Our side: composing, paused after five quiet seconds, then active when the draft empties.
        // The peer logs each as CHAT_STATE_RECEIVED; this test cannot read that log, so it only drives the composer.
        composer.tap(); composer.typeText("Still here")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 6.5))
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Still here".count))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    }
}
