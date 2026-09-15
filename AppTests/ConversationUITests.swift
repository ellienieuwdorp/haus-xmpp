import XCTest

final class ConversationUITests: XCTestCase {
    /// A chat with stored messages must never flash the empty placeholder while its list loads.
    @MainActor func testOpeningChatNeverShowsEmptyPlaceholder() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        alex.tap()
        XCTAssertFalse(app.staticTexts["No messages yet"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["messageComposer"].exists || app.textViews["messageComposer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No messages yet"].exists)
    }

    @MainActor func testComposeSearchAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        alex.tap()
        let composer = app.textFields["messageComposer"]
        // A multiline SwiftUI TextField is exposed as a text view on some runtimes.
        let input = composer.exists ? composer : app.textViews["messageComposer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        let marker = "Smoke \(UUID().uuidString.prefix(8))"
        input.typeText(marker)
        let send = app.buttons["sendMessage"]
        XCTAssertTrue(send.isHittable, "Composer send should stay above keyboard")
        send.tap()
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Conversation with keyboard"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["Conversation options"].tap()
        app.buttons["Search messages"].tap()
        let search = app.searchFields["messageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText(marker)
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value == %@", marker)).firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Alex"].waitForExistence(timeout: 10))
        app.staticTexts["Alex"].tap()
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value == %@", marker)).firstMatch.waitForExistence(timeout: 5))
    }
}
