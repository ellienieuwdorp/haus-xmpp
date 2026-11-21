import XCTest

final class ConversationUITests: XCTestCase {
    @MainActor private func bubble(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.textViews.containing(NSPredicate(format: "value == %@", "History message \(index)")).firstMatch
    }

    @MainActor private func composer(in app: XCUIApplication) -> XCUIElement {
        // A multiline SwiftUI TextField is exposed as a text view on some runtimes.
        let field = app.textFields["messageComposer"]
        return field.exists ? field : app.textViews["messageComposer"]
    }

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
            var flings = 0
            while oldest() > 150, flings < 8 { timeline.swipeDown(velocity: 4000); flings += 1 }
            XCTAssertLessThanOrEqual(oldest(), 150, "An older page loads as the reader scrolls up")
        }

        XCTContext.runActivity(named: "Search reaches past the loaded pages") { _ in
            app.openConversationOptions()
            app.buttons["Search messages"].tap()
            let search = app.searchFields["messageSearch"]
            XCTAssertTrue(search.waitForExistence(timeout: 4))
            search.typeText("History message 12")
            // 12 and 120 through 129; message 12 is still outside every loaded page.
            XCTAssertTrue(app.staticTexts["11 messages found"].waitForExistence(timeout: 5))
        }
    }

    // On sample data: far up in history a button returns to the newest message, and the details open in a sheet over
    // the chat, with encryption pushed inside it.
    @MainActor func testJumpToNewestAndTheDetailsSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demo-long"]
        app.isolateMessageStorage()
        app.launch()
        let history = app.staticTexts["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        history.tap()
        let timeline = app.collectionViews["conversation.timeline"]
        let newest = bubble(250, in: app)
        XCTAssertTrue(newest.waitForExistence(timeout: 10))

        XCTContext.runActivity(named: "Far up in history a button returns to the newest message") { _ in
            let jump = app.buttons["jumpToNewest"]
            XCTAssertFalse(jump.exists, "a chat opens at its newest message")
            for _ in 0..<3 where !jump.exists { timeline.swipeDown(velocity: 4000) }
            XCTAssertTrue(jump.waitForExistence(timeout: 5))
            XCTAssertEqual(jump.label, "Scroll to Newest Message")
            XCTAssertGreaterThanOrEqual(jump.frame.width, 44)
            XCTAssertLessThan(jump.frame.maxY, composer(in: app).frame.minY, "above the composer")
            capture(app, "Jump to newest")
            jump.tap()
            XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
            XCTAssertTrue(newest.waitForExistence(timeout: 5))
            XCTAssertTrue(newest.isHittable)
        }

        let close = app.buttons["closeChatDetails"]
        XCTContext.runActivity(named: "The header opens the details as a sheet; encryption pushes inside it") { _ in
            app.buttons["chatDetails"].tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            capture(app, "Chat details sheet")
            app.buttons["encryptionDetails"].tap()
            let page = app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["Devices & Encryption", "Group details"])).firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 5))
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            XCTAssertTrue(composer(in: app).exists)
        }

        XCTContext.runActivity(named: "A swipe down closes the sheet") { _ in
            app.buttons["chatDetails"].tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        }

        XCTContext.runActivity(named: "Search in the details closes the sheet, then searches the chat") { _ in
            app.buttons["chatDetails"].tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search")).firstMatch.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.searchFields["messageSearch"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the field takes the keyboard once the sheet has gone")
        }
    }

    // One accessibility snapshot; querying each element's frame costs a round trip.
    @MainActor private func bubbleFrames(in timeline: XCUIElement) -> [(text: String, frame: CGRect)] {
        var found: [(text: String, frame: CGRect)] = []
        func walk(_ node: any XCUIElementSnapshot) {
            if node.elementType == .textView, let text = node.value as? String, text.hasPrefix("History message") { found.append((text, node.frame)) }
            node.children.forEach(walk)
        }
        if let root = try? timeline.snapshot() { walk(root) }
        return found
    }

    private struct Anchor: Equatable { let text: String; let gap: CGFloat }

    // Two readings half a second apart agree once scrolling, the keyboard and cell self-sizing are done.
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
