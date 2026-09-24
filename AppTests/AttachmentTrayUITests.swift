import XCTest

/// Sample chats accept files locally (nothing is uploaded), so the tray runs without the lab. Photos come from the
/// simulator's stock library through the system picker.
final class AttachmentTrayUITests: XCTestCase {
    private func openAlex() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        XCTAssertTrue(app.staticTexts["Alex"].waitForExistence(timeout: 15))
        app.staticTexts["Alex"].tap()
        return app
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["messageComposer"]
        return field.exists ? field : app.textViews["messageComposer"]
    }

    /// Photo bubbles in the timeline; the small receipt glyphs are images too, so size tells them apart.
    private func photoBubbles(in app: XCUIApplication) -> [XCUIElement] {
        app.collectionViews["conversation.timeline"].images.allElementsBoundByIndex.filter { $0.frame.height > 60 }
    }

    private func pickPhotos(_ count: Int, in app: XCUIApplication) {
        let attach = app.buttons["attachFile"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        attach.tap()
        app.buttons["Photo or Video"].tap()
        let grid = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 10), "The simulator's stock photos")
        // The picker runs out of process: its elements are visible but report not hittable, so tap their centres.
        let centre = CGVector(dx: 0.5, dy: 0.5)
        for index in 0..<count { grid.element(boundBy: index).coordinate(withNormalizedOffset: centre).tap() }
        app.buttons["Done"].coordinate(withNormalizedOffset: centre).tap()
        let removes = app.buttons.matching(identifier: "removeAttachment")
        let filled = NSPredicate { _, _ in removes.count == count }
        wait(for: [XCTNSPredicateExpectation(predicate: filled, object: nil)], timeout: 15)
    }

    @MainActor func testPickingFillsTheTrayAndSendsNothing() throws {
        let app = openAlex()
        XCTAssertTrue(app.collectionViews["conversation.timeline"].waitForExistence(timeout: 5))
        let before = photoBubbles(in: app).count
        pickPhotos(2, in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "removeAttachment").count, 2)
        XCTAssertTrue(app.staticTexts["2 attachments"].exists)
        XCTAssertEqual(composer(in: app).placeholderValue, "Add a caption…")
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled, "Files alone can be sent")
        sleep(1)
        XCTAssertEqual(photoBubbles(in: app).count, before, "Picking never sends")

        // The tray outlives the keyboard and a rotation, and is dropped when the chat is left.
        let removes = app.buttons.matching(identifier: "removeAttachment")
        composer(in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.collectionViews["conversation.timeline"].swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        XCTAssertEqual(removes.count, 2)
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        XCTAssertEqual(removes.count, 2)
        app.buttons["BackButton"].tap()
        app.staticTexts["Alex"].tap()
        XCTAssertTrue(app.buttons["attachFile"].waitForExistence(timeout: 5))
        XCTAssertEqual(removes.count, 0)
    }

    @MainActor func testRemovingFromTheTray() throws {
        let app = openAlex()
        pickPhotos(2, in: app)
        let removes = app.buttons.matching(identifier: "removeAttachment")
        XCTAssertGreaterThanOrEqual(removes.firstMatch.frame.width, 44)
        XCTAssertGreaterThanOrEqual(removes.firstMatch.frame.height, 44)
        removes.firstMatch.tap()
        XCTAssertEqual(removes.count, 1)
        XCTAssertFalse(app.staticTexts["2 attachments"].exists)
        removes.firstMatch.tap()
        XCTAssertTrue(removes.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(composer(in: app).placeholderValue, "Message")
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
    }

    /// Two photos and a caption become three messages: each photo on its own, the caption last and on its own.
    @MainActor func testTwoPhotosAndACaptionSendThreeMessagesCaptionLast() throws {
        let app = openAlex()
        XCTAssertTrue(app.collectionViews["conversation.timeline"].waitForExistence(timeout: 5))
        pickPhotos(2, in: app)
        let input = composer(in: app)
        input.tap()
        let caption = "Tray caption \(UUID().uuidString.prefix(6))"
        input.typeText(caption)
        app.buttons["sendMessage"].tap()
        let sent = app.textViews.containing(NSPredicate(format: "value == %@", caption)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertFalse(sent.label.contains("Photo"), "The caption travels without a file")
        // The keyboard is up, so only the newest cells are on screen: the two right above the caption are the photos.
        let cells = app.collectionViews["conversation.timeline"].cells
        let isPhoto = { (cell: XCUIElement) in cell.images.allElementsBoundByIndex.contains { $0.frame.height > 60 } }
        let ordered = NSPredicate { _, _ in
            let stack = cells.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
            guard let index = stack.firstIndex(where: { $0.frame.contains(CGPoint(x: sent.frame.midX, y: sent.frame.midY)) }), index >= 2 else { return false }
            return isPhoto(stack[index - 1]) && isPhoto(stack[index - 2]) && index == stack.count - 1
        }
        wait(for: [XCTNSPredicateExpectation(predicate: ordered, object: nil)], timeout: 10)
        XCTAssertFalse(app.buttons["removeAttachment"].exists, "The tray empties once everything is queued")
        XCTAssertTrue(["", "Message"].contains(input.value as? String ?? ""), "The caption left the composer")
    }
}
