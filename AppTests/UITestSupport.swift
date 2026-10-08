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
