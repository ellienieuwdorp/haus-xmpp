import XCTest

/// The attachment panel stands in for the software keyboard: same height, the composer riding on top, and the
/// recent-photos rail feeding the tray in tap order. Sample chats need no lab; photos are the simulator's stock ones.
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
        composer(in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
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

    @MainActor func testRailPicksLandInTheTrayInTapOrder() throws {
        continueAfterFailure = false
        let app = openAlex()
        openPanel(in: app)
        let first = photo(0, in: app), second = photo(1, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        second.tap()
        let removes = app.buttons.matching(identifier: "removeAttachment")
        let two = NSPredicate { _, _ in removes.count == 2 }
        wait(for: [XCTNSPredicateExpectation(predicate: two, object: nil)], timeout: 15)
        XCTAssertEqual(first.value as? String, "Selected, 1 of 2")
        XCTAssertEqual(second.value as? String, "Selected, 2 of 2")
        XCTAssertEqual(removes.element(boundBy: 1).label, "Remove Photo, 2 of 2", "VoiceOver can tell the removes apart")
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled, "Photos alone can be sent")

        // A second tap takes the photo back out and the other one becomes the first.
        first.tap()
        let one = NSPredicate { _, _ in removes.count == 1 }
        wait(for: [XCTNSPredicateExpectation(predicate: one, object: nil)], timeout: 5)
        XCTAssertEqual(first.value as? String ?? "", "", "No badge once taken back out")
        XCTAssertEqual(second.value as? String, "Selected, 1 of 1")

        // Removing from the tray clears the rail's badge too.
        removes.firstMatch.tap()
        let none = NSPredicate { _, _ in removes.count == 0 }
        wait(for: [XCTNSPredicateExpectation(predicate: none, object: nil)], timeout: 5)
        XCTAssertEqual(second.value as? String ?? "", "")
    }

    /// The recent photos are one library for the whole app, so a later chat's rail must still get the tiles even
    /// though the library already counts as read: the regression is a second chat's panel opening blank. It does not
    /// show that the library is read only once; `main` also passes, because each chat read the library itself.
    @MainActor func testASecondChatsPanelShowsThePhotos() throws {
        continueAfterFailure = false
        let app = openAlex()
        openPanel(in: app)
        XCTAssertTrue(photo(0, in: app).waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.staticTexts["Maya"].waitForExistence(timeout: 5))
        app.staticTexts["Maya"].tap()
        XCTAssertTrue(app.buttons["attachFile"].waitForExistence(timeout: 5))
        settle()
        app.buttons["attachFile"].tap()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForExistence(timeout: 5), "The panel's chips")
        XCTAssertTrue(photo(0, in: app).waitForExistence(timeout: 5), "Maya's panel shows the recent photos")
    }

    @MainActor func testDragRotationAndLeavingCloseThePanel() throws {
        continueAfterFailure = false
        let app = openAlex()
        let attach = app.buttons["attachFile"]
        let timeline = app.collectionViews["conversation.timeline"]

        // An interactive drag puts the panel away like a keyboard, and the × turns back into a +.
        openPanel(in: app)
        timeline.swipeDown()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        let reset = NSPredicate { _, _ in attach.label == "Add attachment" }
        wait(for: [XCTNSPredicateExpectation(predicate: reset, object: nil)], timeout: 5)

        // Turning the phone closes it (the keyboard guide would keep the old size) and the composer returns down.
        openPanel(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        let window = app.windows.firstMatch
        let upright = NSPredicate { _, _ in window.frame.height > window.frame.width }
        wait(for: [XCTNSPredicateExpectation(predicate: upright, object: nil)], timeout: 5)
        wait(for: [XCTNSPredicateExpectation(predicate: reset, object: nil)], timeout: 5)

        // Leaving the chat takes the panel and the picks with it.
        openPanel(in: app)
        photo(0, in: app).tap()
        XCTAssertTrue(app.buttons["removeAttachment"].waitForExistence(timeout: 15))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.staticTexts["Alex"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["attachPhotos"].exists)
        app.staticTexts["Alex"].tap()
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        XCTAssertEqual(attach.label, "Add attachment")
        XCTAssertFalse(app.buttons["attachPhotos"].exists)
        XCTAssertFalse(app.buttons["removeAttachment"].exists)
    }
}
