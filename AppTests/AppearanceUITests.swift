import XCTest

/// A theme change made inside the Settings sheet repaints that sheet while it stays open.
/// Colour is read from screenshot pixels: the "on" switch track is filled with the tint.
final class AppearanceUITests: XCTestCase {
    @MainActor func testAccentAndSchemeChangeRepaintTheOpenSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The argument domain pins the starting state even if an earlier run stopped midway.
        app.launchArguments = ["-demo", "-accentTheme", "indigo", "-appearanceMode", "automatic"]
        app.isolateMessageStorage()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()

        let row = app.buttons["appearanceRow"]
        let done = app.buttons["Done"]
        let receipts = app.switches["deliveryReceipts"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Indigo"), row.label)
        let start = sample(app, receipts)
        XCTAssertGreaterThan(start.track.blue, start.track.red, "indigo switch track: \(start.track)")
        attach(app, "Settings before, Indigo")
        let lightBackground = start.background

        row.tap()
        let crab = app.buttons["Crab"]
        XCTAssertTrue(crab.waitForExistence(timeout: 5))
        crab.tap()
        XCTAssertTrue(crab.wait(for: \.isSelected, toEqual: true, timeout: 2))
        attach(app, "Appearance after Crab")
        app.buttons["Dark"].tap()
        attach(app, "Appearance after Dark")
        back(app)

        XCTAssertTrue(done.waitForExistence(timeout: 5), "the sheet is still open")
        XCTAssertTrue(row.wait(for: \.label, toEqual: "Appearance, Crab", timeout: 2), row.label)
        let changed = sample(app, receipts)
        XCTAssertGreaterThan(changed.track.red, changed.track.blue + 0.2, "crab switch track: \(changed.track)")
        XCTAssertLessThan(changed.background.luminance, 0.25, "dark sheet background: \(changed.background)")
        attach(app, "Settings after Crab and Dark, sheet still open")

        // Back to the defaults, which also covers Dark to Automatic with the sheet open.
        row.tap()
        XCTAssertTrue(app.buttons["Indigo"].waitForExistence(timeout: 5))
        app.buttons["Indigo"].tap()
        app.buttons["Automatic"].tap()
        attach(app, "Appearance after Indigo and Automatic")
        back(app)
        XCTAssertTrue(row.wait(for: \.label, toEqual: "Appearance, Indigo", timeout: 2), row.label)
        let reset = sample(app, receipts)
        XCTAssertGreaterThan(reset.track.blue, reset.track.red, "indigo switch track: \(reset.track)")
        XCTAssertEqual(reset.background.luminance, lightBackground.luminance, accuracy: 0.1,
                       "the sheet follows the system again: \(reset.background)")
        attach(app, "Settings after reset")
        done.tap()
    }

    private func back(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        // Let the colour change and any push finish before capturing.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// The switch's track just inside its leading edge, and the sheet's grouped background beside it.
    private func sample(_ app: XCUIApplication, _ toggle: XCUIElement) -> (track: RGB, background: RGB) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        let image = app.screenshot().image
        let frame = toggle.frame
        // The switch element spans the row; left of the "on" knob, about 70pt in from the row end, is track.
        let track = CGPoint(x: frame.maxX - 70, y: frame.midY)
        let background = CGPoint(x: 6, y: frame.midY)
        return (RGB(image, at: track), RGB(image, at: background))
    }
}

private struct RGB: CustomStringConvertible {
    let red: CGFloat, green: CGFloat, blue: CGFloat
    var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    var description: String { String(format: "rgb(%.2f, %.2f, %.2f)", red, green, blue) }

    init(_ image: UIImage, at point: CGPoint) {
        let cg = image.cgImage!
        let scale = CGFloat(cg.width) / image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        red = CGFloat(pixel[0]) / 255
        green = CGFloat(pixel[1]) / 255
        blue = CGFloat(pixel[2]) / 255
    }
}
