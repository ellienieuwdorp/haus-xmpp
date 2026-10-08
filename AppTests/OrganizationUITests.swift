import XCTest

final class OrganizationUITests: XCTestCase {
    @MainActor func testPinStarAndFilter() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        let row = app.buttons["chat.alex@preview.local"]
        row.press(forDuration: 1)
        XCTAssertFalse(app.buttons["Pin"].exists, "Pin must not appear on long press")
        // A one-second press ends as a tap that pushes the chat; give the push time to land before popping.
        if app.buttons["BackButton"].waitForExistence(timeout: 2) { app.buttons["BackButton"].tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        // Every test starts from its own store, where no sample chat is pinned.
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 3))
        app.buttons["Pin"].tap()
        // The pin change lands after the swipe action has closed, so wait for it rather than asserting at once.
        XCTAssertTrue(waitForPinned(row), "Pin must mark the row pinned")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Centered pin and larger compose"
        capture.lifetime = .keepAlways
        add(capture)
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 3))
        let swipe = XCTAttachment(screenshot: app.screenshot())
        swipe.name = "Trailing pin action"
        swipe.lifetime = .keepAlways
        add(swipe)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        alex.tap()

        let marker = "Favorite \(UUID().uuidString.prefix(8))"
        let field = app.textFields["messageComposer"]
        let input = field.exists ? field : app.textViews["messageComposer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        let ordinary = "Ordinary \(UUID().uuidString.prefix(8))"
        input.typeText(ordinary)
        app.buttons["sendMessage"].tap()
        input.tap()
        input.typeText(marker)
        app.buttons["sendMessage"].tap()
        let message = app.textViews.containing(NSPredicate(format: "value == %@", marker)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        let star = app.buttons["Star message"]
        XCTAssertTrue(star.waitForExistence(timeout: 5), "Long-pressing message text must open bubble actions")
        star.tap()
        app.buttons["Conversation options"].tap()
        app.buttons["Starred messages"].tap()
        XCTAssertTrue(app.buttons["Show all"].waitForExistence(timeout: 3))
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("starred"))
        XCTAssertFalse(app.textViews.containing(NSPredicate(format: "value == %@", ordinary)).firstMatch.exists)
    }

    /// Waits for the row's "Pinned" value; the list applies a pin change a moment after the swipe action closes.
    @MainActor private func waitForPinned(_ row: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Pinned'"), object: row)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
