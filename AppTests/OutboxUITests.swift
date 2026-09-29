import XCTest

final class OutboxUITests: XCTestCase {
    @MainActor func testOfflineEncryptedQueueSurvivesRelaunchAndServerAcceptanceDoesNotReplay() throws {
        continueAfterFailure = false
        let lab = try LabFixture(orSkip: "Requires disposable local OMEMO peer")
        let peer = lab.peer
        let app = lab.launch()
        app.connectToLab(); app.buttons["Disconnect"].tap()
        let input = app.startChat(with: peer)
        input.tap()
        let marker = "Queued encrypted \(UUID().uuidString.prefix(6))"
        input.typeText(marker); app.buttons["sendMessage"].tap()
        let messages = app.textViews.containing(NSPredicate(format: "value == %@", marker))
        XCTAssertTrue(messages.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(messages.firstMatch.label.contains("Waiting to send"))
        app.terminate(); app.launch()
        let chat = app.buttons["chat.\(peer)"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        XCTAssertTrue(messages.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(messages.firstMatch.label.contains("Waiting to send"))
        app.navigationBars.buttons["BackButton"].tap(); app.connectToLab()
        app.returnToChats(); chat.tap()
        app.openEncryptionDetails()
        app.acceptPendingDevices()
        app.closeEncryptionDetails()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: messages)], timeout: 30)
        let sent = messages.matching(serverHeldLabel).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15))
        app.terminate(); app.launch(); app.connectToLab()
        app.returnToChats(); chat.tap()
        XCTAssertEqual(messages.count, 2)
        let duplicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 2"), object: messages)
        duplicate.isInverted = true; wait(for: [duplicate], timeout: 3)
        sent.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Retry message"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.25)).tap()
        app.navigationBars.buttons["BackButton"].tap(); app.buttons["Settings"].tap(); app.buttons["Disconnect"].tap()
    }
}
