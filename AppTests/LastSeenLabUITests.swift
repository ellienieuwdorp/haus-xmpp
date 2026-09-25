import XCTest

/// Two clients on the lab: opening a chat with the echo peer asks for its presence, slixmpp approves the
/// subscription on its own, and the header shows "Online". When the peer was started with `--timeout` and that
/// many seconds are in `XMPP_PEER_EXITS_AFTER`, its session ends during the test and the header changes to
/// "Last seen …" from the unavailable presence we watched. Requires `lastactivity` on the lab Prosody.
final class LastSeenLabUITests: XCTestCase {
    @MainActor func testHeaderShowsOnlineThenLastSeenWhenThePeerLeaves() throws {
        continueAfterFailure = false
        let started = Date()
        let env = ProcessInfo.processInfo.environment
        guard let user = env["HAUS_LAB_USERNAME"], let password = env["HAUS_LAB_PASSWORD"], let peer = env["XMPP_OMEMO_PEER"] else {
            throw XCTSkip("Requires disposable local OMEMO echo peer")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["HAUS_LAB_USERNAME": user, "HAUS_LAB_PASSWORD": password]
        app.isolateMessageStorage()
        app.launch()
        app.buttons["Settings"].tap()
        // Sharing defaults on, next to the receipt switches.
        XCTAssertTrue(app.switches["lastSeen"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["lastSeen"].value as? String, "1")
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

        let header = app.buttons["chatDetails"]
        // With the address field focused, the first tap on iOS 27 can only end editing.
        if !header.waitForExistence(timeout: 4), app.buttons["startChat"].exists { app.buttons["startChat"].tap() }
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Online"), object: header)], timeout: 25)
        let online = XCTAttachment(screenshot: app.screenshot()); online.name = "Peer online"; online.lifetime = .keepAlways; add(online)

        // Leaving the foreground drops the socket without closing the stream, so coming back resumes the session
        // (XEP-0198). The server sends no probe answers on a resumed stream: the contact must still read "Online".
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let settled = Date().addingTimeInterval(15)
        while Date() < settled {
            XCTAssertFalse(header.label.contains("Last seen"), "an online contact must not read as gone after a resume: \(header.label)")
            Thread.sleep(forTimeInterval: 1)
        }
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Online"), object: header)], timeout: 10)

        guard let exitsAfter = env["XMPP_PEER_EXITS_AFTER"].flatMap(TimeInterval.init) else { return }
        let remaining = max(0, exitsAfter - Date().timeIntervalSince(started))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Last seen"), object: header)], timeout: remaining + 30)
        let lastSeen = XCTAttachment(screenshot: app.screenshot()); lastSeen.name = "Peer last seen"; lastSeen.lifetime = .keepAlways; add(lastSeen)
    }
}
