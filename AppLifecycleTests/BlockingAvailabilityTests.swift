import XCTest
@testable import HausXMPP

/// Block, Report and Unblock run only against a server that blocks, while connected; otherwise they are shown disabled
/// with a reason, and the sample conversations block locally.
final class BlockingAvailabilityTests: XCTestCase {
    func testActionsNeedAConnectedServerThatBlocks() {
        let blocks = BlockingSupport(features: ["urn:xmpp:blocking", "urn:xmpp:mam:2"])
        let cases: [(signedIn: Bool, demo: Bool, ready: Bool, support: BlockingSupport, expected: BlockingAvailability, line: UInt)] = [
            (true, false, true, blocks, .available, #line),
            (true, false, false, blocks, .unavailable("Available when connected"), #line),
            // No discovery has completed yet: not known to block, so not offered as if it did.
            (true, false, true, BlockingSupport(features: nil), .unavailable("Available when connected"), #line),
            (true, false, true, BlockingSupport(features: ["urn:xmpp:mam:2"]), .unavailable("example.org doesn’t support blocking"), #line),
            (true, false, false, BlockingSupport(features: []), .unavailable("example.org doesn’t support blocking"), #line),
            (false, false, false, BlockingSupport(), .unavailable("Sign in to block"), #line),
            (true, true, false, BlockingSupport(), .available, #line),
        ]
        for c in cases {
            XCTAssertEqual(BlockingAvailability.evaluate(signedIn: c.signedIn, isDemo: c.demo, ready: c.ready, support: c.support, domain: "example.org"),
                           c.expected, line: c.line)
        }
        XCTAssertTrue(blocks.archive)
        XCTAssertFalse(blocks.reporting)
    }
}
