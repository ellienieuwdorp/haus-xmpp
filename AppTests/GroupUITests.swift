import XCTest

final class GroupUITests: XCTestCase {
    @MainActor func testJoinReviewEncryptedGroupAndReaction() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let user = environment["XMPP_LAB_USERNAME"], let password = environment["XMPP_LAB_PASSWORD"],
              let room = environment["XMPP_GROUP_ROOM"] else { throw XCTSkip("Requires disposable local encrypted group fixture") }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["XMPP_LAB_USERNAME": user, "XMPP_LAB_PASSWORD": password]
        app.isolateMessageStorage()
        app.launch()
        connect(app)
        app.buttons["Chats"].tap(); app.buttons["newConversation"].tap()
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
        app.buttons["encryptionDetails"].tap()
        XCTAssertTrue(app.navigationBars["Group details"].waitForExistence(timeout: 10))
        capture(app, "Group members awaiting device review")
        let devices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "groupDevice."))
        XCTAssertTrue(devices.firstMatch.waitForExistence(timeout: 10))
        var emptyReviewScreens = 0
        for _ in 0..<40 {
            let pending = devices.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
            if !pending.exists {
                emptyReviewScreens += 1
                if emptyReviewScreens == 3 { break }
                app.swipeUp()
                continue
            }
            emptyReviewScreens = 0
            pending.tap()
            XCTAssertTrue(app.buttons["Accept without verifying"].waitForExistence(timeout: 5))
            capture(app, "Group fingerprint review")
            app.buttons["Accept without verifying"].tap()
            XCTAssertTrue(app.navigationBars["Group details"].waitForExistence(timeout: 15))
        }
        app.buttons["Done"].tap()
        let echoed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: bubbles)
        wait(for: [echoed], timeout: 35)
        capture(app, "Authenticated group conversation")
        let incoming = bubbles.matching(NSPredicate(format: "label BEGINSWITH %@", environment["XMPP_OMEMO_PEER"] ?? "omemo-")).firstMatch
        XCTAssertTrue(incoming.exists, "Group bubble identifies its authenticated real sender")
        incoming.press(forDuration: 1)
        XCTAssertTrue(app.buttons["React"].waitForExistence(timeout: 5)); app.buttons["React"].tap()
        let reaction = app.buttons["👍"]
        XCTAssertTrue(reaction.waitForExistence(timeout: 5)); reaction.tap()
        let reacted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "2 thumbs up reactions"), object: incoming)
        wait(for: [reacted], timeout: 25)
        capture(app, "Encrypted group reactions")
        XCTAssertEqual(bubbles.count, 2, "Reactions must not create extra chat messages")
        app.terminate(); app.launch()
        connect(app)
        app.buttons["Chats"].tap()
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

    @MainActor private func connect(_ app: XCUIApplication) {
        app.buttons["Settings"].tap(); app.buttons["Connect to local lab"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Connect"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected to lab")).firstMatch.waitForExistence(timeout: 30))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
