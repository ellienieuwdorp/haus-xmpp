import XCTest

/// `-demo-typing` leaves Alex typing: the list row says so in place of the preview, and the chat ends in a dots bubble.
final class TypingUITests: XCTestCase {
    @MainActor func testTypingShowsInTheListRowAndAtTheEndOfTheChat() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demo-typing"]
        app.isolateMessageStorage()
        app.launch()
        let row = app.buttons["chat.alex@preview.local"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.staticTexts["typing…"].exists)
        // The hidden preview keeps the row's height: Alex's row matches Maya's.
        XCTAssertEqual(row.frame.height, app.buttons["chat.maya@preview.local"].frame.height, accuracy: 1)
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "Typing row"; list.lifetime = .keepAlways; add(list)

        row.tap()
        let indicator = app.otherElements["typingIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        XCTAssertEqual(indicator.label, "Alex is typing…")
        // It sits below the newest message and above the composer.
        let newest = app.textViews.containing(NSPredicate(format: "value == %@", "Ten it is ☕️")).firstMatch
        XCTAssertTrue(newest.exists)
        XCTAssertGreaterThan(indicator.frame.minY, newest.frame.maxY)
        let composer = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertLessThan(indicator.frame.maxY, composer.frame.minY)
        let chat = XCTAttachment(screenshot: app.screenshot()); chat.name = "Typing bubble"; chat.lifetime = .keepAlways; add(chat)

        // Typing our own draft neither moves nor hides it.
        let frame = indicator.frame
        composer.tap(); composer.typeText("On my way")
        XCTAssertTrue(indicator.exists)
        let keyboard = XCTAttachment(screenshot: app.screenshot()); keyboard.name = "Typing bubble above the keyboard"; keyboard.lifetime = .keepAlways; add(keyboard)
        XCTAssertLessThan(indicator.frame.maxY, composer.frame.minY)
        XCTAssertEqual(indicator.frame.height, frame.height, accuracy: 1)
    }
}
