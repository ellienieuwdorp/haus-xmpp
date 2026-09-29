import Foundation
import CSQLite
import XMPPProtocol

/// v23: every stored account, chat, sender, actor, room and archive address in normal form (`JID`), so rows written
/// by builds that kept typed capitals meet the normalised keys every caller now uses. Stored rows are migrated once
/// rather than normalised on every read: SQL lookups compare exact text, and SQLite cannot case-fold beyond ASCII.
///
/// A row whose normal form collides with a row already in normal form is a spelling duplicate. Two chats merge into
/// one (messages move, the normal row keeps its settings and takes the other's pin, avatar and nickname if it has
/// none); a read pointer keeps the later of the two; ledgers, cursors and replay records keep the normal row. Messages,
/// their dependents and an encryption identity are never deleted: a colliding one stays under its old spelling (with
/// its chat), unreachable but intact.
///
/// Sealed blobs (encryption state, attachment secrets) use the account as associated data, and the store cannot
/// reseal them. A renamed row keeps the spelling it was sealed under in `sealed_account`; the reader opens with it and
/// the next save of the state reseals under the normal spelling. docs/development/jid-normalisation.md has the reasoning.
enum AddressMigration {
    private enum Duplicate { case keep, delete, mergeChat, keepLaterReadPointer }

    /// Tables in dependency order; a missing table or column (a branch that never created it) is skipped.
    private static let tables: [(name: String, columns: [String], duplicate: Duplicate)] = [
        ("chats", ["account_id", "id"], .mergeChat),
        ("messages", ["account_id", "chat_id", "sender_id"], .keep),
        ("outbox", ["account_id"], .keep),
        ("encryption_state", ["account_id"], .keep),
        ("encrypted_outbox", ["account_id"], .keep),
        ("encrypted_inbox", ["account_id", "sender"], .delete),
        ("pending_encrypted_inbox", ["account_id", "sender"], .delete),
        ("stream_management", ["account_id"], .delete),
        ("archive_checkpoints", ["account_id", "archive_id"], .delete),
        ("outgoing_updates", ["account_id", "chat_id"], .keep),
        ("message_events", ["account_id", "actor_id", "chat_id"], .delete),
        ("account_preferences", ["account_id"], .delete),
        ("notification_candidates", ["account_id"], .keep),
        ("group_message_references", ["account_id", "room"], .keep),
        ("group_ciphertext_messages", ["account_id", "sender"], .keep),
        ("archive_rejections", ["account_id", "archive_id"], .delete),
        ("attachments", ["account_id"], .keep),
        ("archive_backfill", ["account_id", "archive_id"], .delete),
        ("pending_notification_candidates", ["account_id", "sender", "chat_id"], .delete),
        ("chat_read_state", ["account_id", "chat_id"], .keepLaterReadPointer),
        ("read_baselines", ["account_id", "archive_id"], .delete),
        ("reaction_notification_candidates", ["account_id", "chat_id", "actor_id"], .keep),
        ("reaction_notifications_posted", ["account_id", "chat_id", "actor_id"], .keep),
    ]
    /// Tables whose blobs are sealed with the row's account as associated data.
    private static let sealed = ["attachments", "encryption_state"]

    static func normal(_ value: String) -> String { JID.normalized(value) ?? value }

    /// Outside the rewrite's savepoint, so the readers find the column even when the rewrite is rolled back.
    static func addSealedAccountColumns(_ connection: Connection) throws {
        for table in sealed where try !connection.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]).isEmpty
            && connection.query("SELECT 1 FROM pragma_table_info(?) WHERE name='sealed_account'", [.text(table)]).isEmpty {
            try connection.execute("ALTER TABLE \(table) ADD COLUMN sealed_account TEXT")
        }
    }

    /// Runs inside the schema transaction. All-or-nothing: a result that would add a foreign-key violation is rolled
    /// back and reported as false, and the store keeps its old spellings rather than failing to open.
    static func run(_ connection: Connection) throws -> Bool {
        try connection.defineAddressNormalizer()
        // Violations already present (unrelated to addresses) must not block the rewrite.
        let before = try violations(connection)
        try connection.execute("SAVEPOINT address_migration")
        do {
            // Chats are renamed before the messages that point at them.
            try connection.execute("PRAGMA defer_foreign_keys = ON")
            for table in tables { try migrate(table.name, table.columns, table.duplicate, connection) }
            // A chat merged into its normal spelling goes once no message (one kept under its old spelling) needs it.
            if let pending = try pendingCondition("chats", ["account_id", "id"], connection) {
                try connection.execute("""
                    DELETE FROM chats WHERE (\(pending))
                    AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.account_id=chats.account_id AND m.chat_id=chats.id)
                    """)
            }
            guard try violations(connection).isSubset(of: before) else {
                try connection.execute("ROLLBACK TO address_migration")
                try connection.execute("RELEASE address_migration")
                return false
            }
            try connection.execute("RELEASE address_migration")
            return true
        } catch {
            try? connection.execute("ROLLBACK TO address_migration")
            try? connection.execute("RELEASE address_migration")
            throw error
        }
    }

    private static func violations(_ connection: Connection) throws -> Set<String> {
        Set(try connection.query("PRAGMA foreign_key_check").map { row in
            row.map { $0.optionalString ?? String($0.integer) }.joined(separator: "|")
        })
    }

    private static func columns(_ table: String, _ wanted: [String], _ connection: Connection) throws -> [String] {
        let existing = Set(try connection.query("SELECT name FROM pragma_table_info(?)", [.text(table)]).map { $0[0].string })
        return wanted.filter(existing.contains)
    }

    /// Rows with a column not yet in normal form. The GLOB prefilter (an upper-case letter, a non-ASCII or control
    /// character, a trailing dot on the domain) keeps rows that are already normal away from the Swift normaliser.
    private static func pendingCondition(_ table: String, _ wanted: [String], _ connection: Connection) throws -> String? {
        let columns = try columns(table, wanted, connection)
        guard !columns.isEmpty else { return nil }
        return columns.map { column in
            "((\(column) GLOB '*[A-Z]*' OR \(column) GLOB '*[^ -~]*' OR \(column) GLOB '*.' OR \(column) GLOB '*./*') AND \(column) IS NOT jid_normal(\(column)))"
        }.joined(separator: " OR ")
    }

    private static func migrate(_ table: String, _ wanted: [String], _ duplicate: Duplicate, _ connection: Connection) throws {
        guard let pending = try pendingCondition(table, wanted, connection) else { return }
        let columns = try columns(table, wanted, connection)
        // One statement renames every row whose normal spelling is free; the rows left collide with a normal twin.
        var assignments = columns.map { "\($0)=jid_normal(\($0))" }
        if sealed.contains(table) { assignments.append("sealed_account=COALESCE(sealed_account,account_id)") }
        // A chat started by typing an address is titled with it; the title follows the address (SET reads old values).
        if table == "chats" { assignments.append("title=CASE WHEN title=id THEN jid_normal(id) ELSE title END") }
        try connection.execute("UPDATE OR IGNORE \(table) SET \(assignments.joined(separator: ",")) WHERE \(pending)")
        switch duplicate {
        case .keep: return
        case .delete: try connection.execute("DELETE FROM \(table) WHERE \(pending)"); return
        case .mergeChat, .keepLaterReadPointer: break
        }
        // Few rows (chats and read pointers), read in bounded pages all the same.
        let twin = columns.map { "\($0) IS ?" }.joined(separator: " AND ")
        var after = 0
        while true {
            let rows = try connection.query("SELECT rowid,\(columns.joined(separator: ",")) FROM \(table) WHERE (\(pending)) AND rowid>? ORDER BY rowid LIMIT 200",
                                            [.integer(after)])
            guard let last = rows.last else { return }
            after = last[0].integer
            for row in rows {
                let rowid = row[0]
                let twinValues = row.dropFirst().map { $0.optionalString.map { Value.text(normal($0)) } ?? .null }
                if duplicate == .mergeChat {
                    // The chat row itself goes at the end of `run`, once its messages have moved.
                    try connection.execute("""
                        UPDATE chats SET pinned=MAX(pinned,(SELECT pinned FROM chats WHERE rowid=?)),
                            avatar_hash=COALESCE(avatar_hash,(SELECT avatar_hash FROM chats WHERE rowid=?)),
                            room_nickname=COALESCE(room_nickname,(SELECT room_nickname FROM chats WHERE rowid=?))
                        WHERE \(twin)
                        """, [rowid, rowid, rowid] + twinValues)
                } else {
                    try connection.execute("""
                        UPDATE chat_read_state SET (read_sent_at,read_message_id,publish_pending,published_stanza_id)=
                            (SELECT read_sent_at,read_message_id,publish_pending,published_stanza_id FROM chat_read_state WHERE rowid=?)
                        WHERE \(twin) AND read_sent_at<(SELECT read_sent_at FROM chat_read_state WHERE rowid=?)
                        """, [rowid] + twinValues + [rowid])
                    try connection.execute("DELETE FROM chat_read_state WHERE rowid=?", [rowid])
                }
            }
        }
    }
}

extension Connection {
    /// `jid_normal(x)`: `x` in normal form (`JID`), or `x` unchanged when it is not text or not a valid address.
    func defineAddressNormalizer() throws {
        guard let handle else { throw MessageStoreError.closed }
        let result = sqlite3_create_function_v2(handle, "jid_normal", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, arguments in
            guard let argument = arguments?[0] else { sqlite3_result_null(context); return }
            guard sqlite3_value_type(argument) == SQLITE_TEXT, let bytes = sqlite3_value_text(argument) else {
                sqlite3_result_value(context, argument); return
            }
            let text = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_value_bytes(argument))), as: UTF8.self)
            let normal = AddressMigration.normal(text)
            normal.withCString { sqlite3_result_text(context, $0, Int32(normal.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }, nil, nil, nil)
        guard result == SQLITE_OK else { throw error(result) }
    }
}
