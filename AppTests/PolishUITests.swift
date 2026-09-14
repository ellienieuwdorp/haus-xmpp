import XCTest

final class PolishUITests: XCTestCase {
    @MainActor func testBubbleOnlyMenuAndCompactCompose() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        let compose = app.buttons["newConversation"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["New conversation"].exists)
        XCTAssertLessThanOrEqual(compose.frame.width, 68)
        XCTAssertGreaterThanOrEqual(compose.frame.height, 44)
        let composeCapture = XCTAttachment(screenshot: app.screenshot())
        composeCapture.name = "Centered compose control"
        composeCapture.lifetime = .keepAlways
        add(composeCapture)
        app.staticTexts["Alex"].tap()
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
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Bubble-only context preview"
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
    @MainActor func testLargeTextConversationLayout() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Notes to self"].waitForExistence(timeout: 15))
        app.staticTexts["Notes to self"].tap()
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        input.tap()
        input.typeText("A quieter conversation.")
        XCTAssertTrue(app.buttons["sendMessage"].isHittable)
        app.buttons["sendMessage"].tap()
        let message = app.textViews.containing(NSPredicate(format: "value == %@", "A quieter conversation.")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(message.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(message.frame.minX, app.frame.minX)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Large text conversation"
        capture.lifetime = .keepAlways
        add(capture)
    }

}
