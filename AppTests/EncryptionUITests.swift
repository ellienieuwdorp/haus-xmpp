import XCTest

final class EncryptionUITests: XCTestCase {
    @MainActor func testReviewDevicesEncryptedRoundTripAndPersistentIdentity() throws {
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
        connect(app)
        app.returnToChats()
        app.buttons["newConversation"].tap()
        app.textFields["newChatAddress"].tap()
        app.textFields["newChatAddress"].typeText(peer)
        app.buttons["startChat"].tap()
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let marker = "Encrypted coffee ☕ \(UUID().uuidString.prefix(6))"
        input.tap(); input.typeText(marker)
        app.buttons["sendMessage"].tap()
        let bubbles = app.textViews.containing(NSPredicate(format: "value == %@", marker))
        XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(bubbles.firstMatch.label.contains("Waiting to send"))
        app.openEncryptionDetails()
        XCTAssertTrue(app.navigationBars["Devices & Encryption"].waitForExistence(timeout: 5))
        capture(app, "Encryption devices awaiting review")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "encryptionDevice."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        // Every acceptance is an explicit UI action against the displayed fixture fingerprint.
        for _ in 0..<20 {
            let pending = rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
            if !pending.exists { break }
            pending.tap()
            XCTAssertTrue(app.buttons["Accept without verifying"].waitForExistence(timeout: 5))
            capture(app, "Fingerprint review")
            app.buttons["Accept without verifying"].tap()
            XCTAssertTrue(app.navigationBars["Devices & Encryption"].waitForExistence(timeout: 5))
        }
        capture(app, "Accepted encryption devices")
        app.closeEncryptionDetails()
        let response = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: bubbles)
        wait(for: [response], timeout: 30)
        XCTAssertTrue(bubbles.allElementsBoundByIndex.contains { serverHeldLabel.evaluate(with: $0) || $0.label.contains("Delivery unconfirmed") })
        capture(app, "Encrypted independent peer round trip")
        app.terminate(); app.launch()
        let chat = app.buttons["chat.\(peer)"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        XCTAssertEqual(bubbles.count, 2)
        app.openEncryptionDetails()
        XCTAssertTrue(app.staticTexts["Accepted · not verified"].firstMatch.waitForExistence(timeout: 5))
        app.closeEncryptionDetails()
        app.navigationBars.buttons["BackButton"].tap()
        connect(app)
        app.returnToChats(); chat.tap()
        XCTAssertEqual(bubbles.count, 2)
        app.openEncryptionDetails()
        XCTAssertFalse(rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch.exists)
        app.closeEncryptionDetails()
    }

    @MainActor private func connect(_ app: XCUIApplication) {
        app.buttons["Settings"].tap(); app.buttons["Connect to local lab"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Connect"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected")).firstMatch.waitForExistence(timeout: 25))
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
