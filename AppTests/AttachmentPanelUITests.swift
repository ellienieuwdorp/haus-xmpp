import XCTest

/// The attachment panel stands in for the software keyboard: same height, the composer riding on top, and the
/// recent-photos rail and the system picker feeding the tray. Sample chats accept files locally (nothing is uploaded),
/// so no lab is needed; photos are the simulator's stock ones.
final class AttachmentPanelUITests: XCTestCase {
    @MainActor private func openAlex(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + arguments
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

    /// The letters, rather than the panel, are the keyboard. The panel has no keys.
    @MainActor private func lettersUp(in app: XCUIApplication) -> Bool { app.keyboards.keys.count > 10 }

    @MainActor private func waitForLetters(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let up = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.lettersUp(in: app) }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [up], timeout: 5), .completed, "The letters are back", file: file, line: line)
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
        capture(app, "Letters")

        openPanel(in: app)
        settle()
        XCTAssertFalse(lettersUp(in: app), "The panel replaced the letters")
        // Cached from the keyboard just shown, so the composer stays exactly where the keyboard left it.
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
        XCTAssertTrue(photo(0, in: app).waitForExistence(timeout: 5))
        let rail = app.collectionViews["recentPhotos"]
        XCTAssertGreaterThan(rail.frame.minY, attach.frame.maxY, "The panel sits under the composer")
        capture(app, "Panel in place of the letters", settle: 0.6)

        // The × brings the letters back in place of the panel; the field keeps its focus, so nothing moves.
        attach.tap()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        waitForLetters(in: app)
        XCTAssertEqual(attach.label, "Add attachment")
        settle()
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
        capture(app, "Letters after the ×")

        // So does tapping the field while the panel is up.
        openPanel(in: app)
        settle()
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
        composer(in: app).tap()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        waitForLetters(in: app)
        XCTAssertEqual(attach.label, "Add attachment")
        settle()
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)

        // The letters type into the field the panel shared.
        composer(in: app).typeText("Hi")
        XCTAssertEqual(composer(in: app).value as? String, "Hi")
    }

    /// From no keyboard at all, "+" brings the panel up with the field focused behind it, and the × leaves the
    /// letters where the panel was. A drag on the timeline puts either away, and the × turns back into a +.
    @MainActor func testPanelFromRestAndDragDismissal() throws {
        continueAfterFailure = false
        let app = openAlex()
        let attach = app.buttons["attachFile"]
        let timeline = app.collectionViews["conversation.timeline"]
        let rest = attach.frame.minY
        // The keyboard's height, so the panel opened from rest has one to copy.
        app.showKeyboard(tapping: composer(in: app))
        settle()
        let keyboardTop = attach.frame.minY
        timeline.swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        settle()
        XCTAssertEqual(attach.frame.minY, rest, accuracy: 1)

        openPanel(in: app)
        settle()
        XCTAssertFalse(lettersUp(in: app), "The panel, not the letters")
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
        attach.tap()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        waitForLetters(in: app)
        settle()
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)

        // An interactive drag puts the panel away like a keyboard.
        openPanel(in: app)
        timeline.swipeDown()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in attach.label == "Add attachment" }, object: nil)], timeout: 5)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Nothing takes the panel's place")
        settle()
        XCTAssertEqual(attach.frame.minY, rest, accuracy: 1)

        // The field, focused again, gets the letters rather than the panel.
        app.showKeyboard(tapping: composer(in: app))
        waitForLetters(in: app)
        XCTAssertFalse(app.buttons["attachPhotos"].exists)
    }

    /// The message menu puts the panel away like the keyboard. Closing it without an action, or with one that
    /// presents nothing (a star), brings the panel back and the letters do not come up instead; Reply takes the
    /// composer, so the letters come up for it.
    @MainActor func testMessageMenuGivesThePanelBack() throws {
        continueAfterFailure = false
        let app = openAlex()
        let attach = app.buttons["attachFile"]
        let message = app.textViews.containing(NSPredicate(format: "value == %@", "See you there!")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        app.showKeyboard(tapping: composer(in: app))
        settle()
        let keyboardTop = attach.frame.minY
        openPanel(in: app)
        settle()
        func openMenu() {
            message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
            XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5))
        }
        func panelCameBack(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(app.buttons["Reply"].waitForNonExistence(timeout: 5), file: file, line: line)
            XCTAssertTrue(app.buttons["attachPhotos"].waitForExistence(timeout: 5), "The panel came back", file: file, line: line)
            settle()
            XCTAssertFalse(lettersUp(in: app), file: file, line: line)
            XCTAssertEqual(attach.label, "Close attachments", file: file, line: line)
            XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1, file: file, line: line)
        }

        openMenu()
        app.buttons["Dismiss"].firstMatch.tap()
        panelCameBack()

        openMenu()
        app.buttons["Star message"].tap()
        panelCameBack()

        // The field it came back on still swaps to the letters in place.
        attach.tap()
        waitForLetters(in: app)
        settle()
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)

        openPanel(in: app)
        settle()
        openMenu()
        app.buttons["Reply"].tap()
        XCTAssertTrue(app.buttons["cancelReply"].waitForExistence(timeout: 5))
        waitForLetters(in: app)
        XCTAssertFalse(app.buttons["attachPhotos"].exists)
        XCTAssertEqual(attach.label, "Add attachment")
    }

    /// The composer is rebuilt for a new appearance; the panel stays up through it, on the new field, in the same
    /// place, and the × still brings the letters back.
    @MainActor func testAppearanceChangeKeepsThePanelUp() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        let app = openAlex(["-appearanceMode", "automatic"])
        let attach = app.buttons["attachFile"]
        app.showKeyboard(tapping: composer(in: app))
        settle()
        let keyboardTop = attach.frame.minY
        openPanel(in: app)
        XCTAssertTrue(photo(0, in: app).waitForExistence(timeout: 5))
        settle()
        capture(app, "Panel, light")

        XCUIDevice.shared.appearance = .dark
        settle()
        XCTAssertTrue(app.buttons["attachPhotos"].exists, "The panel is still up")
        XCTAssertFalse(lettersUp(in: app))
        XCTAssertEqual(attach.label, "Close attachments")
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
        capture(app, "Panel after the switch to dark")

        attach.tap()
        XCTAssertTrue(app.buttons["attachPhotos"].waitForNonExistence(timeout: 5))
        waitForLetters(in: app)
        XCTAssertEqual(attach.label, "Add attachment")
        settle()
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
        capture(app, "Letters after the ×, dark")

        // And back, with the letters up this time: they stay up too.
        XCUIDevice.shared.appearance = .light
        settle()
        waitForLetters(in: app)
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
        capture(app, "Letters after the switch back to light")
        openPanel(in: app)
        settle()
        XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1)
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

    /// With limited photo access the panel offers Select More. Its picker takes the field's focus, and the panel comes
    /// back when it closes; turning the phone under the picker closes the panel for good. Grants limited access through
    /// the system prompt and resets it afterwards; the next panel asks again (see `allowPhotoAccessIfAsked`).
    @MainActor func testSelectMoreGivesThePanelBackUnlessItWasClosed() throws {
        continueAfterFailure = false
        XCUIApplication().resetAuthorizationStatus(for: .photos)
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
            XCUIApplication().resetAuthorizationStatus(for: .photos)
        }
        let app = openAlex()
        let attach = app.buttons["attachFile"]
        let selectMore = app.buttons["selectMorePhotos"]
        // The limited-library picker runs out of process: tap the centres of its elements.
        let centre = CGVector(dx: 0.5, dy: 0.5)
        let pickerCancel = app.buttons["Cancel"]
        app.showKeyboard(tapping: composer(in: app))
        settle()
        let keyboardTop = attach.frame.minY

        attach.tap()
        let limit = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Limit Access…"]
        guard limit.waitForExistence(timeout: 10) else {
            throw XCTSkip("The system showed no photo access prompt after the reset, so limited access cannot be granted here")
        }
        limit.tap()
        let grid = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 10))
        grid.firstMatch.coordinate(withNormalizedOffset: centre).tap()
        app.buttons["Update"].coordinate(withNormalizedOffset: centre).tap()
        XCTAssertTrue(pickerCancel.waitForNonExistence(timeout: 10))
        // The prompt's own picker took the field's focus, and the panel with it.
        if !selectMore.waitForExistence(timeout: 3) { openPanel(in: app) }
        XCTAssertTrue(selectMore.waitForExistence(timeout: 10), "The panel offers Select More")
        settle()
        XCTAssertEqual(attach.label, "Close attachments")
        capture(app, "Panel with limited access")

        func openPicker(file: StaticString = #filePath, line: UInt = #line) {
            selectMore.tap()
            XCTAssertTrue(pickerCancel.waitForExistence(timeout: 10), "The limited-library picker", file: file, line: line)
            settle()
        }
        func panelIsBack(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(pickerCancel.waitForNonExistence(timeout: 10), file: file, line: line)
            XCTAssertTrue(selectMore.waitForExistence(timeout: 5), "The panel came back", file: file, line: line)
            settle()
            XCTAssertFalse(lettersUp(in: app), file: file, line: line)
            XCTAssertEqual(attach.label, "Close attachments", file: file, line: line)
            XCTAssertEqual(attach.frame.minY, keyboardTop, accuracy: 1, file: file, line: line)
        }

        XCTContext.runActivity(named: "The panel comes back when the picker closes") { _ in
            openPicker()
            pickerCancel.coordinate(withNormalizedOffset: centre).tap()
            panelIsBack()
        }

        XCTContext.runActivity(named: "Turning the phone under the picker closes the panel for good") { _ in
            openPicker()
            XCUIDevice.shared.orientation = .landscapeLeft
            settle()
            XCUIDevice.shared.orientation = .portrait
            let window = app.windows.firstMatch
            let upright = NSPredicate { _, _ in window.frame.height > window.frame.width }
            wait(for: [XCTNSPredicateExpectation(predicate: upright, object: nil)], timeout: 5)
            settle()
            pickerCancel.coordinate(withNormalizedOffset: centre).tap()
            XCTAssertTrue(pickerCancel.waitForNonExistence(timeout: 10))
            settle()
            XCTAssertFalse(selectMore.exists, "The panel stays away")
            XCTAssertFalse(app.buttons["attachPhotos"].exists)
            XCTAssertEqual(attach.label, "Add attachment")
            capture(app, "After the picker closed over a rotation")
        }
    }
}
