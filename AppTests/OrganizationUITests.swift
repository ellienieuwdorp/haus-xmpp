import XCTest

final class OrganizationUITests: XCTestCase {
    @MainActor func testPinStarFilterAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        alex.press(forDuration: 1)
        // Preserve repeatability when a preceding run left the conversation pinned.
        if app.buttons["Unpin chat"].waitForExistence(timeout: 2) {
            app.buttons["Unpin chat"].tap()
            alex.press(forDuration: 1)
        }
        let pin = app.buttons["Pin chat"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.tap()
        alex.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Unpin chat"].waitForExistence(timeout: 3))
        // Dismiss the context menu by tapping outside its preview and actions.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
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
        message.press(forDuration: 1)
        let star = app.buttons["Star message"]
        XCTAssertTrue(star.waitForExistence(timeout: 5), "Starring must remain reachable while text is selectable")
        star.tap()
        app.buttons["Conversation options"].tap()
        app.buttons["Starred messages"].tap()
        XCTAssertTrue(app.buttons["Show all"].waitForExistence(timeout: 3))
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("starred"))
        XCTAssertFalse(app.textViews.containing(NSPredicate(format: "value == %@", ordinary)).firstMatch.exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(alex.waitForExistence(timeout: 10))
        alex.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Unpin chat"].waitForExistence(timeout: 3), "Pin must survive process restart")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        alex.tap()
        app.buttons["Conversation options"].tap()
        app.buttons["Starred messages"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Star must survive process restart")
        XCTAssertTrue(message.label.contains("starred"))
    }
}
