import XCTest

final class OrganizationUITests: XCTestCase {
    @MainActor func testStarAndFilter() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
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
}
