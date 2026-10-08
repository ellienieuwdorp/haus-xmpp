import XCTest

extension XCTestCase {
    /// Keeps a review screenshot of `source` in the result bundle, only when the runner was started with
    /// `TEST_RUNNER_HAUS_UI_CAPTURES=1`. Routine runs need the assertions, not the pictures, and each screenshot is a
    /// round trip. `settle` lets an animation finish before the shot, so routine runs skip that wait too.
    @MainActor func capture(_ source: some XCUIScreenshotProviding, _ name: String, settle: TimeInterval = 0) {
        guard ProcessInfo.processInfo.environment["HAUS_UI_CAPTURES"] == "1" else { return }
        if settle > 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: settle)) }
        let attachment = XCTAttachment(screenshot: source.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIApplication {
    /// Taps `field` and waits until the software keyboard is on screen with the field above it, failing at once when
    /// it is not. A simulator that has seen a hardware keyboard keeps the software one minimised below the screen: the
    /// field stays at rest, and the test used to fail much later on a layout measurement (`467.0 is not equal to
    /// 826.0`) that said nothing about the cause.
    @MainActor func showKeyboard(tapping field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = keyboards.firstMatch
        let screen = frame
        // A minimised keyboard still exists, with its frame below the screen.
        let keyboardUp = { keyboard.exists && keyboard.frame.minY < screen.maxY - 200 }
        field.tap()
        let ready = NSPredicate { _, _ in keyboardUp() && field.frame.maxY <= keyboard.frame.minY + 2 }
        guard XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5) != .completed else { return }
        let state = "field \(field.frame), keyboard \(keyboard.exists ? "\(keyboard.frame)" : "absent"), screen height \(Int(screen.height))"
        if keyboardUp() {
            XCTFail("The software keyboard came up but covers the field (\(state)): the layout did not follow it.", file: file, line: line)
        } else {
            XCTFail("""
                The software keyboard never came on screen after tapping the field (\(state)). This is the simulator, not the \
                app: it minimises the keyboard because it has seen a hardware keyboard. Turn that off and run again: \
                xcrun simctl spawn <udid> defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool NO \
                (see AppTests/README.md).
                """, file: file, line: line)
        }
    }
}

extension XCUIApplication {
    /// The attachment panel asks for the photo library on its first open; the rail needs full access.
    @MainActor func allowPhotoAccessIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        // The prompt comes once per install; after that the rail's first photo shows instead. Stop at whichever is first:
        // a fixed wait for a prompt that no longer comes cost every later open its whole timeout. The deadline is generous
        // because a prompt that shows after it is dismissed by the next tap, which denies the rail for the whole run.
        let railPhoto = descendants(matching: .any).matching(identifier: "recentPhoto-0").firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !allow.exists, !railPhoto.exists { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        if allow.exists { allow.tap() }
    }

    /// Picks the first `count` library photos through the system picker, opened from the attachment panel's Photos
    /// chip, and waits until each has landed in the tray.
    @MainActor func pickPhotos(_ count: Int) {
        let attach = buttons["attachFile"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        attach.tap()
        allowPhotoAccessIfAsked()
        let photos = buttons["attachPhotos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "The attachment panel's Photos chip")
        photos.tap()
        let grid = images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 10), "The simulator's stock photos")
        // The picker runs out of process: its elements are visible but report not hittable, so tap their centres.
        let centre = CGVector(dx: 0.5, dy: 0.5)
        for index in 0..<count { grid.element(boundBy: index).coordinate(withNormalizedOffset: centre).tap() }
        buttons["Done"].coordinate(withNormalizedOffset: centre).tap()
        let removes = buttons.matching(identifier: "removeAttachment")
        let filled = NSPredicate { _, _ in removes.count == count }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: filled, object: nil)], timeout: 15), .completed,
                       "\(count) photos in the tray")
    }
}
