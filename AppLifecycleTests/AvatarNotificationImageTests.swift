import XCTest
import CryptoKit
import ImageIO
import UIKit
@testable import HausXMPP

/// The communication-notification avatar: the app pre-scales a verified avatar once; the extension only reads bytes.
@MainActor final class AvatarNotificationImageTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "avatar-notification-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func png(side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func hash(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testLargeAvatarIsPreScaledToAtMost256PixelsAndReadBackAsBytes() throws {
        let root = try root(), account = "me@example.org"
        let data = png(side: 2_000), hash = hash(data)
        try AvatarStore.save(data, root: root, account: account, hash: hash)
        XCTAssertNil(AvatarStore.notificationImageData(root: root, account: account, hash: hash), "nothing until the app writes it")
        XCTAssertTrue(AvatarStore.saveNotificationImage(root: root, account: account, hash: hash))
        let bytes = try XCTUnwrap(AvatarStore.notificationImageData(root: root, account: account, hash: hash))
        XCTAssertLessThanOrEqual(bytes.count, AvatarStore.maximumNotificationImageBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 256)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 256)
        // Written once: a second call only checks that it exists.
        XCTAssertTrue(AvatarStore.saveNotificationImage(root: root, account: account, hash: hash))
    }

    func testNonHashNamesAndUndecodableAvatarsNeverProduceAFile() throws {
        let root = try root(), account = "me@example.org"
        XCTAssertFalse(AvatarStore.saveNotificationImage(root: root, account: account, hash: "../../secret"))
        XCTAssertNil(AvatarStore.notificationImageData(root: root, account: account, hash: "../messages.sqlite"))
        let junk = Data("not an image".utf8), junkHash = hash(junk)
        try AvatarStore.save(junk, root: root, account: account, hash: junkHash)
        XCTAssertFalse(AvatarStore.saveNotificationImage(root: root, account: account, hash: junkHash))
        XCTAssertNil(AvatarStore.notificationImageData(root: root, account: account, hash: junkHash))
    }
}
