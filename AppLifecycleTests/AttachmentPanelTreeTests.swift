import UIKit
import XCTest
@testable import HausXMPP

// The panel is presented in the keyboard window, whose screen differs from the app window's. A scroll view there
// builds its scroll edge pockets from the app window's bars, and converting a bar's rect across the two screens gives
// CGRectNull, which UIKit asserts on while it configures the pocket. So no scroll view may sit in the panel.
@MainActor final class AttachmentPanelTreeTests: XCTestCase {
    private func scrollViews(in view: UIView) -> [String] {
        (view is UIScrollView ? [String(describing: type(of: view))] : []) + view.subviews.flatMap(scrollViews(in:))
    }

    // Laid out as the warm-up lays it out: sized and laid out before it is the input view.
    private func panel(width: CGFloat, height: CGFloat, compact: Bool) -> AttachmentKeyboardView {
        let keyboard = AttachmentKeyboard()
        let panel = AttachmentKeyboardView(keyboard: keyboard)
        panel.prepare(height: height, compact: compact, safeArea: .zero)
        panel.frame = CGRect(x: 0, y: 0, width: width, height: height)
        panel.layoutIfNeeded()
        return panel
    }

    func testPhonePanelHoldsNoScrollView() {
        XCTAssertEqual(scrollViews(in: panel(width: 390, height: 335, compact: false)), [])
        XCTAssertEqual(scrollViews(in: panel(width: 844, height: 208, compact: true)), [])
    }

    func testTabletPanelHoldsNoScrollView() {
        XCTAssertEqual(scrollViews(in: panel(width: 1024, height: 422, compact: false)), [])
    }

    func testRailStillTakesDrags() throws {
        let panel = panel(width: 390, height: 335, compact: false)
        let rail = try XCTUnwrap(descendant(of: panel, identifier: "recentPhotos"))
        XCTAssertFalse(rail is UIScrollView, "The rail scrolls without being a scroll view")
        XCTAssertTrue(rail.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer } == true)
    }

    func testPhoneRailIsOneRowOfFullHeightSquares() {
        let geometry = RecentPhotosRailGeometry(size: CGSize(width: 390, height: 177))
        XCTAssertEqual(geometry.rows, 1)
        XCTAssertEqual(geometry.frame(of: 0), CGRect(x: 16, y: 0, width: 177, height: 177))
        XCTAssertEqual(geometry.frame(of: 2), CGRect(x: 16 + 2 * 189, y: 0, width: 177, height: 177))
        XCTAssertEqual(geometry.contentWidth(count: 3), 16 + 3 * 177 + 2 * 12 + 16)
        XCTAssertEqual(RecentPhotosRailGeometry(size: CGSize(width: 430, height: 177)).inset, 20)
    }

    func testTallRailFillsTwoRowsColumnByColumn() {
        let geometry = RecentPhotosRailGeometry(size: CGSize(width: 1024, height: 300))
        XCTAssertEqual(geometry.rows, 2)
        XCTAssertEqual(geometry.side, 144)
        XCTAssertEqual(geometry.frame(of: 1), CGRect(x: 20, y: 156, width: 144, height: 144))
        XCTAssertEqual(geometry.frame(of: 2), CGRect(x: 176, y: 0, width: 144, height: 144))
        XCTAssertEqual(geometry.contentWidth(count: 5), 20 + 3 * 144 + 2 * 12 + 20)
    }

    // Only the tiles that overlap the range are made, so a large library recycles a handful of views.
    func testVisibleItemsAreTheOverlappingColumns() {
        let phone = RecentPhotosRailGeometry(size: CGSize(width: 390, height: 177))
        XCTAssertEqual(phone.items(from: 0, to: 390, count: 96), 0..<2)
        XCTAssertEqual(phone.items(from: 16 + 177, to: 16 + 189 + 177, count: 96), 1..<2, "Edges that only touch do not count")
        XCTAssertEqual(phone.items(from: 20_000, to: 20_390, count: 96), 0..<0)
        XCTAssertEqual(phone.items(from: -500, to: 0, count: 96), 0..<0)
        let tablet = RecentPhotosRailGeometry(size: CGSize(width: 1024, height: 300))
        XCTAssertEqual(tablet.items(from: 0, to: 300, count: 5), 0..<4)
        XCTAssertEqual(tablet.items(from: 0, to: 1024, count: 5), 0..<5)
    }

    func testTapsFindTheTileUnderThemAndNothingInTheGaps() {
        let tablet = RecentPhotosRailGeometry(size: CGSize(width: 1024, height: 300))
        XCTAssertEqual(tablet.item(at: CGPoint(x: 30, y: 10), count: 5), 0)
        XCTAssertEqual(tablet.item(at: CGPoint(x: 30, y: 200), count: 5), 1)
        XCTAssertEqual(tablet.item(at: CGPoint(x: 200, y: 200), count: 5), 3)
        XCTAssertNil(tablet.item(at: CGPoint(x: 170, y: 10), count: 5), "The gap between columns")
        XCTAssertNil(tablet.item(at: CGPoint(x: 30, y: 150), count: 5), "The gap between rows")
        XCTAssertNil(tablet.item(at: CGPoint(x: 340, y: 200), count: 5), "Past the last photo")
        XCTAssertNil(tablet.item(at: CGPoint(x: 5, y: 10), count: 5), "The leading inset")
    }

    private func descendant(of view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        return view.subviews.lazy.compactMap { self.descendant(of: $0, identifier: identifier) }.first
    }
}
