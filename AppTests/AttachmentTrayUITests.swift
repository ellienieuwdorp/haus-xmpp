import XCTest

extension XCUIApplication {
    /// The attachment panel asks for the photo library on its first open; the rail needs full access.
    @MainActor func allowPhotoAccessIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        // The prompt comes once per install; after that the rail's first photo shows instead. Stop at whichever is first:
        // a fixed wait for a prompt that no longer comes cost every later open its whole timeout. The deadline is generous
        // because a prompt that shows after it is dismissed by the next tap, which denies the rail for the whole run.
        let railPhoto = descendants(matching: .any).matching(identifier: "recentPhoto-0").firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !allow.exists, !railPhoto.exists { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        if allow.exists { allow.tap() }
    }
}

/// Sample chats accept files locally (nothing is uploaded), so the tray runs without the lab. Photos come from the
/// simulator's stock library through the system picker, opened from the attachment panel's Photos chip.
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

    @MainActor private func pickPhotos(_ count: Int, in app: XCUIApplication) {
        let attach = app.buttons["attachFile"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        attach.tap()
        app.allowPhotoAccessIfAsked()
        let photos = app.buttons["attachPhotos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "The attachment panel's Photos chip")
        photos.tap()
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
