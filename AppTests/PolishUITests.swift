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
        let composeCapture = XCTAttachment(screenshot: app.screenshot())
        composeCapture.name = "Centered compose control"
        composeCapture.lifetime = .keepAlways
        add(composeCapture)
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
        let enabled = XCTAttachment(screenshot: app.screenshot())
        enabled.name = "Centered send enabled"
        enabled.lifetime = .keepAlways
        add(enabled)
        send.tap()
        let message = app.textViews.containing(NSPredicate(format: "value == %@", marker)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(send.frame, enabledFrame)
        XCTAssertFalse(send.isEnabled)
        let disabled = XCTAttachment(screenshot: app.screenshot())
        disabled.name = "Centered send disabled after sending"
        disabled.lifetime = .keepAlways
        add(disabled)
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
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Message actions overlay"
        preview.lifetime = .keepAlways
        add(preview)
        app.buttons["Star message"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.frame.width, widthBefore, accuracy: 1)
        XCTAssertTrue(message.label.contains("starred"))
        let starred = XCTAttachment(screenshot: app.screenshot())
        starred.name = "Star inside bubble footer"
        starred.lifetime = .keepAlways
        add(starred)
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select text"].waitForExistence(timeout: 5))
        app.buttons["Select text"].tap()
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5) || app.buttons["Copy"].exists)
        let selection = XCTAttachment(screenshot: app.screenshot())
        selection.name = "Explicit native text selection"
        selection.lifetime = .keepAlways
        add(selection)
    }
}
