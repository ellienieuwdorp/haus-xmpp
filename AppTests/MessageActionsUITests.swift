import XCTest

/// Alex's sample chat: the icon-only compose and send controls, editing and unsending an own message through the
/// long-press overlay, the overlay targeting the bubble only, starring, the starred filter and native text selection.
/// `-demo-unreadable` adds two placeholders after the sample messages: an own send from another device that did not
/// encrypt for this one, and an incoming message that could not be read.
final class MessageActionsUITests: XCTestCase {
    @MainActor func testComposeEditUnsendStarFilterAndSelectText() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demo-unreadable"]
        app.isolateMessageStorage()
        app.launch()

        XCTContext.runActivity(named: "Icon-only compose control") { _ in
            let compose = app.buttons["newConversation"]
            XCTAssertTrue(compose.waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts["New conversation"].exists)
            XCTAssertLessThanOrEqual(compose.frame.width, 68)
            // A native bottom-bar item reports its glyph frame (36pt); its glass hit area is the full 44pt+ bar height.
            XCTAssertGreaterThanOrEqual(compose.frame.height, 36)
            capture(app, "Centered compose control")
        }
        let incomingUnreadable = "Couldn't read this message"
        let row = app.buttons["chat.alex@preview.local"]
        XCTAssertTrue(row.label.contains(incomingUnreadable), "the newest message is the unreadable one: \(row.label)")
        capture(app, "Chat list preview")
        app.staticTexts["Alex"].tap()
        // The attach button is part of the first composer frame; it never waits for a connection.
        XCTAssertTrue(app.buttons["attachFile"].waitForExistence(timeout: 1))
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        let send = app.buttons["sendMessage"]

        XCTContext.runActivity(named: "A placeholder has nothing to reply to") { _ in
            let placeholder = app.textViews.containing(NSPredicate(format: "value == %@", incomingUnreadable)).firstMatch
            XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
            let start = placeholder.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 110, dy: 0)))
            XCTAssertFalse(app.buttons["cancelReply"].waitForExistence(timeout: 1), "Swiping a placeholder must not start a reply")
            XCTAssertTrue(app.buttons["attachFile"].exists, "The swipe stays in the chat")
        }

        let original = "That sounds perfect. Around ten?"
        let outgoing = app.textViews.containing(NSPredicate(format: "value == %@", original)).matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        let originalWidth = outgoing.frame.width
        let edited = app.textViews.containing(NSPredicate(format: "value == %@", original + " Sharp.")).firstMatch

        XCTContext.runActivity(named: "Edit: the composer takes the text, the send circle saves, the bubble updates in place") { _ in
            outgoing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
            let edit = app.buttons["Edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            XCTAssertTrue(app.staticTexts["Editing message"].waitForExistence(timeout: 5))
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, original)
            XCTAssertFalse(send.isEnabled, "an unchanged text has nothing to save")
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            input.typeText(" Sharp.")
            XCTAssertTrue(send.isEnabled)
            send.tap()
            XCTAssertTrue(edited.waitForExistence(timeout: 10))
            XCTAssertTrue(edited.label.contains("edited"))
            XCTAssertFalse(app.staticTexts["Editing message"].exists)
            XCTAssertFalse(app.textViews.containing(NSPredicate(format: "value == %@", original)).firstMatch.exists, "an edit never adds a bubble")
            capture(app, "Edited bubble")
        }

        XCTContext.runActivity(named: "Unsend: confirmation first, then a quiet placeholder with no reaction row and no text actions") { _ in
            edited.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
            let unsend = app.buttons["Unsend"]
            XCTAssertTrue(unsend.waitForExistence(timeout: 5))
            unsend.tap()
            let confirm = app.sheets.buttons["Unsend"].exists ? app.sheets.buttons["Unsend"] : app.buttons["Unsend"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            let placeholder = app.textViews.containing(NSPredicate(format: "value == %@", "You unsent a message")).firstMatch
            XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
            XCTAssertLessThanOrEqual(placeholder.frame.width, max(originalWidth, 240) + 1)
            capture(app, "Unsent bubble")
            placeholder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
            XCTAssertTrue(app.buttons["Star message"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Edit"].exists)
            XCTAssertFalse(app.buttons["Copy"].exists)
            app.buttons["Dismiss"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Star message"].waitForNonExistence(timeout: 5))
        }

        let marker = "A small detail \(UUID().uuidString.prefix(4))"
        let message = app.textViews.containing(NSPredicate(format: "value == %@", marker)).firstMatch
        XCTContext.runActivity(named: "The send circle keeps its frame from enabled to disabled") { _ in
            input.tap()
            input.typeText(marker)
            let enabledFrame = send.frame
            XCTAssertGreaterThanOrEqual(enabledFrame.width, 44)
            XCTAssertGreaterThanOrEqual(enabledFrame.height, 44)
            capture(app, "Centered send enabled")
            send.tap()
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertEqual(send.frame, enabledFrame)
            XCTAssertFalse(send.isEnabled)
            capture(app, "Centered send disabled after sending")
        }

        XCTContext.runActivity(named: "Bubble-only actions, a disabled reaction row, and a star that keeps the width") { _ in
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
        }

        XCTContext.runActivity(named: "The starred filter lists only starred messages") { _ in
            let unstarred = app.textViews.containing(NSPredicate(format: "value == %@", "See you there!")).firstMatch
            XCTAssertTrue(unstarred.exists)
            app.buttons["Conversation options"].tap()
            app.buttons["Starred messages"].tap()
            let showAll = app.buttons["Show all"]
            XCTAssertTrue(showAll.waitForExistence(timeout: 3))
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertTrue(message.label.contains("starred"))
            XCTAssertFalse(unstarred.exists)
            showAll.tap()
            XCTAssertTrue(unstarred.waitForExistence(timeout: 5))
        }

        XCTContext.runActivity(named: "Select text hands over to native selection") { _ in
            message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
            XCTAssertTrue(app.buttons["Select text"].waitForExistence(timeout: 5))
            app.buttons["Select text"].tap()
            XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5) || app.buttons["Copy"].exists)
            capture(app, "Explicit native text selection")
        }
    }
}
