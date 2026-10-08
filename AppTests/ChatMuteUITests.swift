import XCTest

/// Mute is local: a trailing swipe action beside Pin, a duration dialog, a quiet row glyph and the details row.
/// The demo seeds Maya as muted always.
final class ChatMuteUITests: XCTestCase {
    @MainActor func testSwipeMuteDialogAndDetailsRow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()

        let alex = app.buttons["chat.alex@preview.local"], maya = app.buttons["chat.maya@preview.local"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        XCTAssertEqual(maya.value as? String, "Muted", "The demo's muted sample")
        XCTAssertFalse((alex.value as? String ?? "").contains("Muted"))
        let heightBefore = alex.frame.height

        // Mute sits beside Pin; picking it changes nothing until a duration is chosen.
        alex.swipeLeft()
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pin"].exists || app.buttons["Unpin"].exists)
        capture(app, "Mute swipe action")
        mute.tap()
        let eightHours = app.buttons["For 8 hours"]
        XCTAssertTrue(eightHours.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["For 1 hour"].exists && app.buttons["For 1 week"].exists && app.buttons["Always"].exists)
        capture(app, "Mute duration dialog")
        XCTAssertFalse((alex.value as? String ?? "").contains("Muted"), "No change before a duration is picked")
        eightHours.tap()
        XCTAssertTrue(wait(alex, muted: true), "8 hours must mute the row")
        XCTAssertEqual(alex.frame.height, heightBefore, accuracy: 0.5, "The glyph must not change the row")
        capture(app, "Muted row glyph")

        // The details row names the mute and ends it.
        alex.tap()
        let header = app.buttons["chatDetails"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.tap()
        let row = app.buttons["chatNotifications"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("Muted until"), String(describing: row.value))
        capture(app, "Details notifications row")
        row.tap()
        let unmute = app.buttons["Unmute"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Mentions only"].exists, "Mentions only is for groups")
        capture(app, "Details notifications menu")
        unmute.tap()
        XCTAssertTrue(wait(row, value: "All messages"))
        for _ in 0..<2 {
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(wait(alex, muted: false))

        // Unmute from the list, and mute always from it.
        maya.swipeLeft()
        let unmuteAction = app.buttons["Unmute"]
        XCTAssertTrue(unmuteAction.waitForExistence(timeout: 3))
        unmuteAction.tap()
        XCTAssertTrue(wait(maya, muted: false))
        alex.swipeLeft()
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        mute.tap()
        XCTAssertTrue(app.buttons["Always"].waitForExistence(timeout: 3))
        app.buttons["Always"].tap()
        XCTAssertTrue(wait(alex, muted: true))
    }

    @MainActor private func wait(_ element: XCUIElement, muted: Bool, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: muted ? "value CONTAINS 'Muted'" : "NOT (value CONTAINS 'Muted')")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor private func wait(_ element: XCUIElement, value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }
}
