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

    private func openLongChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demo-long"]
        app.isolateMessageStorage()
        app.launch()
        let history = app.staticTexts["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        history.tap()
        return app
    }

    private func bubble(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.textViews.containing(NSPredicate(format: "value == %@", "History message \(index)")).firstMatch
    }

    /// Only the newest page is loaded on open; scrolling up pages the rest in until the first message is reachable.
    @MainActor func testLongChatOpensAtNewestAndPagesBackToTheFirstMessage() throws {
        let app = openLongChat()
        XCTAssertTrue(bubble(250, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(bubble(250, in: app).isHittable, "A chat opens on its newest message, above the composer")
        let timeline = app.collectionViews["conversation.timeline"]
        for _ in 0..<60 where !bubble(1, in: app).exists { timeline.swipeDown(velocity: .fast) }
        XCTAssertTrue(bubble(1, in: app).exists, "Older pages load as the reader scrolls up")
    }

    /// Search covers messages older than the newest page.
    @MainActor func testSearchReachesBeyondTheNewestPage() throws {
        let app = openLongChat()
        XCTAssertTrue(bubble(250, in: app).waitForExistence(timeout: 5))
        app.buttons["Conversation options"].tap()
        app.buttons["Search messages"].tap()
        let search = app.searchFields["messageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.typeText("History message 12")
        // 12 and 120 through 129, all outside the newest hundred.
        XCTAssertTrue(app.staticTexts["11 messages found"].waitForExistence(timeout: 5))
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        // A multiline SwiftUI TextField is exposed as a text view on some runtimes.
        let field = app.textFields["messageComposer"]
        return field.exists ? field : app.textViews["messageComposer"]
    }

    /// A long draft wraps and the composer grows upward: send stays above the keyboard, the newest message above the composer.
    @MainActor func testLongDraftGrowsTheComposer() throws {
        let app = openLongChat()
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        let oneLine = input.frame.height
        input.typeText(String(repeating: "wrapping words ", count: 8))
        XCTAssertGreaterThan(input.frame.height, oneLine * 1.8)
        XCTAssertTrue(app.buttons["sendMessage"].isHittable)
        XCTAssertTrue(bubble(250, in: app).isHittable)
    }

    /// Sending always returns to the newest message, even from far up in history.
    @MainActor func testSendingFromHistoryReturnsToTheNewestMessage() throws {
        let app = openLongChat()
        XCTAssertTrue(bubble(250, in: app).waitForExistence(timeout: 5))
        let timeline = app.collectionViews["conversation.timeline"]
        for _ in 0..<3 { timeline.swipeDown(velocity: .fast) }
        XCTAssertFalse(bubble(250, in: app).isHittable)
        let input = composer(in: app)
        input.tap()
        input.typeText("Back to the bottom")
        app.buttons["sendMessage"].tap()
        let sent = app.textViews.containing(NSPredicate(format: "value == %@", "Back to the bottom")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertTrue(sent.isHittable)
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
