import Foundation
import XMPPProtocol

/// v23: every stored account, chat, sender, actor, room and archive address in normal form (`JID`), so rows written
/// by builds that kept typed capitals meet the normalised keys every caller now uses. Stored rows are migrated once
/// rather than normalised on every read: SQL lookups compare exact text, and SQLite cannot case-fold beyond ASCII.
///
/// A row whose normal form collides with a row already in normal form is a spelling duplicate. Two chats merge into
/// one (messages move, the normal row keeps its settings and takes the other's pin, avatar and nickname if it has
/// none); a read pointer keeps the later of the two; ledgers, cursors and replay records keep the normal row. Messages,
/// their dependents and an encryption identity are never deleted: a colliding one stays under its old spelling,
/// unreachable but intact. Sealed blobs (encryption state, stream-management snapshot) are not rewritten here; their
/// readers compare in normal form. docs/development/jid-normalisation.md has the reasoning.
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

    static func normal(_ value: String) -> String { JID.normalized(value) ?? value }

    /// Runs inside the schema transaction. All-or-nothing: a result that would break a foreign key is rolled back and
    /// the store keeps its old spellings rather than failing to open.
    static func run(_ connection: Connection) throws {
        try connection.execute("SAVEPOINT address_migration")
        do {
            // Chats are renamed before the messages that point at them.
            try connection.execute("PRAGMA defer_foreign_keys = ON")
            for table in tables { try migrate(table.name, table.columns, table.duplicate, connection) }
            guard try connection.query("PRAGMA foreign_key_check").isEmpty else {
                try connection.execute("ROLLBACK TO address_migration")
                try connection.execute("RELEASE address_migration")
                return
            }
            try connection.execute("RELEASE address_migration")
        } catch {
            try? connection.execute("ROLLBACK TO address_migration")
            try? connection.execute("RELEASE address_migration")
            throw error
        }
    }

    private static func migrate(_ table: String, _ wanted: [String], _ duplicate: Duplicate, _ connection: Connection) throws {
        let existing = Set(try connection.query("SELECT name FROM pragma_table_info(?)", [.text(table)]).map { $0[0].string })
        let columns = wanted.filter(existing.contains)
        guard !columns.isEmpty else { return }
        let list = columns.joined(separator: ",")
        for row in try connection.query("SELECT rowid,\(list) FROM \(table)") {
            let values = row.dropFirst().map(\.optionalString)
            let normalized = values.map { $0.map(normal) }
            guard normalized != values else { continue }
            let rowid = row[0]
            let assignments = columns.map { "\($0)=?" }.joined(separator: ",")
            try connection.execute("UPDATE OR IGNORE \(table) SET \(assignments) WHERE rowid=?",
                                   normalized.map { $0.map(Value.text) ?? .null } + [rowid])
            guard try connection.query("SELECT changes()").first?[0].integer == 0 else { continue }
            // The normal spelling already has this row.
            let twin = zip(columns, normalized).map { "\($0.0) IS ?" }.joined(separator: " AND ")
            let twinValues = normalized.map { $0.map(Value.text) ?? .null }
            switch duplicate {
            case .keep: continue
            case .delete: break
            case .mergeChat:
                try connection.execute("""
                    UPDATE chats SET pinned=MAX(pinned,(SELECT pinned FROM chats WHERE rowid=?)),
                        avatar_hash=COALESCE(avatar_hash,(SELECT avatar_hash FROM chats WHERE rowid=?)),
                        room_nickname=COALESCE(room_nickname,(SELECT room_nickname FROM chats WHERE rowid=?))
                    WHERE \(twin)
                    """, [rowid, rowid, rowid] + twinValues)
            case .keepLaterReadPointer:
                try connection.execute("""
                    UPDATE chat_read_state SET (read_sent_at,read_message_id,publish_pending,published_stanza_id)=
                        (SELECT read_sent_at,read_message_id,publish_pending,published_stanza_id FROM chat_read_state WHERE rowid=?)
                    WHERE \(twin) AND read_sent_at<(SELECT read_sent_at FROM chat_read_state WHERE rowid=?)
                    """, [rowid] + twinValues + [rowid])
            }
            try connection.execute("DELETE FROM \(table) WHERE rowid=?", [rowid])
        }
    }
}
