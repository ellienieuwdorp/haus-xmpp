import XCTest

final class AttachmentSendLabUITests: XCTestCase {
    @MainActor func testFourPhotosAndACaptionAllReachTheServer() throws {
        continueAfterFailure = false
        let lab = try LabFixture(orSkip: "Requires disposable local OMEMO peer")
        let app = lab.launch()
        app.connectToLab()
        let input = app.startChat(with: lab.peer)
        app.openEncryptionDetails()
        app.acceptPendingDevices()
        app.closeEncryptionDetails()
        app.pickPhotos(4)
        input.tap()
        let caption = "After four photos \(UUID().uuidString.prefix(6))"
        input.typeText(caption)
        app.buttons["sendMessage"].tap()
        // A file still uploading holds everything queued after it, so once the server holds the caption every photo has
        // gone. Our own bubble: the echo's can come first in the query.
        let sent = app.textViews.matching(NSPredicate(format: "value == %@ AND label BEGINSWITH %@", caption, "You:")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15))
        let held = XCTNSPredicateExpectation(predicate: serverHeldLabel, object: sent)
        XCTAssertEqual(XCTWaiter().wait(for: [held], timeout: 90), .completed, "the caption is still \(sent.label)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no upload was refused")

        XCTContext.runActivity(named: "A photo sent just before leaving finishes while the app is away") { _ in
            app.pickPhotos(1)
            input.tap()
            let after = "After leaving \(UUID().uuidString.prefix(6))"
            input.typeText(after)
            app.buttons["sendMessage"].tap()
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.waitForBackground())
            // Until suspended, or long enough for the PUT to finish away: the simulator can report the app running in
            // the background throughout.
            let suspended = NSPredicate { object, _ in (object as? XCUIApplication)?.state == .runningBackgroundSuspended }
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: suspended, object: app)], timeout: 30)
            app.activate()
            let caption = app.textViews.matching(NSPredicate(format: "value == %@ AND label BEGINSWITH %@", after, "You:")).firstMatch
            XCTAssertTrue(caption.waitForExistence(timeout: 15))
            let held = XCTNSPredicateExpectation(predicate: serverHeldLabel, object: caption)
            XCTAssertEqual(XCTWaiter().wait(for: [held], timeout: 90), .completed, "the caption is still \(caption.label)")
            XCTAssertFalse(app.alerts.firstMatch.exists, "no upload was refused")
        }
    }
}
