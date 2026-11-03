import XCTest

extension XCTestCase {
    // Only with `TEST_RUNNER_HAUS_UI_CAPTURES=1`: each screenshot is a round trip.
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
    // A simulator that has seen a hardware keyboard keeps the software one minimised below the screen.
    @MainActor func showKeyboard(tapping field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = keyboards.firstMatch
        let screen = frame
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
    @MainActor func allowPhotoAccessIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        // Stop at the prompt or the rail's first photo; a prompt shown after the deadline is dismissed by the next tap,
        // denying the rail for the whole run.
        let railPhoto = descendants(matching: .any).matching(identifier: "recentPhoto-0").firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !allow.exists, !railPhoto.exists { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        if allow.exists { allow.tap() }
    }

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
