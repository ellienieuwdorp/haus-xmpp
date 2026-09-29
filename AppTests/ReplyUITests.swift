import XCTest

final class ReplyUITests: XCTestCase {
    @MainActor func testSwipeReplyCancelSearchAndKeepTheDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        XCTAssertTrue(app.buttons["newConversation"].waitForExistence(timeout: 15))
        app.buttons["newConversation"].tap()
        let address = "reply-\(UUID().uuidString.prefix(6))@preview.local"
        app.textFields["newChatAddress"].tap()
        app.textFields["newChatAddress"].typeText(address)
        app.buttons["startChat"].tap()
        let input = app.textFields["messageComposer"].waitForExistence(timeout: 3) ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        let original = "Coffee by the water tomorrow?"
        input.typeText(original)
        app.buttons["sendMessage"].tap()
        let message = app.textViews.containing(NSPredicate(format: "value == %@", original)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let start = message.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 18, dy: 0)))
        XCTAssertFalse(app.buttons["cancelReply"].exists, "Small drags must not trigger reply")
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 95, dy: 0)))
        XCTAssertTrue(app.buttons["cancelReply"].waitForExistence(timeout: 4))
        capture(app, "Reply composer")
        app.buttons["cancelReply"].tap()
        XCTAssertFalse(app.buttons["cancelReply"].exists)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 95, dy: 0)))
        XCTAssertTrue(app.buttons["cancelReply"].waitForExistence(timeout: 4))
        input.tap()
        let answer = "Ten sounds good."
        input.typeText(answer)
        app.buttons["sendMessage"].tap()
        let reply = app.textViews.containing(NSPredicate(format: "value == %@", answer)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 4))
        XCTAssertTrue(reply.label.contains("Replying to you: \(original)"))
        XCTAssertFalse(app.buttons["cancelReply"].exists)
        capture(app, "Sent reply bubble")
        input.tap()
        input.typeText("Unsent note")
        app.buttons["Conversation options"].tap()
        app.buttons["Search messages"].tap()
        let search = app.searchFields["messageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.typeText("Ten")
        XCTAssertTrue(reply.waitForExistence(timeout: 3))
        XCTAssertFalse(message.exists)
        XCTAssertFalse(app.buttons["sendMessage"].exists)
        capture(app, "Conversation search results")
        let closeSearch = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Cancel"]
        closeSearch.tap()
        XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "Unsent note")
        // Leading-edge navigation remains distinct from a message-content reply swipe.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(app.buttons["newConversation"].waitForExistence(timeout: 5))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
