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

        // The projection survives a relaunch and the chat list preview follows it.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Alex"].waitForExistence(timeout: 10))
        app.staticTexts["Alex"].tap()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
