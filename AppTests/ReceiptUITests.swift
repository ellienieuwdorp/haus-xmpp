import XCTest

final class ReceiptUITests: XCTestCase {
    @MainActor func testSentMessageClimbsFromAcceptedToDeliveredToReadInsideAFixedFooter() throws {
        continueAfterFailure = false
        let lab = try LabFixture(orSkip: "Requires disposable local OMEMO echo peer")
        let peer = lab.peer
        let app = lab.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["deliveryReceipts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["deliveryReceipts"].value as? String, "1")
        XCTAssertEqual(app.switches["readReceipts"].value as? String, "1")
        app.connectToLab()
        let composer = app.startChat(with: peer)
        let marker = "Please confirm \(UUID().uuidString.prefix(4))"
        composer.tap(); composer.typeText(marker); app.buttons["sendMessage"].tap()
        app.openEncryptionDetails()
        app.acceptPendingDevices()
        app.closeEncryptionDetails()
        let outgoing = app.textViews.containing(NSPredicate(format: "value == %@", marker)).matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        // The echo peer answers within a second, so "Sent" may never be observable.
        let acceptedWidth = outgoing.frame.width
        // The peer sends its receipt and marker back to back, so "Delivered" may already have become "Read".
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Delivered' OR label CONTAINS 'Read'"), object: outgoing)], timeout: 25)
        XCTAssertEqual(outgoing.frame.width, acceptedWidth, accuracy: 1)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Read"), object: outgoing)], timeout: 25)
        XCTAssertEqual(outgoing.frame.width, acceptedWidth, accuracy: 1)
        capture(app, "Read receipt inside the bubble")
        // The states survive a relaunch because they are projected, not remembered.
        let echoed = app.textViews.containing(NSPredicate(format: "value == %@", marker)).matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", "You:")).firstMatch
        XCTAssertTrue(echoed.waitForExistence(timeout: 25))
        app.terminate(); app.launch()
        let chat = app.buttons["chat.\(peer)"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15)); chat.tap()
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        XCTAssertTrue(outgoing.label.contains("Read"))
    }
}
