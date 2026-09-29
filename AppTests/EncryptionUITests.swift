import XCTest

final class EncryptionUITests: XCTestCase {
    @MainActor func testReviewDevicesEncryptedRoundTripAndPersistentIdentity() throws {
        continueAfterFailure = false
        let lab = try LabFixture(orSkip: "Requires disposable local OMEMO echo peer")
        let peer = lab.peer
        let app = lab.launch()
        app.connectToLab()
        let input = app.startChat(with: peer)
        let marker = "Encrypted coffee ☕ \(UUID().uuidString.prefix(6))"
        input.tap(); input.typeText(marker)
        app.buttons["sendMessage"].tap()
        let bubbles = app.textViews.containing(NSPredicate(format: "value == %@", marker))
        XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(bubbles.firstMatch.label.contains("Waiting to send"))
        app.openEncryptionDetails()
        XCTAssertTrue(app.navigationBars["Devices & Encryption"].waitForExistence(timeout: 5))
        capture(app, "Encryption devices awaiting review")
        // Every acceptance is an explicit UI action against the displayed fixture fingerprint.
        app.acceptPendingDevices { capture(app, "Fingerprint review") }
        capture(app, "Accepted encryption devices")
        app.closeEncryptionDetails()
        let response = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: bubbles)
        wait(for: [response], timeout: 30)
        XCTAssertTrue(bubbles.allElementsBoundByIndex.contains { serverHeldLabel.evaluate(with: $0) || $0.label.contains("Sending, not yet confirmed") })
        capture(app, "Encrypted independent peer round trip")
        app.terminate(); app.launch()
        let chat = app.buttons["chat.\(peer)"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        XCTAssertEqual(bubbles.count, 2)
        app.openEncryptionDetails()
        XCTAssertTrue(app.staticTexts["Accepted · not verified"].firstMatch.waitForExistence(timeout: 5))
        app.closeEncryptionDetails()
        app.navigationBars.buttons["BackButton"].tap()
        app.connectToLab()
        app.returnToChats(); chat.tap()
        XCTAssertEqual(bubbles.count, 2)
        app.openEncryptionDetails()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "encryptionDevice."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch.exists)
        app.closeEncryptionDetails()
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
