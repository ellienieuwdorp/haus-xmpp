import XCTest

// The status mark is an image inside the preview's text, so only its label tells VoiceOver whether the last sent
// message was read. The demo's last messages are read (Alex), delivered (Maya) and held by the server (notes).
final class ChatRowUITests: XCTestCase {
    @MainActor func testPreviewSaysTheLastSentMessageStatus() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()

        let alex = app.buttons["chat.alex@preview.local"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        XCTAssertTrue(alex.label.contains("Read See you there!"), alex.label)
        XCTAssertTrue(app.buttons["chat.maya@preview.local"].label.contains("Delivered Always. See you this weekend!"))
        XCTAssertTrue(app.buttons["chat.notes@preview.local"].label.contains("Sent Starred things stay at the top of the list."))
    }
}
