import XCTest

/// The chat list's trailing swipe actions: Pin, and Mute with its duration dialog, a quiet row glyph and the details
/// row that ends it. Mute is local. The demo seeds Maya as muted always.
final class ChatListSwipeUITests: XCTestCase {
    @MainActor func testSwipePinAndMuteThenUnmuteFromDetails() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()

        let alex = app.buttons["chat.alex@preview.local"], maya = app.buttons["chat.maya@preview.local"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        XCTAssertEqual(maya.value as? String, "Muted", "The demo's muted sample")
        let mute = app.buttons["Mute"]

        XCTContext.runActivity(named: "Pin from the trailing swipe") { _ in
            // Every test starts from its own store, where no sample chat is pinned or muted.
            XCTAssertEqual(alex.value as? String ?? "", "")
            alex.swipeLeft()
            let pin = app.buttons["Pin"]
            XCTAssertTrue(pin.waitForExistence(timeout: 3))
            XCTAssertTrue(mute.exists, "Mute sits beside Pin")
            capture(app, "Mute swipe action")
            pin.tap()
            // The pin change lands after the swipe action has closed, so wait for it rather than asserting at once.
            XCTAssertTrue(wait(alex, value: "Pinned"), "Pin must mark the row pinned")
            capture(app, "Centered pin and larger compose")
        }

        XCTContext.runActivity(named: "Mute for 8 hours from the same swipe") { _ in
            let heightBefore = alex.frame.height
            alex.swipeLeft()
            XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 3), "A pinned row offers Unpin")
            capture(app, "Trailing pin action")
            mute.tap()
            let eightHours = app.buttons["For 8 hours"]
            XCTAssertTrue(eightHours.waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["For 1 hour"].exists && app.buttons["For 1 week"].exists && app.buttons["Always"].exists)
            capture(app, "Mute duration dialog")
            XCTAssertFalse((alex.value as? String ?? "").contains("Muted"), "No change before a duration is picked")
            eightHours.tap()
            XCTAssertTrue(wait(alex, value: "Pinned, Muted"), "8 hours must mute the row")
            XCTAssertEqual(alex.frame.height, heightBefore, accuracy: 0.5, "The glyph must not change the row")
            capture(app, "Muted row glyph")
        }

        XCTContext.runActivity(named: "The details row names the mute and ends it") { _ in
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
        }
    }

    /// Waits for `value`; the list applies a pin or mute change a moment after the swipe action or dialog closes.
    @MainActor private func wait(_ element: XCUIElement, value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }
}
