import XCTest

/// Unsend and edit on an own message, driven through the long-press overlay on sample data.
final class RevisionUITests: XCTestCase {
    @MainActor func testEditThenUnsendOwnMessage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        alex.tap()
        let original = "That sounds perfect. Around ten?"
        let outgoing = app.textViews.containing(NSPredicate(format: "value == %@", original)).matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        let originalWidth = outgoing.frame.width

        // Edit: the composer takes the text, the send circle becomes a save tick, the bubble updates in place.
        outgoing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.staticTexts["Editing message"].waitForExistence(timeout: 5))
        let composer = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, original)
        let save = app.buttons["sendMessage"]
        XCTAssertFalse(save.isEnabled, "an unchanged text has nothing to save")
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        composer.typeText(" Sharp.")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let edited = app.textViews.containing(NSPredicate(format: "value == %@", original + " Sharp.")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10))
        XCTAssertTrue(edited.label.contains("edited"))
        XCTAssertFalse(app.staticTexts["Editing message"].exists)
        XCTAssertFalse(app.textViews.containing(NSPredicate(format: "value == %@", original)).firstMatch.exists, "an edit never adds a bubble")
        capture(app, "Edited bubble")

        // Unsend: confirmation first, then a quiet placeholder with no reaction row and no text actions.
        edited.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        let unsend = app.buttons["Unsend"]
        XCTAssertTrue(unsend.waitForExistence(timeout: 5))
        unsend.tap()
        let confirm = app.sheets.buttons["Unsend"].exists ? app.sheets.buttons["Unsend"] : app.buttons["Unsend"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let placeholder = app.textViews.containing(NSPredicate(format: "value == %@", "You unsent a message")).firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(placeholder.frame.width, max(originalWidth, 240) + 1)
        capture(app, "Unsent bubble")
        placeholder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Star message"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit"].exists)
        XCTAssertFalse(app.buttons["Copy"].exists)
        app.buttons["Dismiss"].firstMatch.tap()
    }

    /// The lab echo peer corrects its echo of a "#edit" message and retracts its echo of a "#unsend"
    /// message, so the inbound half is exercised against real OMEMO traffic.
    @MainActor func testPeerEditsAndUnsendsApplyToTheOriginalBubble() throws {
        continueAfterFailure = false
        let lab = try LabFixture(orSkip: "Requires the lab echo peer")
        let app = lab.launch()
        app.connectToLab()
        let composer = app.startChat(with: lab.peer)
        // The keyboard stays down until the devices are reviewed: returning from a pushed page with it
        // raised can leave the composer behind the keyboard (known layout bug, outside this test).
        app.openEncryptionDetails()
        // The echo peer speaks OMEMO 2 only.
        app.selectModernOMEMO()
        app.acceptPendingDevices()
        app.closeEncryptionDetails()

        // Peer edit: the echo arrives, then its correction rewrites that same bubble.
        let marker = "Draft \(UUID().uuidString.prefix(4))"
        composer.tap(); composer.typeText(marker + " #edit"); app.buttons["sendMessage"].tap()
        let echo = app.textViews.containing(NSPredicate(format: "value == %@", marker + " #edit")).matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", "You:")).firstMatch
        // The correction follows the echo within milliseconds, so the uncorrected text may never be on screen.
        let corrected = app.textViews.containing(NSPredicate(format: "value == %@", marker + " (edited by peer)")).firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 30))
        XCTAssertTrue(corrected.label.contains("edited"))
        XCTAssertFalse(echo.exists, "the correction replaced the echo instead of adding a bubble")
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "label CONTAINS %@", marker)).count, 2, "our message and the peer's edited echo")
        capture(app, "Peer edit applied in place")

        // Peer unsend: the echo becomes the placeholder.
        let second = "Gone \(UUID().uuidString.prefix(4))"
        composer.tap(); composer.typeText(second + " #unsend"); app.buttons["sendMessage"].tap()
        let unsentEcho = app.textViews.containing(NSPredicate(format: "value == %@", "Message unsent")).firstMatch
        XCTAssertTrue(unsentEcho.waitForExistence(timeout: 40))
        XCTAssertFalse(app.textViews.containing(NSPredicate(format: "value == %@", second + " #unsend")).matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", "You:")).firstMatch.exists)
        capture(app, "Peer unsend applied in place")

        // Our own edit and unsend round-trip through the outbox and reach server acceptance.
        let mine = app.textViews.containing(NSPredicate(format: "value == %@", second + " #unsend")).matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5)); app.buttons["Edit"].tap()
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap(); composer.typeText(" more"); app.buttons["sendMessage"].tap()
        let edited = app.textViews.containing(NSPredicate(format: "value == %@", second + " #unsend more")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "edited"), object: edited)], timeout: 10)
        edited.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Unsend"].waitForExistence(timeout: 5)); app.buttons["Unsend"].tap()
        let confirm = app.sheets.buttons["Unsend"].exists ? app.sheets.buttons["Unsend"] : app.buttons["Unsend"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value == %@", "You unsent a message")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "Own edit and unsend in the lab")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
