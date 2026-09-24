import UIKit
import XCTest
@testable import HausXMPP

final class MessageStatusGlyphTests: XCTestCase {
    private typealias Status = TimelineMessage.Status

    func testEveryStatusMapsToItsMark() {
        let expected: [(Status, MessageStatusGlyph)] = [
            (.queued, .sending(spinning: true)),
            (.submitting, .sending(spinning: true)),
            (.unconfirmed, .sending(spinning: false)),
            (.failed, .failed),
            (.serverAccepted, .sent),
            (.delivered, .delivered),
            (.displayed, .read),
        ]
        XCTAssertEqual(Set(expected.map(\.0.rawValue)).count, 7, "one row per status")
        for (status, glyph) in expected {
            XCTAssertEqual(MessageStatusGlyph.glyph(for: status), glyph, status.rawValue)
        }
    }

    /// A socket write is not delivery: nothing short of server acceptance may show a check.
    func testOnlyServerHeldMessagesShowACheck() {
        for status in [Status.queued, .submitting, .unconfirmed, .failed] {
            XCTAssertFalse(MessageStatusGlyph.glyph(for: status).showsCheck, status.rawValue)
        }
        for status in [Status.serverAccepted, .delivered, .displayed] {
            XCTAssertTrue(MessageStatusGlyph.glyph(for: status).showsCheck, status.rawValue)
        }
    }

    func testAccessibilityDescriptionsAreSentences() {
        XCTAssertEqual(Status.serverAccepted.accessibilityDescription, "Sent")
        XCTAssertEqual(Status.delivered.accessibilityDescription, "Delivered")
        XCTAssertEqual(Status.displayed.accessibilityDescription, "Read")
        XCTAssertEqual(Status.unconfirmed.accessibilityDescription, "Sending, not yet confirmed")
    }

    /// Single rings are 12 x 12, double rings fill the 18 pt slot, and all scale together.
    func testImagesKeepTheirSlotGeometryAndAreTemplates() {
        let glyphs: [MessageStatusGlyph] = [.sending(spinning: true), .sent, .delivered, .read, .failed]
        for scale in [CGFloat(1), 1.5] {
            for glyph in glyphs {
                let image = MessageStatusArt.image(glyph, scale: scale)
                let wide = glyph == .delivered || glyph == .read
                XCTAssertEqual(image.size.width, (wide ? 18 : 12) * scale, accuracy: 0.01, "\(glyph)")
                XCTAssertEqual(image.size.height, 12 * scale, accuracy: 0.01, "\(glyph)")
                XCTAssertEqual(image.renderingMode, .alwaysTemplate, "\(glyph)")
            }
        }
    }

    /// Failed is a filled disc with the exclamation knocked out, so it reads by shape in the neutral meta colour.
    func testFailedMarkIsAFilledDiscWithAKnockedOutExclamation() throws {
        let image = MessageStatusArt.image(.failed, scale: 2)
        let alpha = try XCTUnwrap(AlphaSampler(image, designWidth: MessageStatusArt.designWidth(.failed)))
        XCTAssertGreaterThan(alpha.at(x: 3, y: 6), 0.9, "disc body left of the mark")
        XCTAssertGreaterThan(alpha.at(x: 9, y: 6), 0.9, "disc body right of the mark")
        XCTAssertLessThan(alpha.at(x: 6, y: 4.5), 0.1, "exclamation bar is a hole")
        XCTAssertLessThan(alpha.at(x: 6, y: 8.9), 0.1, "exclamation dot is a hole")
        XCTAssertGreaterThan(alpha.at(x: 6, y: 7.7), 0.9, "disc between the bar and the dot")
        XCTAssertLessThan(alpha.at(x: 0.3, y: 0.3), 0.1, "corner outside the disc")
    }
}

/// Reads alpha at design-size points from a status mark.
private struct AlphaSampler {
    let width: Int, height: Int, pixelsPerPoint: CGFloat
    let bytes: [UInt8]

    init?(_ image: UIImage, designWidth: CGFloat) {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        pixelsPerPoint = CGFloat(w) / designWidth
        bytes = buffer
    }

    /// `x`, `y` in design points from the top left.
    func at(x: CGFloat, y: CGFloat) -> CGFloat {
        let px = min(width - 1, Int(x * pixelsPerPoint)), py = min(height - 1, Int(y * pixelsPerPoint))
        return CGFloat(bytes[(py * width + px) * 4 + 3]) / 255
    }
}
