import XCTest

/// Several photos sent in one go against the lab. Each file needs its own slot and PUT before its message can go,
/// and the caption after them waits until every one of them has uploaded.
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
        // A file still uploading holds everything queued after it in its chat, so the caption goes last: once the
        // server holds it, every photo before it has uploaded and gone. A file that used up its tries raises an alert.
        let sent = app.textViews.containing(NSPredicate(format: "value == %@", caption)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15))
        let held = XCTNSPredicateExpectation(predicate: serverHeldLabel, object: sent)
        XCTAssertEqual(XCTWaiter().wait(for: [held], timeout: 90), .completed, "the caption is still \(sent.label)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no upload was refused")
    }
}
