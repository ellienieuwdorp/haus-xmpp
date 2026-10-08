import XCTest

/// Two clients on the lab: opening a chat with the echo peer asks for its presence, slixmpp approves the
/// subscription on its own, and the header shows "Online". When the peer was started with `--timeout` and that
/// many seconds are in `XMPP_PEER_EXITS_AFTER`, its session ends during the test and the header changes to
/// "Last seen …" from the unavailable presence we watched. Requires `lastactivity` on the lab Prosody.
final class LastSeenLabUITests: XCTestCase {
    @MainActor func testHeaderShowsOnlineThenLastSeenWhenThePeerLeaves() throws {
        continueAfterFailure = false
        let started = Date()
        let lab = try LabFixture(orSkip: "Requires disposable local OMEMO echo peer")
        let app = lab.launch()
        app.buttons["Settings"].tap()
        // Sharing defaults on, next to the receipt switches.
        XCTAssertTrue(app.switches["lastSeen"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["lastSeen"].value as? String, "1")
        app.connectToLab()
        app.startChat(with: lab.peer)

        let header = app.buttons["chatDetails"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Online"), object: header)], timeout: 25)
        capture(app, "Peer online")

        // Leaving the foreground drops the socket without closing the stream, so coming back resumes the session
        // (XEP-0198). The server sends no probe answers on a resumed stream: the contact must still read "Online".
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        // An online contact must not read as gone after a resume.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Last seen"), object: header)
        gone.isInverted = true; wait(for: [gone], timeout: 15)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Online"), object: header)], timeout: 10)

        guard let exitsAfter = lab["XMPP_PEER_EXITS_AFTER"].flatMap(TimeInterval.init) else { return }
        let remaining = max(0, exitsAfter - Date().timeIntervalSince(started))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Last seen"), object: header)], timeout: remaining + 30)
        capture(app, "Peer last seen")
    }
}
