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

    /// Reading history, the keyboard opening must not slide messages under the composer: the bubble resting just
    /// above it keeps its distance.
    @MainActor func testKeyboardKeepsTheHistoryAnchor() throws {
        let app = openLongChat()
        XCTAssertTrue(bubble(250, in: app).waitForExistence(timeout: 5))
        let timeline = app.collectionViews["conversation.timeline"]
        // Slow drags that end at rest: no deceleration follows, so nothing re-records the position after cells self-size.
        for _ in 0..<4 {
            timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let input = composer(in: app)
        let bubbles = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "History message"))
        // Twice: the second opening follows an interactive dismissal, which leaves the list wherever the finger put it.
        for round in 1...2 {
            // Measure once the drag and any cell self-sizing have settled.
            let anchor = try XCTUnwrap(settled { () -> Anchor? in
                bubbles.allElementsBoundByIndex.filter { $0.frame.maxY < input.frame.minY - 11 }.max { $0.frame.maxY < $1.frame.maxY }
                    .map { Anchor(text: $0.value as? String ?? "", gap: input.frame.minY - $0.frame.maxY) }
            }, "round \(round)")
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let moved = app.textViews.containing(NSPredicate(format: "value == %@", anchor.text)).firstMatch
            XCTAssertTrue(moved.exists, "round \(round)")
            XCTAssertEqual(settled { input.frame.minY - moved.frame.maxY }, anchor.gap, accuracy: 4, "round \(round)")
            guard round == 1 else { break }
            timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)), withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
    }

    /// The bubble resting just above the composer and its distance from it.
    private struct Anchor: Equatable { let text: String; let gap: CGFloat }

    /// Polls `probe` until two readings half a second apart agree: scrolling, the keyboard and cell self-sizing are done.
    @MainActor private func settled<T: Equatable>(timeout: TimeInterval = 10, _ probe: () -> T) -> T {
        var last = probe()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            let next = probe()
            if next == last { return next }
            last = next
        }
        XCTFail("Still moving after \(timeout) seconds")
        return last
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

}
