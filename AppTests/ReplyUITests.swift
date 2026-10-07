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

    /// Alex's sample photo has no caption. Replying quotes it as "Photo" (with a still) instead of failing on an empty
    /// quote; files sent with no caption carry a reply to an own message, and leave a reply to a received one in the composer.
    @MainActor func testReplyToAPhotoQuotesItAndFilesAloneCarryAReplyToAnOwnMessage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        XCTAssertTrue(app.staticTexts["Alex"].waitForExistence(timeout: 15))
        app.staticTexts["Alex"].tap()
        let timeline = app.collectionViews["conversation.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(timeline.cells.containing(.image, identifier: nil).firstMatch.waitForExistence(timeout: 5))
        let photo = timeline.cells.containing(.image, identifier: nil).allElementsBoundByIndex
            .first { cell in cell.images.allElementsBoundByIndex.contains { $0.frame.height > 60 } }
        let photoCell = try XCTUnwrap(photo, "Alex's sample photo")
        let start = photoCell.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 110, dy: 0)))
        XCTAssertTrue(app.buttons["cancelReply"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Photo"].exists, "The strip quotes the photo by kind")
        capture(app, "Replying to a photo")

        // Files alone cannot quote a received message (the body must stay the link): the reply waits for a caption,
        // and the field says so before Send.
        pickRailPhoto(in: app)
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertEqual(input.placeholderValue, "Add a caption to reply…")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["removeAttachment"].waitForNonExistence(timeout: 10), "The file is sent")
        XCTAssertTrue(app.buttons["cancelReply"].exists, "The reply stays for a caption")

        input.tap()
        let answer = "Love this view \(UUID().uuidString.prefix(4))"
        input.typeText(answer)
        app.buttons["sendMessage"].tap()
        let reply = app.textViews.containing(NSPredicate(format: "value == %@", answer)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "The reply is sent, not refused")
        XCTAssertTrue(reply.label.contains("Replying to Alex: Photo"))
        XCTAssertFalse(app.buttons["cancelReply"].exists)

        // An own message: the first file carries the reply, and the strip clears.
        let ownStart = reply.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        ownStart.press(forDuration: 0.05, thenDragTo: ownStart.withOffset(CGVector(dx: 110, dy: 0)))
        XCTAssertTrue(app.buttons["cancelReply"].waitForExistence(timeout: 4))
        pickRailPhoto(in: app)
        XCTAssertEqual(input.placeholderValue, "Add a caption…", "The file can carry this reply on its own")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["removeAttachment"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["cancelReply"].waitForNonExistence(timeout: 4), "The strip clears")
        // The sent photo has no caption, so the photo itself speaks for the message, quote included.
        let sentPhoto = timeline.images.matching(NSPredicate(format: "label BEGINSWITH 'You, Photo' AND label CONTAINS[c] %@", "Replying to you: \(answer)")).firstMatch
        XCTAssertTrue(sentPhoto.waitForExistence(timeout: 5), "The file carried the reply")
        capture(app, "Photo sent as a reply")
    }

    @MainActor private func pickRailPhoto(in app: XCUIApplication) {
        app.buttons["attachFile"].tap()
        app.allowPhotoAccessIfAsked()
        let first = app.descendants(matching: .any).matching(identifier: "recentPhoto-0").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "The simulator's stock photos on the rail")
        first.tap()
        XCTAssertTrue(app.buttons["removeAttachment"].waitForExistence(timeout: 10))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
