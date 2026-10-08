import XCTest

final class ReplyUITests: XCTestCase {
    /// A rightward swipe on a message row replies, from the bubble or the empty gutter beside a short sent message, and
    /// keeps the keyboard up. A day header is not a message: from there, as from the leading edge, the swipe goes back.
    @MainActor func testReplySwipesKeepTheKeyboardAndLeaveBackToTheSystem() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        alex.tap()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let cancelReply = app.buttons["cancelReply"]

        XCTContext.runActivity(named: "A day header gives the swipe back") { _ in
            let first = app.textViews.containing(NSPredicate(format: "value BEGINSWITH %@", "Found a quiet spot")).firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            // The day header sits just above the first bubble, in the same cell. The demo messages are all sent on one day.
            let day = Date(timeIntervalSince1970: 1_789_380_000).formatted(date: .abbreviated, time: .omitted)
            let dayHeader = app.staticTexts.matching(NSPredicate(format: "label == %@", day)).firstMatch
            XCTAssertTrue(dayHeader.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(dayHeader.frame.maxY, first.frame.minY, "the day header is above the first bubble")
            // Past half the width, so the back swipe completes at XCTest's drag speed.
            let header = origin.withOffset(CGVector(dx: app.frame.width * 0.15, dy: dayHeader.frame.midY))
            header.press(forDuration: 0.05, thenDragTo: header.withOffset(CGVector(dx: app.frame.width * 0.75, dy: 0)))
            XCTAssertTrue(app.buttons["newConversation"].waitForExistence(timeout: 5), "a day header gives the swipe back")
            XCTAssertFalse(cancelReply.exists)
            alex.tap()
        }

        XCTContext.runActivity(named: "Swiping a received photo quotes it as Photo") { _ in
            let timeline = app.collectionViews["conversation.timeline"]
            XCTAssertTrue(timeline.cells.containing(.image, identifier: nil).firstMatch.waitForExistence(timeout: 5))
            let photo = timeline.cells.containing(.image, identifier: nil).allElementsBoundByIndex
                .first { cell in cell.images.allElementsBoundByIndex.contains { $0.frame.height > 60 } }
            guard let photo else { return XCTFail("Alex's sample photo") }
            let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 110, dy: 0)))
            XCTAssertTrue(cancelReply.waitForExistence(timeout: 4))
            XCTAssertTrue(app.staticTexts["Photo"].exists, "The strip quotes the photo by kind")
            capture(app, "Replying to a photo")
            cancelReply.tap()
            XCTAssertTrue(cancelReply.waitForNonExistence(timeout: 2))
        }

        let short = app.textViews.containing(NSPredicate(format: "value == %@", "See you there!")).firstMatch
        let field = app.textFields["messageComposer"]
        let composer = field.exists ? field : app.textViews["messageComposer"]
        let answer = "Ten sounds good."
        let reply = app.textViews.containing(NSPredicate(format: "value == %@", answer)).firstMatch

        XCTContext.runActivity(named: "A gutter swipe replies and keeps the keyboard; a small drag does not") { _ in
            XCTAssertTrue(short.waitForExistence(timeout: 5))
            app.showKeyboard(tapping: composer)
            XCTAssertGreaterThan(short.frame.minX, app.frame.width / 2, "a short sent message sits on the trailing half")
            let gutter = origin.withOffset(CGVector(dx: app.frame.width * 0.25, dy: short.frame.midY))
            gutter.press(forDuration: 0.05, thenDragTo: gutter.withOffset(CGVector(dx: 18, dy: 0)))
            XCTAssertFalse(cancelReply.exists, "Small drags must not trigger reply")
            gutter.press(forDuration: 0.05, thenDragTo: gutter.withOffset(CGVector(dx: 130, dy: 0)))
            XCTAssertTrue(cancelReply.waitForExistence(timeout: 4), "a swipe in the gutter replies")
            XCTAssertTrue(app.keyboards.firstMatch.exists, "the reply swipe keeps the keyboard up")
            capture(app, "Reply from the gutter")
            cancelReply.tap()
            XCTAssertTrue(cancelReply.waitForNonExistence(timeout: 2))
        }

        XCTContext.runActivity(named: "The sent reply quotes the message and the strip clears") { _ in
            let gutter = origin.withOffset(CGVector(dx: app.frame.width * 0.25, dy: short.frame.midY))
            gutter.press(forDuration: 0.05, thenDragTo: gutter.withOffset(CGVector(dx: 130, dy: 0)))
            XCTAssertTrue(cancelReply.waitForExistence(timeout: 4))
            composer.tap()
            composer.typeText(answer)
            app.buttons["sendMessage"].tap()
            XCTAssertTrue(reply.waitForExistence(timeout: 5))
            XCTAssertTrue(reply.label.contains("Replying to you: See you there!"), reply.label)
            XCTAssertFalse(cancelReply.exists)
            capture(app, "Sent reply bubble")
        }

        XCTContext.runActivity(named: "Search hides the composer and the draft survives it") { _ in
            composer.tap()
            composer.typeText("Unsent note")
            app.buttons["Conversation options"].tap()
            app.buttons["Search messages"].tap()
            let search = app.searchFields["messageSearch"]
            XCTAssertTrue(search.waitForExistence(timeout: 4))
            search.typeText("sounds good")
            XCTAssertTrue(reply.waitForExistence(timeout: 3))
            XCTAssertFalse(short.exists)
            XCTAssertFalse(app.buttons["sendMessage"].exists)
            capture(app, "Conversation search results")
            let closeSearch = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Cancel"]
            closeSearch.tap()
            XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 3))
            XCTAssertEqual(composer.value as? String, "Unsent note")
        }

        XCTContext.runActivity(named: "The leading edge stays the system's swipe back, on a message row too") { _ in
            XCTAssertTrue(short.waitForExistence(timeout: 3))
            let edge = origin.withOffset(CGVector(dx: 2, dy: short.frame.midY))
            edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: app.frame.width * 0.8, dy: 0)))
            XCTAssertTrue(app.buttons["newConversation"].waitForExistence(timeout: 5))
            XCTAssertFalse(cancelReply.exists)
        }
    }
}
