import XCTest
import XMPPProtocol
@testable import HausXMPP

// Disabled with a reason unless connected to a server that blocks; the sample conversations block locally.
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

    func testTheBlockedListPutsDatedBlocksFirstNewestFirst() throws {
        let suite = "haus.xmpp.tests.blockDates.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), account = "alice@example.org"
        let earlier = Date(timeIntervalSince1970: 1_800_000_000), later = earlier + 86_400
        let listed: Set<String> = ["zed@example.org", "bob@example.org", "spam.example", "carol@example.org"]
        BlockedAddresses.save(XMPPBlocklist(listed), accountID: account, defaults: defaults)
        BlockedAddresses.recordBlocked("Bob@Example.org", at: earlier, accountID: account, defaults: defaults)
        BlockedAddresses.recordBlocked("zed@example.org", at: later, accountID: account, defaults: defaults)
        BlockedAddresses.recordBlocked("unlisted@example.org", at: later, accountID: account, defaults: defaults)
        let dates = BlockedAddresses.blockDates(accountID: account, defaults: defaults)
        XCTAssertEqual(dates, ["bob@example.org": earlier, "zed@example.org": later])
        XCTAssertTrue(BlockedAddresses.blockDates(accountID: "bob@example.org", defaults: defaults).isEmpty)
        XCTAssertEqual(BlockedAddresses.ordered(BlockedAddresses.load(accountID: account, defaults: defaults).addresses, dates: dates),
                       ["zed@example.org", "bob@example.org", "carol@example.org", "spam.example"])

        // Unblocked elsewhere and blocked again elsewhere: the old date does not come back.
        BlockedAddresses.save(XMPPBlocklist(["bob@example.org", "spam.example"]), accountID: account, defaults: defaults)
        BlockedAddresses.save(XMPPBlocklist(["bob@example.org", "spam.example", "zed@example.org"]), accountID: account, defaults: defaults)
        XCTAssertEqual(BlockedAddresses.blockDates(accountID: account, defaults: defaults), ["bob@example.org": earlier])

        BlockedAddresses.forget(accountID: account, defaults: defaults)
        XCTAssertTrue(BlockedAddresses.blockDates(accountID: account, defaults: defaults).isEmpty)
    }
}
