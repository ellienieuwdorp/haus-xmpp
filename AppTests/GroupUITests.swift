import XCTest

final class GroupUITests: XCTestCase {
    @MainActor func testJoinReviewEncryptedGroupAndReaction() throws {
        continueAfterFailure = false
        let lab = try LabFixture(requiring: ["XMPP_GROUP_ROOM"], orSkip: "Requires disposable local encrypted group fixture")
        let room = lab["XMPP_GROUP_ROOM"]!
        let app = lab.launch()
        app.connectToLab()
        app.returnToChats(); app.buttons["newConversation"].tap()
        XCTAssertTrue(app.buttons["newGroup"].waitForExistence(timeout: 5)); app.buttons["newGroup"].tap()
        XCTAssertTrue(app.textFields["groupAddress"].waitForExistence(timeout: 5))
        capture(app, "Group invitation form")
        app.textFields["groupAddress"].tap(); app.textFields["groupAddress"].typeText(room)
        app.buttons["joinGroup"].tap()
        let composer = app.textFields["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 25))
        let marker = "Synthetic group hello \(UUID().uuidString.prefix(6))"
        composer.tap(); composer.typeText(marker)
        let send = app.buttons["sendMessage"]
        let joined = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        wait(for: [joined], timeout: 15)
        send.tap()
        let bubbles = app.textViews.containing(NSPredicate(format: "value == %@", marker))
        XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 5))
        app.openEncryptionDetails()
        XCTAssertTrue(app.navigationBars["Group details"].waitForExistence(timeout: 10))
        capture(app, "Group members awaiting device review")
        app.acceptPendingDevices(group: true) { capture(app, "Group fingerprint review") }
        app.closeEncryptionDetails()
        let echoed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: bubbles)
        wait(for: [echoed], timeout: 35)
        capture(app, "Authenticated group conversation")
        let incoming = bubbles.matching(NSPredicate(format: "label BEGINSWITH %@", lab["XMPP_OMEMO_PEER"] ?? "omemo-")).firstMatch
        XCTAssertTrue(incoming.exists, "Group bubble identifies its authenticated real sender")
        incoming.press(forDuration: 1)
        let reaction = app.buttons["👍"]
        XCTAssertTrue(reaction.waitForExistence(timeout: 5)); reaction.tap()
        let reacted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "2 thumbs up reactions"), object: incoming)
        wait(for: [reacted], timeout: 25)
        capture(app, "Encrypted group reactions")
        XCTAssertEqual(bubbles.count, 2, "Reactions must not create extra chat messages")
        app.terminate(); app.launch()
        app.connectToLab()
        app.returnToChats()
        let restored = app.buttons["chat.\(room)"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10)); restored.tap()
        XCTAssertEqual(bubbles.count, 2, "Archive catch-up must not duplicate authenticated messages")
        let resumedMarker = marker + " after reconnect"
        composer.tap(); composer.typeText(resumedMarker)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)], timeout: 15)
        send.tap()
        let resumedBubbles = app.textViews.containing(NSPredicate(format: "value == %@", resumedMarker))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: resumedBubbles)], timeout: 30)
        capture(app, "Restored group membership and history")
    }
}
