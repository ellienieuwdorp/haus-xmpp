import XCTest
@testable import HausXMPP

final class NotificationAccessGateTests: XCTestCase {
    func testLogoutTombstoneSurvivesReopenAndRequiresExplicitEnable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "disabled")
        XCTAssertFalse(try NotificationAccessGate.isDisabled(at: url))
        try NotificationAccessGate.disable(at: url)
        XCTAssertTrue(try NotificationAccessGate.isDisabled(at: URL(fileURLWithPath: url.path)))
        try Data().write(to: url) // Even an empty marker must not reauthorize credentials.
        XCTAssertTrue(try NotificationAccessGate.isDisabled(at: url))
        try NotificationAccessGate.enable(at: url)
        XCTAssertFalse(try NotificationAccessGate.isDisabled(at: url))
        try NotificationAccessGate.enable(at: url)
    }

    func testUnreadableGateFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try NotificationAccessGate.isDisabled(at: root))
    }
}
