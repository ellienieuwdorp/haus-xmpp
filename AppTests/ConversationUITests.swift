import XCTest

final class ConversationUITests: XCTestCase {
    /// A chat with stored messages must never flash the empty placeholder while its list loads.
    @MainActor func testOpeningChatNeverShowsEmptyPlaceholder() throws {
        continueAfterFailure = false
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
        continueAfterFailure = false
        let app = openLongChat()
        XCTAssertTrue(bubble(250, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(bubble(250, in: app).isHittable, "A chat opens on its newest message, above the composer")
        let timeline = app.collectionViews["conversation.timeline"]
        // A hard fling coasts about three screens; `.fast` coasts one, and every fling waits for the list to come to rest.
        var flings = 0
        while !bubble(1, in: app).exists, flings < 20 { timeline.swipeDown(velocity: 4000); flings += 1 }
        XCTAssertTrue(bubble(1, in: app).exists, "Older pages load as the reader scrolls up")
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        // A multiline SwiftUI TextField is exposed as a text view on some runtimes.
        let field = app.textFields["messageComposer"]
        return field.exists ? field : app.textViews["messageComposer"]
    }

    /// The 250-message History chat in one launch. It opens on its newest message without flashing the empty notice.
    /// Reading history, the keyboard opening (twice, the second time after an interactive dismissal) and a growing draft
    /// leave the messages above the composer where they were. Scrolling up loads an older page, and search reaches
    /// past the loaded pages.
    @MainActor func testKeyboardKeepsTheHistoryAnchorThenPagesAndSearches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demo-long"]
        app.isolateMessageStorage()
        app.launch()
        let timeline = app.collectionViews["conversation.timeline"]

        XCTContext.runActivity(named: "Opening never shows the empty notice") { _ in
            let history = app.staticTexts["History"]
            XCTAssertTrue(history.waitForExistence(timeout: 15))
            history.tap()
            let newest = bubble(250, in: app), empty = app.staticTexts["No messages yet"]
            // Polled while the first page loads; a single negative wait would only sample once.
            let deadline = Date().addingTimeInterval(10)
            while !newest.exists, Date() < deadline {
                XCTAssertFalse(empty.exists, "A chat with stored messages must never flash the empty notice while it loads")
            }
            XCTAssertTrue(newest.exists)
            XCTAssertFalse(empty.exists)
            XCTAssertTrue(newest.isHittable, "A chat opens on its newest message, above the composer")
        }

        let input = composer(in: app)
        let moved = try XCTContext.runActivity(named: "The keyboard keeps the history anchor") { _ -> XCUIElement in
            // Slow drags that end at rest: no deceleration follows, so nothing re-records the position after cells self-size.
            for _ in 0..<4 {
                timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)), withVelocity: .slow, thenHoldForDuration: 0.3)
            }
            var moved = input
            // Twice: the second opening follows an interactive dismissal, which leaves the list wherever the finger put it.
            for round in 1...2 {
                // Measure once the drag and any cell self-sizing have settled.
                let anchor = try XCTUnwrap(settled { () -> Anchor? in
                    let top = input.frame.minY
                    return bubbleFrames(in: timeline).filter { $0.frame.maxY < top - 11 }.max { $0.frame.maxY < $1.frame.maxY }
                        .map { Anchor(text: $0.text, gap: top - $0.frame.maxY) }
                }, "round \(round)")
                app.showKeyboard(tapping: input)
                moved = app.textViews.containing(NSPredicate(format: "value == %@", anchor.text)).firstMatch
                XCTAssertTrue(moved.exists, "round \(round)")
                XCTAssertEqual(settled { input.frame.minY - moved.frame.maxY }, anchor.gap, accuracy: 4, "round \(round)")
                guard round == 1 else { break }
                timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)), withVelocity: .slow, thenHoldForDuration: 0.3)
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            }
            return moved
        }

        XCTContext.runActivity(named: "A long draft grows the composer upward over the same messages") { _ in
            let oneLine = input.frame.height
            let gap = settled { input.frame.minY - moved.frame.maxY }
            input.typeText(String(repeating: "wrapping words ", count: 8))
            XCTAssertGreaterThan(input.frame.height, oneLine * 1.8)
            XCTAssertTrue(app.buttons["sendMessage"].isHittable, "Send stays above the keyboard")
            XCTAssertEqual(settled { input.frame.minY - moved.frame.maxY }, gap, accuracy: 4, "The message above the composer stays above it")
        }

        XCTContext.runActivity(named: "Scrolling up loads an older page") { _ in
            // The newest page is messages 151 to 250. Every page arrives through the same reach-top path, so one proves it.
            @MainActor func oldest() -> Int {
                bubbleFrames(in: timeline).compactMap { Int($0.text.dropFirst("History message ".count).prefix(while: \.isNumber)) }.min() ?? .max
            }
            // A hard fling coasts about three screens; every fling waits for the list to come to rest.
            var flings = 0
            while oldest() > 150, flings < 8 { timeline.swipeDown(velocity: 4000); flings += 1 }
            XCTAssertLessThanOrEqual(oldest(), 150, "An older page loads as the reader scrolls up")
        }

        XCTContext.runActivity(named: "Search reaches past the loaded pages") { _ in
            app.buttons["Conversation options"].tap()
            app.buttons["Search messages"].tap()
            let search = app.searchFields["messageSearch"]
            XCTAssertTrue(search.waitForExistence(timeout: 4))
            search.typeText("History message 12")
            // 12 and 120 through 129; message 12 is still outside every loaded page.
            XCTAssertTrue(app.staticTexts["11 messages found"].waitForExistence(timeout: 5))
        }
    }

    /// Every visible history bubble from one accessibility snapshot; querying each element's frame costs a round trip.
    @MainActor private func bubbleFrames(in timeline: XCUIElement) -> [(text: String, frame: CGRect)] {
        var found: [(text: String, frame: CGRect)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .textView, let text = node.value as? String, text.hasPrefix("History message") { found.append((text, node.frame)) }
            node.children.forEach(walk)
        }
        if let root = try? timeline.snapshot() { walk(root) }
        return found
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

}
