import XCTest

/// The attachment panel stands in for the software keyboard: same height, the composer riding on top, and the
/// recent-photos rail and the system picker feeding the tray. Sample chats accept files locally (nothing is uploaded),
/// so no lab is needed; photos are the simulator's stock ones.
final class AttachmentPanelUITests: XCTestCase {
    @MainActor private func openAlex() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        XCTAssertTrue(app.staticTexts["Alex"].waitForExistence(timeout: 15))
        app.staticTexts["Alex"].tap()
        XCTAssertTrue(app.buttons["attachFile"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func composer(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["messageComposer"]
        return field.exists ? field : app.textViews["messageComposer"]
    }

    /// A rail tile; UIKit reports it as a cell even though it carries the button trait.
    @MainActor private func photo(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "recentPhoto-\(index)").firstMatch
    }

    @MainActor private func openPanel(in app: XCUIApplication) {
        app.buttons["attachFile"].tap()
        app.allowPhotoAccessIfAsked()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForExistence(timeout: 5), "The panel's chips")
        XCTAssertEqual(app.buttons["attachFile"].label, "Close attachments")
    }

    private func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8)) }

    @MainActor func testPanelSwapsWithTheKeyboardAtTheSameHeight() throws {
        continueAfterFailure = false
        let app = openAlex()
        let attach = app.buttons["attachFile"]
        XCTAssertGreaterThanOrEqual(attach.frame.width, 44)
        XCTAssertGreaterThanOrEqual(attach.frame.height, 44)
        XCTAssertEqual(attach.label, "Add attachment")
        app.showKeyboard(tapping: composer(in: app))
        settle()
        let keyboardTop = attach.frame.minY

        openPanel(in: app)
        settle()
        XCTAssertFalse(app.keyboards.buttons["Next keyboard"].exists, "The panel replaced the letters")
        // Cached from the keyboard just shown, so the composer stays exactly where the keyboard left it.
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
        XCTAssertTrue(photo(0, in: app).waitForExistence(timeout: 5))
        let rail = app.collectionViews["recentPhotos"]
        XCTAssertGreaterThan(rail.frame.minY, attach.frame.maxY, "The panel sits under the composer")

        // Tapping the field brings the letters back in place of the panel.
        composer(in: app).tap()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(attach.label, "Add attachment")
        settle()
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)

        // And "+" swaps once more; its second press closes everything.
        openPanel(in: app)
        attach.tap()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(attach.label, "Add attachment")
    }

    /// The rail feeds the tray in tap order, the panel closes like a keyboard (drag, rotation, leaving the chat), a
    /// later chat's panel still shows the photos, and the system picker fills the tray. Sending the tray is owned by
    /// AttachmentDispatchTests.
    @MainActor func testRailPickerAndPanelLifecycle() throws {
        continueAfterFailure = false
        let app = openAlex()
        let attach = app.buttons["attachFile"]
        let timeline = app.collectionViews["conversation.timeline"]
        let removes = app.buttons.matching(identifier: "removeAttachment")
        let reset = NSPredicate { _, _ in attach.label == "Add attachment" }
        func tray(holds count: Int, timeout: TimeInterval = 5) {
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in removes.count == count }, object: nil)], timeout: timeout)
        }

        XCTContext.runActivity(named: "Rail picks land in the tray in tap order") { _ in
            openPanel(in: app)
            let first = photo(0, in: app), second = photo(1, in: app)
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            first.tap()
            second.tap()
            tray(holds: 2, timeout: 15)
            XCTAssertEqual(first.value as? String, "Selected, 1 of 2")
            XCTAssertEqual(second.value as? String, "Selected, 2 of 2")
            XCTAssertEqual(removes.element(boundBy: 1).label, "Remove Photo, 2 of 2", "VoiceOver can tell the removes apart")
            XCTAssertTrue(app.buttons["sendMessage"].isEnabled, "Photos alone can be sent")

            // A second tap takes the photo back out and the other one becomes the first.
            first.tap()
            tray(holds: 1)
            XCTAssertEqual(first.value as? String ?? "", "", "No badge once taken back out")
            XCTAssertEqual(second.value as? String, "Selected, 1 of 1")

            // Removing from the tray clears the rail's badge too.
            removes.firstMatch.tap()
            tray(holds: 0)
            XCTAssertEqual(second.value as? String ?? "", "")
        }

        XCTContext.runActivity(named: "An interactive drag puts the panel away like a keyboard") { _ in
            timeline.swipeDown()
            XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
            // The × turns back into a +.
            wait(for: [XCTNSPredicateExpectation(predicate: reset, object: nil)], timeout: 5)
        }

        XCTContext.runActivity(named: "Turning the phone closes the panel and the composer returns down") { _ in
            // Closed, because the keyboard guide would keep the old size.
            openPanel(in: app)
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
            XCUIDevice.shared.orientation = .portrait
            let window = app.windows.firstMatch
            let upright = NSPredicate { _, _ in window.frame.height > window.frame.width }
            wait(for: [XCTNSPredicateExpectation(predicate: upright, object: nil)], timeout: 5)
            wait(for: [XCTNSPredicateExpectation(predicate: reset, object: nil)], timeout: 5)
        }

        XCTContext.runActivity(named: "Leaving takes the panel and the picks; a second chat's panel still shows the photos") { _ in
            openPanel(in: app)
            photo(0, in: app).tap()
            XCTAssertTrue(removes.firstMatch.waitForExistence(timeout: 15))
            app.buttons["BackButton"].tap()
            XCTAssertTrue(app.staticTexts["Maya"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["attachPhotos"].exists)
            // The recent photos are one library for the whole app, so this rail must get the tiles even though the
            // library already counts as read: the regression is a second chat's panel opening blank.
            app.staticTexts["Maya"].tap()
            XCTAssertTrue(attach.waitForExistence(timeout: 5))
            settle()
            attach.tap()
            XCTAssertTrue(app.buttons["attachPhotos"].waitForExistence(timeout: 5), "The panel's chips")
            XCTAssertTrue(photo(0, in: app).waitForExistence(timeout: 5), "Maya's panel shows the recent photos")
            app.buttons["BackButton"].tap()
            XCTAssertTrue(app.staticTexts["Alex"].waitForExistence(timeout: 5))
            app.staticTexts["Alex"].tap()
            XCTAssertTrue(attach.waitForExistence(timeout: 5))
            XCTAssertEqual(attach.label, "Add attachment")
            XCTAssertFalse(app.buttons["attachPhotos"].exists)
            XCTAssertFalse(removes.firstMatch.exists, "Alex's pick left with the panel")
        }

        XCTContext.runActivity(named: "The system photo picker fills the tray") { _ in
            app.pickPhotos(2)
            removes.firstMatch.tap()
            removes.firstMatch.tap()
            tray(holds: 0)
        }
    }
}
