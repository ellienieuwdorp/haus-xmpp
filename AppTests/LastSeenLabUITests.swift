import XCTest

// Needs `lastactivity` on the lab Prosody; with `XMPP_PEER_EXITS_AFTER` the peer signs off mid-test.
final class LastSeenLabUITests: XCTestCase {
    @MainActor func testHeaderShowsOnlineThenLastSeenWhenThePeerLeaves() throws {
        continueAfterFailure = false
        let started = Date()
        let lab = try LabFixture(orSkip: "Requires disposable local OMEMO echo peer")
        let app = lab.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["lastSeen"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["lastSeen"].value as? String, "1")
        app.connectToLab()
        app.startChat(with: lab.peer)

        let header = app.buttons["chatDetails"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Online"), object: header)], timeout: 25)
        capture(app, "Peer online")

        // Coming back resumes the stream (XEP-0198), on which the server sends no probe answers.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Last seen"), object: header)
        gone.isInverted = true; wait(for: [gone], timeout: 15)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Online"), object: header)], timeout: 10)

        guard let exitsAfter = lab["XMPP_PEER_EXITS_AFTER"].flatMap(TimeInterval.init) else { return }
        let remaining = max(0, exitsAfter - Date().timeIntervalSince(started))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Last seen"), object: header)], timeout: remaining + 30)
        capture(app, "Peer last seen")
    }
}
