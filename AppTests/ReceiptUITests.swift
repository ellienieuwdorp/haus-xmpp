import XCTest

/// Two clients on the lab: the echo peer answers `<request/>` with a receipt and `<markable/>` with a
/// read marker, so an accepted bubble climbs to delivered and then read without ever changing width.
final class ReceiptUITests: XCTestCase {
    @MainActor func testSentMessageClimbsFromAcceptedToDeliveredToReadInsideAFixedFooter() throws {
        continueAfterFailure = false
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
        // The switches live outside any staging gate and default on.
        XCTAssertTrue(app.switches["deliveryReceipts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["deliveryReceipts"].value as? String, "1")
        XCTAssertEqual(app.switches["readReceipts"].value as? String, "1")
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
        // With the address field focused, the first tap on iOS 27 can only end editing.
        if !app.buttons["chatDetails"].waitForExistence(timeout: 4), app.buttons["startChat"].exists { app.buttons["startChat"].tap() }
        let composer = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let marker = "Please confirm \(UUID().uuidString.prefix(4))"
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
        let outgoing = app.textViews.containing(NSPredicate(format: "value == %@", marker)).matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        // The echo peer answers within a second, so "Sent" may never be observable; the width is fixed from the first frame.
        let acceptedWidth = outgoing.frame.width
        // The peer sends its receipt and marker back to back, so "Delivered" may already have become "Read".
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Delivered' OR label CONTAINS 'Read'"), object: outgoing)], timeout: 25)
        XCTAssertEqual(outgoing.frame.width, acceptedWidth, accuracy: 1)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Read"), object: outgoing)], timeout: 25)
        XCTAssertEqual(outgoing.frame.width, acceptedWidth, accuracy: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Read receipt inside the bubble"; attachment.lifetime = .keepAlways; add(attachment)
        // The echo reply arrives after our receipt request; the states survive a relaunch because they are projected, not remembered.
        let echoed = app.textViews.containing(NSPredicate(format: "value == %@", marker)).matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", "You:")).firstMatch
        XCTAssertTrue(echoed.waitForExistence(timeout: 25))
        app.terminate(); app.launch()
        let chat = app.buttons["chat.\(peer)"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15)); chat.tap()
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        XCTAssertTrue(outgoing.label.contains("Read"))
    }
}
