import UIKit
import XCTest
@testable import XMPPiOS

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
}
