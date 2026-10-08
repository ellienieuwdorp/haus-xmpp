import XCTest

final class PolishUITests: XCTestCase {
    @MainActor func testBubbleOnlyMenuAndCompactCompose() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let compose = app.buttons["newConversation"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["New conversation"].exists)
        XCTAssertLessThanOrEqual(compose.frame.width, 68)
        // A native bottom-bar item reports its glyph frame (36pt); its glass hit area is the full 44pt+ bar height.
        XCTAssertGreaterThanOrEqual(compose.frame.height, 36)
        capture(app, "Centered compose control")
        app.staticTexts["Alex"].tap()
        // The attach button is part of the first composer frame; it never waits for a connection.
        XCTAssertTrue(app.buttons["attachFile"].waitForExistence(timeout: 1))
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        input.tap()
        let marker = "A small detail \(UUID().uuidString.prefix(4))"
        input.typeText(marker)
        let send = app.buttons["sendMessage"]
        let enabledFrame = send.frame
        XCTAssertGreaterThanOrEqual(enabledFrame.width, 44)
        XCTAssertGreaterThanOrEqual(enabledFrame.height, 44)
        capture(app, "Centered send enabled")
        send.tap()
        let message = app.textViews.containing(NSPredicate(format: "value == %@", marker)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(send.frame, enabledFrame)
        XCTAssertFalse(send.isEnabled)
        capture(app, "Centered send disabled after sending")
        let widthBefore = message.frame.width
        // The opposite side of an outgoing bubble is not a message interaction target.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: message.frame.midY)).press(forDuration: 1)
        XCTAssertFalse(app.buttons["Star message"].exists)
        // The message body opens the same bubble-only actions as its footer.
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Star message"].waitForExistence(timeout: 5))
        // Sample messages cannot be reacted to: the row stays visible, disabled, with the reason under it.
        XCTAssertTrue(app.staticTexts["reactionUnavailableReason"].exists)
        XCTAssertTrue(app.buttons["👍"].exists)
        XCTAssertFalse(app.buttons["👍"].isEnabled)
        capture(app, "Message actions overlay")
        app.buttons["Star message"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.frame.width, widthBefore, accuracy: 1)
        XCTAssertTrue(message.label.contains("starred"))
        capture(app, "Star inside bubble footer")
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select text"].waitForExistence(timeout: 5))
        app.buttons["Select text"].tap()
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5) || app.buttons["Copy"].exists)
        capture(app, "Explicit native text selection")
    }
}
