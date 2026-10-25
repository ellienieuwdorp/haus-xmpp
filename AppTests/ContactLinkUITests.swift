import XCTest

/// A direct chat's Contact row in its details, on sample data: what it offers before anything is linked, that Contacts
/// is asked for only when linking starts, and that declining still offers a link by name. A room has no such row.
final class ContactLinkUITests: XCTestCase {
    @MainActor func testLinkingAsksForContactsOnlyWhenStartedAndOffersANameOnlyLinkWithoutIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .contacts)
        app.launchArguments = ["-demo", "-demo-group"]
        app.isolateMessageStorage()
        app.launch()

        let alex = app.buttons["chat.alex@preview.local"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        alex.tap()
        app.buttons["chatDetails"].tap()
        let row = app.buttons["chatContact"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "Contact")
        XCTAssertEqual(row.value as? String, "Not linked")
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        capture(app, "Contact row, not linked")

        row.tap()
        let link = app.buttons["Link to Contact…"]
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add to Contacts…"].exists)
        XCTAssertFalse(app.buttons["Unlink Contact"].exists)
        capture(app, "Contact menu, not linked")
        link.tap()

        // The system asks now, and only now.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = springboard.buttons["Don’t Allow"]
        XCTAssertTrue(decline.waitForExistence(timeout: 5), "Linking asks for Contacts")
        decline.tap()
        XCTAssertTrue(app.staticTexts["Link Without Contacts Access?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose Contact…"].exists && app.buttons["Open Settings"].exists)
        capture(app, "Link without access")
        // The dialog is a popover over the row on iOS 26: a tap outside it cancels.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        XCTAssertTrue(app.staticTexts["Link Without Contacts Access?"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(row.value as? String, "Not linked", "Nothing is linked until a contact is chosen")

        // A room is never linked to a contact.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let room = app.buttons["chat.trail@rooms.preview.local"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        room.tap()
        app.buttons["chatDetails"].tap()
        XCTAssertTrue(app.buttons["chatNotifications"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chatContact"].exists)
    }
}
