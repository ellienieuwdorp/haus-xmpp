import XCTest
import SQLite3
import Foundation
import MessageStore
@testable import HausXMPP

// Sign-out's store rows stay owed until a lease holder deletes them: a sign-out without the lease, or cut short, is
// finished by the next lease this process takes. Both accounts start with one row in every table.
@MainActor final class SignOutCleanupTests: XCTestCase {
    private let alice = "alice@example.org", bob = "bob@example.org"
    private var deleted: [AccountTable] { AccountTable.allCases.filter { $0.policy.signOut == .delete } }

    private func seededStore() throws -> (MessageStore, URL, SignOutCleanup) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sign-out-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: url)
        let suite = "haus.xmpp.tests.sign-out.\(UUID().uuidString)"
        addTeardownBlock {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "account-tables", withExtension: "sql"))
        let sql = try String(contentsOf: fixture, encoding: .utf8)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        for account in [alice, bob] { XCTAssertEqual(sqlite3_exec(db, sql.replacingOccurrences(of: "{account}", with: account), nil, nil, nil), SQLITE_OK) }
        sqlite3_close(db)
        return (store, url, SignOutCleanup(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
    }

    private func count(_ url: URL, _ table: AccountTable, _ account: String) throws -> Int {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw MessageStoreError.closed }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \"\(table.rawValue)\" WHERE account_id='\(account)'", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw MessageStoreError.closed }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func testRowsStayWithoutTheLeaseAndGoUnderTheNextOne() async throws {
        let (store, url, cleanup) = try seededStore()
        XCTAssertFalse(deleted.isEmpty)
        cleanup.owe(alice)
        cleanup.owe(alice)
        XCTAssertEqual(cleanup.owed, [alice])

        let settledWithout = await cleanup.settle(store: store)
        XCTAssertFalse(settledWithout, "without the lease nothing is deleted")
        XCTAssertEqual(cleanup.owed, [alice], "and the rows stay owed")
        for table in deleted { XCTAssertEqual(try count(url, table, alice), 1, table.rawValue) }

        try await store.acquireTransportOwnership()
        let settled = await cleanup.settle(store: store)
        XCTAssertTrue(settled)
        XCTAssertEqual(cleanup.owed, [])
        for table in AccountTable.allCases {
            XCTAssertEqual(try count(url, table, alice), table.policy.signOut == .delete ? 0 : 1, table.rawValue)
            XCTAssertEqual(try count(url, table, bob), 1, "\(table.rawValue): another account's rows stay")
        }
    }

    // Signing out of one account and into another: what the first still owed goes once the second's connection takes
    // the lease another process held, and the second account's rows stay.
    func testAnAccountSwitchSettlesWhatTheEarlierSignOutOwed() async throws {
        let (store, url, cleanup) = try seededStore()
        let extensionRun = try MessageStore(url: url)
        try await extensionRun.acquireTransportOwnership()
        cleanup.owe(alice)
        do {
            try await store.acquireTransportOwnership()
            XCTFail("the extension holds the lease")
        } catch { XCTAssertEqual(error as? MessageStoreError, .transportOwnedElsewhere) }
        let settledWhileHeld = await cleanup.settle(store: store)
        XCTAssertFalse(settledWhileHeld)

        try await extensionRun.close()
        try await store.acquireTransportOwnership()
        let settled = await cleanup.settle(store: store)
        XCTAssertTrue(settled)
        for table in deleted {
            XCTAssertEqual(try count(url, table, alice), 0, table.rawValue)
            XCTAssertEqual(try count(url, table, bob), 1, table.rawValue)
        }
    }

    // Sign-out could not take the lease, and an extension run posted after its first clear. The next connection's
    // settle deletes the rows and clears the notifications again; a settle that deleted nothing leaves them.
    func testTheSettleBeforeASessionClearsNotificationsOnceItDeletedRows() async throws {
        let (store, url, seeded) = try seededStore()
        var cleanup = seeded, cleared = 0
        cleanup.clearNotifications = { cleared += 1 }
        cleanup.owe(alice)
        let withoutLease = await cleanup.settle(store: store, connecting: alice)
        XCTAssertFalse(withoutLease)
        XCTAssertEqual(cleared, 0, "nothing was deleted, so nothing is cleared")

        try await store.acquireTransportOwnership()
        let connects = await cleanup.settle(store: store, connecting: alice)
        XCTAssertTrue(connects)
        XCTAssertEqual(cleared, 1)
        for table in deleted { XCTAssertEqual(try count(url, table, alice), 0, table.rawValue) }

        let nothingOwed = await cleanup.settle(store: store, connecting: bob)
        XCTAssertTrue(nothingOwed)
        XCTAssertEqual(cleared, 1, "with nothing owed a connection leaves the notifications")
        try await store.close()
        cleanup.owe(bob)
        let closed = await cleanup.settle(store: store, connecting: alice)
        XCTAssertTrue(closed, "alice is no longer owed")
        XCTAssertEqual(cleared, 1, "bob's failed delete clears nothing")
    }

    // One account's delete keeps failing: it stays owed and is refused a session, while another account connects.
    func testAnotherAccountsFailingDeleteNeverBlocksThisOne() async throws {
        let (store, url, cleanup) = try seededStore()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TRIGGER keep_alice BEFORE DELETE ON notification_candidates WHEN old.account_id='\(alice)' BEGIN SELECT RAISE(ABORT,'kept'); END;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        try await store.acquireTransportOwnership()
        cleanup.owe(alice)
        cleanup.owe(bob)

        let bobConnects = await cleanup.settle(store: store, connecting: bob)
        XCTAssertTrue(bobConnects, "alice's failure does not block bob")
        XCTAssertEqual(cleanup.owed, [alice])
        for table in deleted {
            XCTAssertEqual(try count(url, table, bob), 0, table.rawValue)
            XCTAssertEqual(try count(url, table, alice), 1, "\(table.rawValue): alice's delete rolled back")
        }
        let aliceConnects = await cleanup.settle(store: store, connecting: alice)
        XCTAssertFalse(aliceConnects, "alice is still owed, so she gets no session")
        let unrelated = await cleanup.settle(store: store, connecting: "carol@example.org")
        XCTAssertTrue(unrelated)
        XCTAssertEqual(AppModel.failureMessage(for: SignOutCleanup.Owed()), "Couldn’t finish signing out this account. Try again.")
    }

    // What the next session writes after the owed rows went is its own: later settles leave it.
    func testRowsWrittenAfterASettleSurviveLaterSettles() async throws {
        let (store, url, cleanup) = try seededStore()
        try await store.acquireTransportOwnership()
        cleanup.owe(alice)
        let settled = await cleanup.settle(store: store)
        XCTAssertTrue(settled)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO notification_candidates(account_id,message_id) VALUES('\(alice)','m1');
            INSERT INTO reaction_notification_candidates(account_id,chat_id,actor_id,target_message_id,reactions_json,reacted_at)
            VALUES('\(alice)','peer@example.org','peer@example.org','m1','[]',1790000100);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        for _ in 0..<2 {
            let again = await cleanup.settle(store: store)
            XCTAssertTrue(again)
        }
        XCTAssertEqual(try count(url, .notificationCandidates, alice), 1)
        XCTAssertEqual(try count(url, .reactionNotificationCandidates, alice), 1)
    }

    // A failed settle is what makes the next connection refuse the owed account a session.
    func testAClosedStoreKeepsTheRowsOwedAndSaysWhy() async throws {
        let (store, url, cleanup) = try seededStore()
        cleanup.owe(alice)
        try await store.close()
        let settled = await cleanup.settle(store: store)
        XCTAssertFalse(settled)
        XCTAssertEqual(cleanup.owed, [alice])
        for table in deleted { XCTAssertEqual(try count(url, table, alice), 1, table.rawValue) }
        XCTAssertEqual(SignOutCleanup.reason(MessageStoreError.closed), "store closed")
        XCTAssertEqual(SignOutCleanup.reason(MessageStoreError.replaced), "store replaced")
        XCTAssertEqual(SignOutCleanup.reason(MessageStoreError.transportOwnershipRequired), "no lease")
    }
}
