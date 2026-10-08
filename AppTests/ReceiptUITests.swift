import XCTest

/// Two clients on the lab: the echo peer answers `<request/>` with a receipt and `<markable/>` with a
/// read marker, so an accepted bubble climbs to delivered and then read without ever changing width.
final class ReceiptUITests: XCTestCase {
    @MainActor func testSentMessageClimbsFromAcceptedToDeliveredToReadInsideAFixedFooter() throws {
        continueAfterFailure = false
        let lab = try LabFixture(orSkip: "Requires disposable local OMEMO echo peer")
        let peer = lab.peer
        let app = lab.launch()
        app.buttons["Settings"].tap()
        // The switches live outside any staging gate and default on.
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
        // The echo peer answers within a second, so "Sent" may never be observable; the width is fixed from the first frame.
        let acceptedWidth = outgoing.frame.width
        // The peer sends its receipt and marker back to back, so "Delivered" may already have become "Read".
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Delivered' OR label CONTAINS 'Read'"), object: outgoing)], timeout: 25)
        XCTAssertEqual(outgoing.frame.width, acceptedWidth, accuracy: 1)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Read"), object: outgoing)], timeout: 25)
        XCTAssertEqual(outgoing.frame.width, acceptedWidth, accuracy: 1)
        capture(app, "Read receipt inside the bubble")
        // The echo reply arrives after our receipt request; the states survive a relaunch because they are projected, not remembered.
        let echoed = app.textViews.containing(NSPredicate(format: "value == %@", marker)).matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", "You:")).firstMatch
        XCTAssertTrue(echoed.waitForExistence(timeout: 25))
        app.terminate(); app.launch()
        let chat = app.buttons["chat.\(peer)"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15)); chat.tap()
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        XCTAssertTrue(outgoing.label.contains("Read"))
    }
}
