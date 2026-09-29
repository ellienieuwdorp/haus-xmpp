import XCTest

/// `-demo-unreadable` adds two placeholders to Alex's chat: an own send from another device that did not encrypt for
/// this one, and an incoming message that could not be read. They are notices, never content.
final class UnreadablePlaceholderUITests: XCTestCase {
    private let ownText = "Sent from another device and not encrypted for this iPhone"
    private let incomingText = "Couldn't read this message"

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demo-unreadable"]
        app.isolateMessageStorage()
        app.launch()
        return app
    }

    @MainActor func testPlaceholderBubblesAreQuietUnreactableAndPreviewed() throws {
        continueAfterFailure = false
        let app = launch()
        let row = app.buttons["chat.alex@preview.local"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.label.contains(incomingText), "the newest message is the unreadable one: \(row.label)")
        capture(app, "Chat list preview")
        row.tap()

        let own = app.textViews.containing(NSPredicate(format: "value == %@", ownText)).firstMatch
        let incoming = app.textViews.containing(NSPredicate(format: "value == %@", incomingText)).firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        XCTAssertTrue(incoming.waitForExistence(timeout: 5))
        // VoiceOver hears who it is from and why there is no text; a direct chat's peer is "Contact".
        XCTAssertTrue(incoming.label.hasPrefix("Contact: \(incomingText), not readable on this device"), incoming.label)
        XCTAssertTrue(own.label.hasPrefix("You: \(ownText), not readable on this device"), own.label)
        // Sides: the own-device send is on the trailing side, the unreadable incoming one on the leading side.
        XCTAssertGreaterThan(own.frame.midX, incoming.frame.midX)
        XCTAssertLessThan(own.frame.maxY, incoming.frame.minY + 1)
        capture(app, "Placeholder bubbles")

        incoming.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Encryption details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Reply"].exists)
        XCTAssertFalse(app.buttons["Copy"].exists)
        XCTAssertFalse(app.buttons["Star message"].exists)
        XCTAssertFalse(app.buttons["Select text"].exists)
        capture(app, "Placeholder menu")
        // The action is not tapped here: sample chats have no Encryption Details state.
        app.buttons["Dismiss"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Encryption details"].waitForNonExistence(timeout: 2))

        // The composer still works and a new message lands after the placeholders.
        let field = app.textFields["messageComposer"]
        let composer = field.exists ? field : app.textViews["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        let marker = "After placeholders \(UUID().uuidString.prefix(6))"
        composer.typeText(marker)
        app.buttons["sendMessage"].tap()
        let sent = app.textViews.containing(NSPredicate(format: "value == %@", marker)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(sent.frame.minY, incoming.frame.maxY - 1)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
