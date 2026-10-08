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
    /// Taps `field` and waits for the software keyboard to push it up, failing at once when it does not. Some freshly
    /// cloned simulators never show the keyboard: the field stays at rest, and the test then fails much later on a
    /// layout measurement (`467.0 is not equal to 826.0`) that says nothing about the cause.
    @MainActor func showKeyboard(tapping field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let resting = field.frame.minY
        field.tap()
        let keyboard = keyboards.firstMatch
        // A connected hardware keyboard leaves only a short bar on screen, so the height tells the two apart.
        let raised = NSPredicate { _, _ in keyboard.exists && keyboard.frame.height > 200 && field.frame.minY < resting - 150 }
        guard XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: raised, object: nil)], timeout: 5) != .completed else { return }
        let height = keyboard.exists ? keyboard.frame.height : 0
        let position = "at y \(Int(field.frame.minY)), resting at \(Int(resting))"
        if height > 200 {
            XCTFail("A \(Int(height)) pt software keyboard showed but the field stayed put (\(position)): the layout did not follow the keyboard.",
                    file: file, line: line)
        } else {
            XCTFail("""
                The software keyboard never showed after tapping the field (\(height > 0 ? "only a \(Int(height)) pt bar" : "no keyboard"), field \(position)). \
                Likely the simulator, not the app: a hardware keyboard is connected to it, or a freshly cloned simulator has not \
                shown its keyboard yet. Disconnect the hardware keyboard, or show the keyboard there once by hand, then run again.
                """, file: file, line: line)
        }
    }
}
