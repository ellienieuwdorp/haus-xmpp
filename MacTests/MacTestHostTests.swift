import AppKit
import XCTest
@testable import HausXMPP

// The host app must never show itself or open an account: `MacTestHost` replaces the app delegate, which owns the
// model, the lifecycle driver and the main window.
@MainActor
final class MacTestHostTests: XCTestCase {
    func testTheHostRunsWithoutTheAppDelegateAWindowOrTheFocus() {
        XCTAssertTrue(MacTestHost.isHosting)
        XCTAssertFalse(NSApp.delegate is MacAppDelegate, "no model, lifecycle driver or main window")
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited, "no Dock icon, no menu bar, never active")
        XCTAssertFalse(NSApp.isActive)
        XCTAssertEqual(NSApp.windows.map { "\(type(of: $0)) \($0.title)" }, [])
    }
}
