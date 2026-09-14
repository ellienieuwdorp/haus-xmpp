import XCTest

final class OrganizationUITests: XCTestCase {
    @MainActor func testPinStarFilterAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        let row = app.buttons["chat.alex@preview.local"]
        row.press(forDuration: 1)
        XCTAssertFalse(app.buttons["Pin"].exists, "Pin must not appear on long press")
        if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
        row.swipeLeft()
        if app.buttons["Unpin"].waitForExistence(timeout: 1) {
            app.buttons["Unpin"].tap()
            row.swipeLeft()
        }
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 3))
        app.buttons["Pin"].tap()
        XCTAssertEqual(row.value as? String, "Pinned")
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

        app.terminate()
        app.launch()
        XCTAssertTrue(alex.waitForExistence(timeout: 10))
        XCTAssertEqual(row.value as? String, "Pinned", "Pin must survive process restart")
        alex.tap()
        app.buttons["Conversation options"].tap()
        app.buttons["Starred messages"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Star must survive process restart")
        XCTAssertTrue(message.label.contains("starred"))
    }
}
