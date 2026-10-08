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
    /// Taps `field` and waits for the software keyboard to push it up, failing at once when it does not. A simulator
    /// that has seen a hardware keyboard keeps the software one minimised below the screen: the field stays at rest,
    /// and the test used to fail much later on a layout measurement (`467.0 is not equal to 826.0`) that said nothing
    /// about the cause.
    @MainActor func showKeyboard(tapping field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let resting = field.frame.minY
        field.tap()
        let raised = NSPredicate { _, _ in field.frame.minY < resting - 150 }
        guard XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: raised, object: nil)], timeout: 5) != .completed else { return }
        let keyboard = keyboards.firstMatch
        let frame = keyboard.exists ? keyboard.frame : .null
        let state = "field at y \(Int(field.frame.minY)), resting at \(Int(resting)); keyboard \(keyboard.exists ? "\(frame)" : "absent")"
        // A full keyboard on screen with the field still at rest is the app's layout. Anything else is the simulator: a
        // simulator that has seen a hardware keyboard minimises the software one, which then sits below the screen.
        if frame.height > 200, frame.minY < resting {
            XCTFail("The software keyboard showed but the field stayed put (\(state)): the layout did not follow it.", file: file, line: line)
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
