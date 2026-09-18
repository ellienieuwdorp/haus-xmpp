import XCTest

final class ReactionUITests: XCTestCase {
    @MainActor func testEncryptedReactionSelectionRemovalAndPersistentAccessibleSummary() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let user = env["XMPP_LAB_USERNAME"], let password = env["XMPP_LAB_PASSWORD"], let peer = env["XMPP_OMEMO_PEER"] else {
            throw XCTSkip("Requires disposable modern OMEMO peer")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["XMPP_LAB_USERNAME": user, "XMPP_LAB_PASSWORD": password]
        app.isolateMessageStorage()
        app.launch()
        app.buttons["Settings"].tap(); app.buttons["Connect to local lab"].tap()
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
        let marker = "A thoughtful detail \(UUID().uuidString.prefix(4))"
        composer.tap(); composer.typeText(marker); app.buttons["sendMessage"].tap()
        app.openEncryptionDetails()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "encryptionDevice."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        let version = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "OMEMO · compatible")).firstMatch
        for _ in 0..<5 { if version.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(version.isHittable); version.tap()
        XCTAssertTrue(app.buttons["OMEMO 2"].waitForExistence(timeout: 5)); app.buttons["OMEMO 2"].tap()
        for _ in 0..<5 { if rows.firstMatch.isHittable { break }; app.swipeDown() }
        for _ in 0..<20 {
            let pending = rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
            if !pending.exists { break }
            pending.tap()
            XCTAssertTrue(app.buttons["Accept without verifying"].waitForExistence(timeout: 5))
            app.buttons["Accept without verifying"].tap()
            XCTAssertTrue(app.navigationBars["Devices & Encryption"].waitForExistence(timeout: 5))
        }
        app.closeEncryptionDetails()
        let outgoing = app.textViews.containing(NSPredicate(format: "value == %@", marker)).matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        wait(for: [XCTNSPredicateExpectation(predicate: serverHeldLabel, object: outgoing)], timeout: 25)
        let originalWidth = outgoing.frame.width
        openReactions(app, message: outgoing)
        capture(app, "Encrypted reaction menu")
        XCTAssertTrue(app.buttons["👍"].waitForExistence(timeout: 5)); app.buttons["👍"].tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "2 thumbs up reactions, including you"), object: outgoing)], timeout: 10)
        XCTAssertEqual(outgoing.frame.width, originalWidth, accuracy: 1)
        capture(app, "Reaction summary inside bubble")
        openReactions(app, message: outgoing)
        capture(app, "Selected reaction in native menu")
        app.buttons["👍"].tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (label CONTAINS %@)", "thumbs up reaction"), object: outgoing)], timeout: 10)
        XCTAssertEqual(outgoing.frame.width, originalWidth, accuracy: 1)
        openReactions(app, message: outgoing)
        app.buttons["❤️"].tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "2 heart reactions, including you"), object: outgoing)], timeout: 10)
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        let chat = app.buttons["chat.\(peer)"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15)); chat.tap()
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        XCTAssertTrue(outgoing.label.contains("2 heart reactions, including you"))
        XCTAssertGreaterThanOrEqual(outgoing.frame.minX, 0)
        XCTAssertLessThanOrEqual(outgoing.frame.maxX, app.frame.maxX)
        capture(app, "Persistent reaction at accessibility text size")
    }

    /// Long-pressing a bubble opens the actions overlay with the quick-reaction row above it.
    @MainActor private func openReactions(_ app: XCUIApplication, message: XCUIElement) {
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
