import XCTest

/// The demo's fixed samples: Alex is online, Maya was last seen on a fixed date, Notes to self has no subtitle.
final class LastSeenUITests: XCTestCase {
    @MainActor func testHeaderShowsLastSeenOnlyWhenKnown() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()

        let header = app.buttons["chatDetails"]
        func open(_ chat: String) -> XCUIElement {
            let row = app.buttons["chat.\(chat)"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), chat)
            row.tap()
            XCTAssertTrue(header.waitForExistence(timeout: 10), chat)
            return header
        }
        func back() {
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            XCTAssertTrue(header.waitForNonExistence(timeout: 5))
        }

        let alex = open("alex@preview.local")
        XCTAssertEqual(alex.label, "Alex, Online")
        let alexShot = XCTAttachment(screenshot: app.screenshot()); alexShot.name = "Alex online"; alexShot.lifetime = .keepAlways; add(alexShot)
        back()

        let maya = open("maya@preview.local")
        XCTAssertTrue(maya.label.hasPrefix("Maya, Last seen "), maya.label)
        let mayaShot = XCTAttachment(screenshot: app.screenshot()); mayaShot.name = "Maya last seen"; mayaShot.lifetime = .keepAlways; add(mayaShot)
        back()

        let notes = open("notes@preview.local")
        XCTAssertEqual(notes.label, "Notes to self")
    }
}
