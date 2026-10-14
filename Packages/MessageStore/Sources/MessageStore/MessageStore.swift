import Foundation
import CSQLite
import Darwin

/// Protected-directory SQLite persistence. The caller validates authenticated transport identities.
/// Crypto writes use revision CAS; socket work additionally requires exclusive OS ownership.
public actor MessageStore {
    private let connection: Connection
    private let transportOwnership: TransportOwnership

    /// The schema this build writes.
    public static let currentSchemaVersion = 26

    /// How opening treats a file written by an older build.
    public enum SchemaAccess: Sendable {
        /// Bring it to the current schema (or create it) while opening.
        case upgrade
        /// Refuse an older schema with `upgradeRequired` before writing anything: for processes that must never
        /// migrate (the notification extension). The file must already exist.
        case currentOnly
        /// Open the file as it is and write nothing. The owner takes the transport lease and then either copies it
        /// (`writeSnapshot`), moves it (`closeForMigration`) or migrates it (`upgradeSchema`). The file must exist.
        case asIs
    }

    /// `user_version` when this store was opened, before any migration it ran.
    public nonisolated let openedSchemaVersion: Int
    private let url: URL
    /// The database file this connection opened; a lease is never granted over a file replaced since.
    private let fileIdentity: FileIdentity

    public init(url: URL) throws { try self.init(url: url, schema: .upgrade) }

    public init(url: URL, schema access: SchemaAccess) throws {
        transportOwnership = try TransportOwnership(url: url)
        connection = try Connection(url: url, create: access == .upgrade)
        self.url = url
        guard let identity = FileIdentity(path: url.path) else { throw MessageStoreError.closed }
        fileIdentity = identity
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA synchronous = FULL")
        let version = try connection.query("PRAGMA user_version").first?[0].integer ?? 0
        openedSchemaVersion = version
        guard version <= Self.currentSchemaVersion else { throw MessageStoreError.unsupportedSchema(version) }
        switch access {
        case .upgrade: try Self.migrate(connection)
        case .currentOnly: guard version == Self.currentSchemaVersion else { throw MessageStoreError.upgradeRequired(version) }
        case .asIs: break
        }
    }

    /// Migrates a store opened `asIs` to the current schema. Holding the lease keeps every other process (which opens
    /// `currentOnly` or waits for the lease) away from the file while it changes.
    public func upgradeSchema() throws {
        try requireTransportOwnership()
        try Self.migrate(connection)
    }

    private static func migrate(_ connection: Connection) throws {
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.transaction {
            let version = try connection.query("PRAGMA user_version").first?[0].integer ?? 0
            guard version <= currentSchemaVersion else { throw MessageStoreError.unsupportedSchema(version) }
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS chats (
                    account_id TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(account_id, id)
                )
                """)
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS messages (
                    account_id TEXT NOT NULL, id TEXT NOT NULL, chat_id TEXT NOT NULL,
                    sender_id TEXT NOT NULL, body TEXT NOT NULL, sent_at REAL NOT NULL,
                    outgoing INTEGER NOT NULL, starred INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(account_id, id),
                    FOREIGN KEY(account_id, chat_id) REFERENCES chats(account_id, id)
                )
                """)
            try connection.execute("CREATE INDEX IF NOT EXISTS timeline ON messages(account_id, chat_id, sent_at, id)")
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS outbox (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id TEXT NOT NULL, message_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('queued','submitting','unconfirmed','failed')),
                    attempt_id TEXT,
                    UNIQUE(account_id, message_id),
                    FOREIGN KEY(account_id, message_id) REFERENCES messages(account_id, id)
                )
                """)
            try connection.execute("CREATE INDEX IF NOT EXISTS outbox_queue ON outbox(account_id,state,sequence)")
            if version < 3 {
                try connection.execute("ALTER TABLE messages ADD COLUMN reply_json TEXT")
            }
            if version < 4 {
                try connection.execute("ALTER TABLE messages ADD COLUMN encryption_profile TEXT")
            }
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS encryption_state (
                    account_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, snapshot BLOB NOT NULL
                )
                """)
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS encrypted_outbox (
                    account_id TEXT NOT NULL, message_id TEXT NOT NULL, wire BLOB NOT NULL,
                    PRIMARY KEY(account_id,message_id),
                    FOREIGN KEY(account_id,message_id) REFERENCES messages(account_id,id)
                )
                """)
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS encrypted_inbox (
                    account_id TEXT NOT NULL, sender TEXT NOT NULL, digest TEXT NOT NULL,
                    PRIMARY KEY(account_id,sender,digest)
                )
                """)
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS pending_encrypted_inbox (
                    account_id TEXT NOT NULL, sender TEXT NOT NULL, digest TEXT NOT NULL, wire BLOB NOT NULL,
                    PRIMARY KEY(account_id,sender,digest)
                )
                """)
            if version < 5 {
                // SQLite cannot alter CHECK constraints. Rebuild only the outbox, preserving FIFO/tokens.
                try connection.execute("ALTER TABLE outbox RENAME TO outbox_v4")
                try connection.execute("""
                    CREATE TABLE outbox (
                        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                        account_id TEXT NOT NULL, message_id TEXT NOT NULL,
                        state TEXT NOT NULL CHECK(state IN ('queued','submitting','unconfirmed','failed','serverAccepted')),
                        attempt_id TEXT, UNIQUE(account_id,message_id),
                        FOREIGN KEY(account_id,message_id) REFERENCES messages(account_id,id)
                    )
                    """)
                try connection.execute("INSERT INTO outbox SELECT * FROM outbox_v4")
                try connection.execute("DROP TABLE outbox_v4")
                try connection.execute("CREATE INDEX outbox_queue ON outbox(account_id,state,sequence)")
            }
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS stream_management (
                    account_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, snapshot BLOB NOT NULL
                )
                """)
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS archive_checkpoints (
                    account_id TEXT NOT NULL, archive_id TEXT NOT NULL, revision INTEGER NOT NULL, cursor TEXT NOT NULL,
                    PRIMARY KEY(account_id,archive_id)
                )
                """)
            if version < 6 {
                try connection.execute("ALTER TABLE messages ADD COLUMN wire_id TEXT")
                try connection.execute("ALTER TABLE messages ADD COLUMN wire_id_authenticated INTEGER NOT NULL DEFAULT 0")
            }
            try connection.execute("CREATE INDEX IF NOT EXISTS authenticated_message_wire ON messages(account_id,chat_id,wire_id) WHERE wire_id_authenticated=1")
            if version < 9 {
                // Legacy direct sends kept no wire ID; peers react to that stanza ID unencrypted.
                try connection.execute("UPDATE messages SET wire_id=id WHERE wire_id IS NULL AND outgoing=1 AND encryption_profile='legacy'")
            }
            try connection.execute("CREATE INDEX IF NOT EXISTS message_wire ON messages(account_id,chat_id,wire_id)")
            // Every outgoing stanza that is not a chat message: reactions, key transports, later
            // retractions/markers. One queue, one state machine, one replay rule (the sealed wire).
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS outgoing_updates (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL, id TEXT NOT NULL,
                    kind TEXT NOT NULL, chat_id TEXT NOT NULL, target_message_id TEXT, target_wire_id TEXT,
                    reactions_json TEXT, created_at REAL NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('queued','submitting','unconfirmed','failed','serverAccepted')),
                    attempt_id TEXT, wire BLOB, UNIQUE(account_id,id),
                    FOREIGN KEY(account_id,target_message_id) REFERENCES messages(account_id,id)
                )
                """)
            try connection.execute("CREATE INDEX IF NOT EXISTS outgoing_update_queue ON outgoing_updates(account_id,state,sequence)")
            if version < 10 {
                let tables = Set(try connection.query("SELECT name FROM sqlite_master WHERE type='table'").map { $0[0].string })
                if tables.contains("reaction_updates") {
                    try connection.execute("""
                        INSERT INTO outgoing_updates(account_id,id,kind,chat_id,target_message_id,target_wire_id,reactions_json,created_at,state,attempt_id,wire)
                        SELECT account_id,id,'reaction',chat_id,target_message_id,target_wire_id,reactions_json,created_at,state,attempt_id,wire FROM reaction_updates ORDER BY sequence
                        """)
                    try connection.execute("DROP TABLE reaction_updates")
                }
                if tables.contains("encryption_controls") {
                    try connection.execute("""
                        INSERT INTO outgoing_updates(account_id,id,kind,chat_id,created_at,state,wire)
                        SELECT account_id,id,'keyTransport',recipient,strftime('%s','now'),state,wire FROM encryption_controls ORDER BY rowid
                        """)
                    try connection.execute("DROP TABLE encryption_controls")
                }
            }
            // Every message-scoped event peers assert: reactions now, retractions/corrections/receipts
            // later. One table, one idempotency rule, one target resolution.
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS message_events (
                    account_id TEXT NOT NULL, actor_id TEXT NOT NULL, id TEXT NOT NULL,
                    chat_id TEXT NOT NULL, target_wire_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('reaction','retraction','correction','delivered','displayed')),
                    payload_json TEXT NOT NULL, updated_at REAL NOT NULL,
                    PRIMARY KEY(account_id,actor_id,id)
                )
                """)
            if version < 11, try !connection.query("SELECT name FROM sqlite_master WHERE type='table' AND name='reaction_events'").isEmpty {
                try connection.execute("""
                    INSERT INTO message_events(account_id,actor_id,id,chat_id,target_wire_id,kind,payload_json,updated_at)
                    SELECT account_id,actor_id,id,chat_id,target_wire_id,'reaction',reactions_json,updated_at FROM reaction_events
                    """)
                try connection.execute("DROP TABLE reaction_events")
            }
            try connection.execute("CREATE INDEX IF NOT EXISTS event_target ON message_events(account_id,chat_id,target_wire_id,kind,actor_id,updated_at,id)")
            if version < 13, try !connection.query("SELECT name FROM sqlite_master WHERE type='table' AND name='notification_preferences'").isEmpty {
                // One row per account was always the shape; receipts add two switches beside previews.
                try connection.execute("ALTER TABLE notification_preferences RENAME TO account_preferences")
                try connection.execute("ALTER TABLE account_preferences ADD COLUMN delivery_receipts INTEGER NOT NULL DEFAULT 1")
                try connection.execute("ALTER TABLE account_preferences ADD COLUMN read_receipts INTEGER NOT NULL DEFAULT 1")
            }
            try connection.execute("CREATE TABLE IF NOT EXISTS account_preferences (account_id TEXT PRIMARY KEY, previews INTEGER NOT NULL DEFAULT 1, delivery_receipts INTEGER NOT NULL DEFAULT 1, read_receipts INTEGER NOT NULL DEFAULT 1, last_seen INTEGER NOT NULL DEFAULT 1)")
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS notification_candidates (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL, message_id TEXT NOT NULL,
                    UNIQUE(account_id,message_id),
                    FOREIGN KEY(account_id,message_id) REFERENCES messages(account_id,id)
                )
                """)
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS group_message_references (
                    account_id TEXT NOT NULL, room TEXT NOT NULL, message_id TEXT NOT NULL, stanza_id TEXT NOT NULL,
                    PRIMARY KEY(account_id,message_id), FOREIGN KEY(account_id,message_id) REFERENCES messages(account_id,id) ON DELETE CASCADE
                )
                """)
            try connection.execute("CREATE INDEX IF NOT EXISTS group_reference_target ON group_message_references(account_id,room,stanza_id)")
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS group_ciphertext_messages (
                    account_id TEXT NOT NULL, sender TEXT NOT NULL, digest TEXT NOT NULL, message_id TEXT NOT NULL,
                    PRIMARY KEY(account_id,sender,digest), FOREIGN KEY(account_id,message_id) REFERENCES messages(account_id,id) ON DELETE CASCADE
                )
                """)
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS archive_rejections (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL, archive_id TEXT NOT NULL,
                    message_id TEXT NOT NULL, reason TEXT NOT NULL, UNIQUE(account_id,archive_id,message_id)
                )
                """)
            // v13 (v12 on the avatars-only tree; the column check keeps it idempotent): the verified XEP-0084/0153 avatar hash; the bytes live as a file beside the database.
            if version < 13, try connection.query("SELECT 1 FROM pragma_table_info('chats') WHERE name='avatar_hash'").isEmpty {
                try connection.execute("ALTER TABLE chats ADD COLUMN avatar_hash TEXT")
            }
            // v14 (v12 on the media-only tree; IF NOT EXISTS keeps it idempotent): one file per message,
            // with metadata, sealed key material and transfer state. Bytes are files.
            if version < 14 {
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS attachments (
                        account_id TEXT NOT NULL, message_id TEXT NOT NULL, name TEXT NOT NULL, media_type TEXT NOT NULL,
                        size INTEGER NOT NULL, width INTEGER, height INTEGER, hash TEXT NOT NULL, cipher_hash TEXT,
                        secret BLOB NOT NULL, url TEXT, upload_state TEXT CHECK(upload_state IN ('pending','uploaded')), task_id INTEGER,
                        PRIMARY KEY(account_id, message_id),
                        FOREIGN KEY(account_id, message_id) REFERENCES messages(account_id, id)
                    )
                    """)
            }
            // v15: placeholders for messages this device deliberately cannot show, and why a retained ciphertext is still pending.
            // Values are enforced in Swift (`UnreadableReason`, `PendingEncryptedReason`); ALTER cannot add a CHECK.
            if version < 15, try connection.query("SELECT 1 FROM pragma_table_info('messages') WHERE name='unreadable_reason'").isEmpty {
                try connection.execute("ALTER TABLE messages ADD COLUMN unreadable_reason TEXT")
            }
            if version < 15, try connection.query("SELECT 1 FROM pragma_table_info('pending_encrypted_inbox') WHERE name='reason'").isEmpty {
                try connection.execute("ALTER TABLE pending_encrypted_inbox ADD COLUMN reason TEXT NOT NULL DEFAULT 'trustPending'")
            }
            // v16: the backward cursor of each archive's history backfill; IF NOT EXISTS keeps it idempotent.
            // An archive with a forward checkpoint and no row here was walked forward from its start (before v16).
            if version < 16 {
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS archive_backfill (
                        account_id TEXT NOT NULL, archive_id TEXT NOT NULL, revision INTEGER NOT NULL,
                        oldest_id TEXT NOT NULL, complete INTEGER NOT NULL DEFAULT 0 CHECK(complete IN (0,1)),
                        PRIMARY KEY(account_id, archive_id)
                    )
                    """)
            }
            // v17: the last-seen switch (column check keeps it idempotent on trees that wrote it as v15).
            if try connection.query("SELECT 1 FROM pragma_table_info('account_preferences') WHERE name='last_seen'").isEmpty {
                try connection.execute("ALTER TABLE account_preferences ADD COLUMN last_seen INTEGER NOT NULL DEFAULT 1")
            }
            // v18: retained ciphertext waiting for trust or keys may alert. It has no message row, so its
            // candidate lives beside the pending row and disappears with it. IF NOT EXISTS keeps it idempotent.
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS pending_notification_candidates (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL, sender TEXT NOT NULL, digest TEXT NOT NULL,
                    chat_id TEXT NOT NULL, sent_at REAL NOT NULL, UNIQUE(account_id,sender,digest),
                    FOREIGN KEY(account_id,sender,digest) REFERENCES pending_encrypted_inbox(account_id,sender,digest) ON DELETE CASCADE
                )
                """)
            // v19: read state. Each chat's read pointer (the newest message read on any device of the account) and the
            // XEP-0359 id the account's own archive gave a direct message, by which XEP-0490 names it. Every step checks
            // for its column or table, so the v18–v20 branches migrate correctly in any merge order.
            if try connection.query("SELECT 1 FROM pragma_table_info('messages') WHERE name='stanza_id'").isEmpty {
                try connection.execute("ALTER TABLE messages ADD COLUMN stanza_id TEXT")
            }
            try connection.execute("CREATE INDEX IF NOT EXISTS message_stanza ON messages(account_id,chat_id,stanza_id) WHERE stanza_id IS NOT NULL")
            // Which message a consumed ciphertext became, so a later archive copy of it can still bind the stanza-id.
            if try connection.query("SELECT 1 FROM pragma_table_info('encrypted_inbox') WHERE name='message_id'").isEmpty {
                try connection.execute("ALTER TABLE encrypted_inbox ADD COLUMN message_id TEXT")
            }
            if try connection.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_read_state'").isEmpty {
                try connection.execute("""
                    CREATE TABLE chat_read_state (
                        account_id TEXT NOT NULL, chat_id TEXT NOT NULL,
                        read_sent_at REAL NOT NULL, read_message_id TEXT NOT NULL,
                        publish_pending INTEGER NOT NULL DEFAULT 0 CHECK(publish_pending IN (0,1)),
                        published_stanza_id TEXT,
                        PRIMARY KEY(account_id, chat_id)
                    )
                    """)
                // An upgrade is not news: every existing chat counts as read up to its newest message, and nothing
                // already waiting may alert. One index seek per chat.
                try connection.execute("""
                    INSERT INTO chat_read_state(account_id,chat_id,read_sent_at,read_message_id)
                    SELECT c.account_id,c.id,m.sent_at,m.id FROM chats c JOIN messages m ON m.account_id=c.account_id
                    AND m.id=(SELECT x.id FROM messages x WHERE x.account_id=c.account_id AND x.chat_id=c.id ORDER BY x.sent_at DESC,x.id DESC LIMIT 1)
                    """)
                try connection.execute("DELETE FROM notification_candidates")
            }
            // v19: each archive's history baseline. Its first (newest) page is history, read before this device joined
            // the account, as is anything backfill brings from further back: a message no newer than the baseline of
            // the archive that holds its chat counts as read even where no pointer exists. An upgrade seeds it from
            // what each walked archive has stored.
            if try connection.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='read_baselines'").isEmpty {
                try connection.execute("""
                    CREATE TABLE read_baselines (
                        account_id TEXT NOT NULL, archive_id TEXT NOT NULL, sent_at REAL NOT NULL,
                        PRIMARY KEY(account_id, archive_id)
                    )
                    """)
                try connection.execute("""
                    INSERT INTO read_baselines(account_id,archive_id,sent_at)
                    SELECT account_id,archive_id,newest FROM (
                        SELECT a.account_id,a.archive_id,(SELECT MAX(m.sent_at) FROM messages m WHERE m.account_id=a.account_id
                            AND (a.archive_id=a.account_id OR m.chat_id=a.archive_id)) AS newest
                        FROM archive_checkpoints a) WHERE newest IS NOT NULL
                    """)
            }
            // v20: per-chat notification level and mute, and the own room nickname for mention detection. Local only;
            // column checks keep it idempotent whatever order the v18/v19 migrations land in.
            if try connection.query("SELECT 1 FROM pragma_table_info('chats') WHERE name='notification_level'").isEmpty {
                try connection.execute("ALTER TABLE chats ADD COLUMN notification_level TEXT NOT NULL DEFAULT 'all' CHECK(notification_level IN ('all','mentions'))")
            }
            if try connection.query("SELECT 1 FROM pragma_table_info('chats') WHERE name='muted_until'").isEmpty {
                try connection.execute("ALTER TABLE chats ADD COLUMN muted_until REAL")
            }
            if try connection.query("SELECT 1 FROM pragma_table_info('chats') WHERE name='room_nickname'").isEmpty {
                try connection.execute("ALTER TABLE chats ADD COLUMN room_nickname TEXT")
            }
            // v21: others' authenticated reactions to this account's own messages may alert, behind a per-account
            // switch that defaults on. One row per actor and target: a replacement updates it, a removal deletes it.
            // Column and table checks keep it idempotent in any merge order.
            if try connection.query("SELECT 1 FROM pragma_table_info('account_preferences') WHERE name='reaction_alerts'").isEmpty {
                try connection.execute("ALTER TABLE account_preferences ADD COLUMN reaction_alerts INTEGER NOT NULL DEFAULT 1")
            }
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS reaction_notification_candidates (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL, chat_id TEXT NOT NULL,
                    actor_id TEXT NOT NULL, target_message_id TEXT NOT NULL, reactions_json TEXT NOT NULL, reacted_at REAL NOT NULL,
                    UNIQUE(account_id,chat_id,actor_id,target_message_id),
                    FOREIGN KEY(account_id,target_message_id) REFERENCES messages(account_id,id) ON DELETE CASCADE
                )
                """)
            // What a run posted per actor and target, so cleanup can tell a delivered reaction notification that still
            // matches the actor's reaction from one that was withdrawn (in part or whole) or seen since.
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS reaction_notifications_posted (
                    account_id TEXT NOT NULL, chat_id TEXT NOT NULL, actor_id TEXT NOT NULL, target_message_id TEXT NOT NULL,
                    reactions_json TEXT NOT NULL,
                    PRIMARY KEY(account_id,chat_id,actor_id,target_message_id),
                    FOREIGN KEY(account_id,target_message_id) REFERENCES messages(account_id,id) ON DELETE CASCADE
                )
                """)
            // v22: the archive time of each checkpoint's entry, so a walk whose cursor the server no longer holds restarts by
            // time (XEP-0313 `start`), and one row per lost cursor. Column and table checks keep it idempotent in any merge order.
            if version < 22, try connection.query("SELECT 1 FROM pragma_table_info('archive_checkpoints') WHERE name='stamp'").isEmpty {
                try connection.execute("ALTER TABLE archive_checkpoints ADD COLUMN stamp REAL")
            }
            if version < 22 {
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS archive_gaps (
                        account_id TEXT NOT NULL, archive_id TEXT NOT NULL, cursor TEXT NOT NULL, since REAL, detected_at REAL NOT NULL,
                        PRIMARY KEY(account_id, archive_id, cursor)
                    )
                    """)
            }
            // v23: stored addresses in normal form; merges chats that differ only in spelling. `AddressMigration` checks
            // each table and column exists and is idempotent, so it is safe in any merge order. A rewrite it had to roll
            // back leaves the version below 23, so a later open tries again instead of stranding the typed spelling.
            try AddressMigration.addSealedAccountColumns(connection)
            let addressesMigrated = try version >= 23 || AddressMigration.run(connection)
            // v24: why a server returned an outgoing message or update (`rejectOutgoing`), and that it ever did. Column
            // checks keep it idempotent in any merge order, and when a rolled-back address rewrite leaves the version at 22.
            if version < 24 {
                for table in ["outbox", "outgoing_updates"] {
                    for (column, type) in [("rejection", "TEXT"), ("returned", "INTEGER NOT NULL DEFAULT 0")]
                    where try connection.query("SELECT 1 FROM pragma_table_info('\(table)') WHERE name='\(column)'").isEmpty {
                        try connection.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
                    }
                }
            }
            // v25: each encryption state row's device ID in plain text, and own device IDs given up when encryption was
            // set up again, with where each stands in the published device lists.
            // Column and table checks keep it idempotent in any merge order.
            if try connection.query("SELECT 1 FROM pragma_table_info('encryption_state') WHERE name='device_id'").isEmpty {
                try connection.execute("ALTER TABLE encryption_state ADD COLUMN device_id INTEGER")
            }
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS retired_own_devices (
                    account_id TEXT NOT NULL, profile TEXT NOT NULL CHECK(profile IN ('legacy','modern')), device_id INTEGER NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','removed','reclaimed')),
                    PRIMARY KEY(account_id, profile, device_id)
                )
                """)
            // v26: link previews. The preview a message carries, sent or received, goes and comes with its message; our
            // own fetches are a per-account cache whose image files live under the account's attachment folder. The
            // version check and IF NOT EXISTS keep it idempotent in any merge order.
            if version < 26 {
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS message_link_previews (
                        account_id TEXT NOT NULL, message_id TEXT NOT NULL, url TEXT NOT NULL, title TEXT, summary TEXT,
                        image_data BLOB, image_type TEXT, image_alt TEXT, source TEXT NOT NULL CHECK(source IN ('sender','own')),
                        PRIMARY KEY(account_id, message_id),
                        FOREIGN KEY(account_id, message_id) REFERENCES messages(account_id, id) ON DELETE CASCADE
                    )
                    """)
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS link_preview_cache (
                        account_id TEXT NOT NULL, url TEXT NOT NULL, fetched_at REAL NOT NULL,
                        status TEXT NOT NULL CHECK(status IN ('ok','failed')), title TEXT, summary TEXT, image_alt TEXT,
                        image_path TEXT, image_width INTEGER, image_height INTEGER,
                        PRIMARY KEY(account_id, url)
                    )
                    """)
                try connection.execute("CREATE INDEX IF NOT EXISTS link_preview_cache_age ON link_preview_cache(account_id,fetched_at)")
            }
            try connection.execute("PRAGMA user_version = \(addressesMigrated ? 26 : 22)")
        }
    }

    public func upsertChat(accountID: String, chatID: String, title: String) throws {
        guard !accountID.isEmpty, !chatID.isEmpty else { throw MessageStoreError.invalidValue }
        try connection.execute("""
            INSERT INTO chats(account_id,id,title) VALUES(?,?,?)
            ON CONFLICT(account_id,id) DO UPDATE SET title=excluded.title
            """, [.text(accountID), .text(chatID), .text(title)])
    }

    /// Repeated delivery preserves local starring. A conflicting payload is an error.
    @discardableResult public func insertMessage(_ message: StoredMessage) throws -> Bool {
        try connection.transaction { try insertMessageInTransaction(message) }
    }

    private func insertMessageInTransaction(_ message: StoredMessage) throws -> Bool {
        guard !message.id.isEmpty, !message.accountID.isEmpty, !message.chatID.isEmpty,
              message.sentAt.timeIntervalSince1970.isFinite,
              message.wireID.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
              !message.wireIDAuthenticated || (message.wireID != nil && message.encryptionProfile == "modern"),
              // Placeholders are written only by `recordUnreadableMessage`; nothing else may claim their profile or ID space.
              message.encryptionProfile != Self.unreadableProfile, message.unreadableReason == nil,
              !message.id.hasPrefix(Self.unreadableIDPrefix) else { throw MessageStoreError.invalidValue }
        let replyJSON: Value
        if let reply = message.reply {
            try Self.validateReply(reply)
            replyJSON = .text(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
        } else {
            replyJSON = .null
        }
        if let existing = try connection.query("SELECT \(Self.columns) FROM messages WHERE account_id=? AND id=?",
                                               [.text(message.accountID), .text(message.id)]).first.map(decodeRow) {
            var comparison = message
            comparison.isStarred = existing.isStarred
            comparison.transportState = existing.transportState
            comparison.rejection = existing.rejection
            comparison.attachment = existing.attachment
            // A seal for a legacy chat may have cleared our own preview since (`sealQueuedOutgoing`).
            comparison.linkPreview = existing.linkPreview
            guard existing == comparison else { throw MessageStoreError.conflictingIdentity }
            return false
        }
        if let attachment = message.attachment {
            try Self.validateAttachment(attachment)
        }
        try message.linkPreview?.validate()
        try connection.execute("""
            INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing,starred,reply_json,encryption_profile,wire_id,wire_id_authenticated)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(message.accountID), .text(message.id), .text(message.chatID), .text(message.senderID),
                  .text(message.body), .real(message.sentAt.timeIntervalSince1970),
                  .integer(message.isOutgoing ? 1 : 0), .integer(message.isStarred ? 1 : 0), replyJSON, message.encryptionProfile.map(Value.text) ?? .null,
                  message.wireID.map(Value.text) ?? .null, .integer(message.wireIDAuthenticated ? 1 : 0)])
        if let attachment = message.attachment {
            try connection.execute("""
                INSERT INTO attachments(account_id,message_id,name,media_type,size,width,height,hash,cipher_hash,secret,url,upload_state,task_id)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(message.accountID), .text(message.id), .text(attachment.name), .text(attachment.mediaType), .integer(attachment.size),
                      attachment.width.map(Value.integer) ?? .null, attachment.height.map(Value.integer) ?? .null, .text(attachment.hash),
                      attachment.cipherHash.map(Value.text) ?? .null, .blob(attachment.secret), attachment.url.map(Value.text) ?? .null,
                      attachment.uploadState.map { .text($0.rawValue) } ?? .null, attachment.uploadTaskID.map(Value.integer) ?? .null])
        }
        if let preview = message.linkPreview {
            try connection.execute("""
                INSERT INTO message_link_previews(account_id,message_id,url,title,summary,image_data,image_type,image_alt,source)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, [.text(message.accountID), .text(message.id), .text(preview.url), preview.title.map(Value.text) ?? .null,
                      preview.summary.map(Value.text) ?? .null, preview.imageData.map(Value.blob) ?? .null, preview.imageType.map(Value.text) ?? .null,
                      preview.imageAlt.map(Value.text) ?? .null, .text(preview.source.rawValue)])
        }
        return true
    }

    private static func validateAttachment(_ attachment: StoredAttachment) throws {
        guard !attachment.name.isEmpty, attachment.name.utf8.count <= 255, !attachment.mediaType.isEmpty, attachment.mediaType.utf8.count <= 128,
              attachment.size >= 0, attachment.hash.utf8.count <= 64, attachment.cipherHash.map({ $0.utf8.count <= 64 }) ?? true,
              !attachment.secret.isEmpty, attachment.secret.count <= 4_096, attachment.url.map({ $0.utf8.count <= 2_048 }) ?? true,
              attachment.width.map({ $0 > 0 }) ?? true, attachment.height.map({ $0 > 0 }) ?? true else { throw MessageStoreError.invalidValue }
    }

    /// Atomically saves the message and queued work before any socket operation.
    /// The supplied message ID must also be the stable outgoing stanza/origin ID.
    /// Repeating an enqueue never resets an existing transport attempt.
    @discardableResult public func enqueueOutgoing(_ message: StoredMessage) throws -> Bool {
        guard message.isOutgoing, !message.body.isEmpty || message.attachment != nil, message.body.utf8.count <= 65_536,
              message.attachment.map({ $0.uploadState != nil }) ?? true else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let inserted = try insertMessageInTransaction(message)
            let existing = try connection.query("SELECT state FROM outbox WHERE account_id=? AND message_id=?",
                                                [.text(message.accountID), .text(message.id)])
            if !inserted && existing.isEmpty {
                // An older message may already have been sent. Enqueue must not silently replay it.
                throw MessageStoreError.invalidTransition
            }
            if inserted {
                try connection.execute("INSERT INTO outbox(account_id,message_id,state) VALUES(?,?,'queued')",
                                       [.text(message.accountID), .text(message.id)])
            }
            return inserted
        }
    }

    /// Acquires a nonblocking kernel lock shared by the app and extensions. Process termination
    /// releases it automatically; a suspended owner retains it and contenders must defer transport.
    /// Reading/opening a database never recovers or modifies another owner's active submissions.
    public func acquireTransportOwnership() throws {
        guard connection.isOpen else { throw MessageStoreError.closed }
        try transportOwnership.acquire()
        // A restore or directory move replaced the file while this connection waited: it must not write into, or
        // connect for, data nobody will read again.
        guard FileIdentity(path: url.path) == fileIdentity else {
            transportOwnership.release()
            throw MessageStoreError.replaced
        }
    }

    /// Copies the database, as one committed state, to a new file at `destination` with SQLite's online backup API:
    /// page by page through this connection's read transaction, so frames still in the WAL are included and the
    /// source is only read (no checkpoint, no journal-mode or version change, same page size and layout). The copy
    /// is then reopened and checked (`verifySnapshot`) against the counts read in that same transaction. Requires the
    /// lease, so no other process writes meanwhile.
    public func writeSnapshot(to destination: URL) throws -> StoreSnapshotSummary {
        try requireTransportOwnership()
        guard let source = connection.handle else { throw MessageStoreError.closed }
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: destination.path + suffix) }
        try connection.execute("BEGIN")
        let summary: StoreSnapshotSummary
        do {
            summary = try StoreSnapshotSummary(connection)
            let copy = try Connection(url: destination)
            defer { try? copy.close() }
            guard let backup = sqlite3_backup_init(copy.handle, "main", source, "main") else {
                throw copy.error(sqlite3_errcode(copy.handle))
            }
            let stepped = sqlite3_backup_step(backup, -1)
            let finished = sqlite3_backup_finish(backup)
            guard stepped == SQLITE_DONE else { throw copy.error(stepped) }
            guard finished == SQLITE_OK else { throw copy.error(finished) }
            // At rest the copy is one self-contained file in rollback-journal mode, so reading or verifying it leaves
            // no WAL sidecars that could be mistaken for part of it. Putting it back switches it to WAL
            // (`useWriteAheadLog`): a build opening a store at its own schema leaves the journal mode as it is.
            guard try copy.query("PRAGMA journal_mode = DELETE").first?.first?.optionalString == "delete" else {
                throw MessageStoreError.snapshotMismatch("journal mode")
            }
            try copy.close()
            // Nothing has the copy open: sidecars left from its brief WAL phase are empty and not part of it.
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: destination.path + suffix) }
            try connection.execute("COMMIT")
        } catch { try? connection.execute("ROLLBACK"); throw error }
        try Self.verifySnapshot(at: destination, matches: summary)
        return summary
    }

    /// Checks a copy made by `writeSnapshot` (then or later, before it is restored): `integrity_check` is ok, and the
    /// schema version and every table's row count equal what was read from the source.
    public static func verifySnapshot(at url: URL, matches expected: StoreSnapshotSummary) throws {
        let copy = try Connection(url: url, create: false)
        defer { try? copy.close() }
        let integrity = try copy.query("PRAGMA integrity_check").compactMap { $0.first?.optionalString }
        guard integrity == ["ok"] else { throw MessageStoreError.snapshotMismatch("integrity: " + integrity.prefix(3).joined(separator: "; ")) }
        let found = try StoreSnapshotSummary(copy)
        guard found.schemaVersion == expected.schemaVersion else {
            throw MessageStoreError.snapshotMismatch("schema \(found.schemaVersion) != \(expected.schemaVersion)")
        }
        guard found.rowCounts == expected.rowCounts else {
            let differing = Set(found.rowCounts.keys).union(expected.rowCounts.keys).filter { found.rowCounts[$0] != expected.rowCounts[$0] }
            throw MessageStoreError.snapshotMismatch("row counts differ: " + differing.sorted().joined(separator: ","))
        }
    }

    /// Whether this store holds the transport lease right now. A caller that gave it up, or never got it, reads false.
    public var holdsTransportOwnership: Bool { transportOwnership.isHeld }

    /// Switches a database file nobody has open to write-ahead logging, as every build keeps its live store. A copy put
    /// back at the schema of the build that opens it (which then does not migrate it) would otherwise stay in
    /// rollback-journal mode.
    public static func useWriteAheadLog(at url: URL) throws {
        let file = try Connection(url: url, create: false)
        defer { try? file.close() }
        guard try file.query("PRAGMA journal_mode = WAL").first?.first?.optionalString == "wal" else {
            throw MessageStoreError.snapshotMismatch("journal mode")
        }
    }

    /// Stop and join all socket/sender/crypto work before closing. This deterministic lifecycle
    /// boundary must complete before deleting or replacing a database or its SQLite sidecars.
    /// Repeated closes are harmless; later database operations fail with a controlled error.
    public func close() throws {
        guard connection.isOpen else { return }
        if transportOwnership.isHeld { try releaseTransportOwnership() }
        try connection.close()
    }

    /// Containing-app migration only. Stop/join all work and close every other connection
    /// first. Close SQLite before a synchronous directory rename while retaining the same
    /// transport-lock inode across the rename. The store is unusable afterwards, even if
    /// the move fails; reopening the original/destination is an explicit caller decision.
    public func closeForMigration(_ move: @Sendable () throws -> Void) throws {
        try requireTransportOwnership()
        defer { transportOwnership.release() }
        try connection.close()
        try move()
    }

    /// Caller MUST stop and join every socket/sender before release. Invalidates attempt tokens.
    public func releaseTransportOwnership() throws {
        try requireTransportOwnership()
        try connection.transaction {
            try connection.execute("UPDATE outbox SET state='unconfirmed',attempt_id=NULL WHERE state='submitting'")
            try connection.execute("UPDATE outgoing_updates SET state='unconfirmed',attempt_id=NULL WHERE state='submitting'")
        }
        transportOwnership.release()
    }

    private func requireTransportOwnership() throws {
        guard transportOwnership.isHeld else { throw MessageStoreError.transportOwnershipRequired }
    }

    /// FIFO by durable enqueue order, independent of message timestamps.
    public func claimNextOutgoing(accountID: String, messageIDs: Set<String>? = nil) throws -> OutboxSubmission? {
        try Task.checkCancellation()
        try requireTransportOwnership()
        return try connection.transaction {
            if let messageIDs, messageIDs.isEmpty { return nil }
            let selection: String
            var parameters: [Value] = [.text(accountID)]
            if let messageIDs {
                guard messageIDs.count <= 1000 else { throw MessageStoreError.invalidValue }
                selection = " AND message_id IN (" + messageIDs.map { _ in "?" }.joined(separator: ",") + ")"
                parameters += messageIDs.map(Value.text)
            } else { selection = "" }
            guard let row = try connection.query("SELECT message_id FROM outbox WHERE account_id=? AND state='queued'" + selection + Self.uploadedOnly + " ORDER BY sequence LIMIT 1", parameters).first else { return nil }
            let attemptID = UUID().uuidString
            try connection.execute("UPDATE outbox SET state='submitting',attempt_id=? WHERE account_id=? AND message_id=? AND state='queued'",
                                   [.text(attemptID), .text(accountID), .text(row[0].string)])
            let message = try connection.query("SELECT \(Self.columns) FROM messages WHERE account_id=? AND id=?",
                                               [.text(accountID), .text(row[0].string)]).first.map(decodeRow)!
            return OutboxSubmission(message: message, attemptID: attemptID)
        }
    }

    /// Safe only when the caller knows no wire-send operation was invoked for this attempt.
    @discardableResult public func releaseUnsentSubmission(_ submission: OutboxSubmission) throws -> Bool {
        try requireTransportOwnership()
        return try connection.transaction {
            try connection.execute("""
                UPDATE outbox SET state='queued',attempt_id=NULL
                WHERE account_id=? AND message_id=? AND state='submitting' AND attempt_id=?
                """, [.text(submission.message.accountID), .text(submission.message.id), .text(submission.attemptID)])
            return try connection.query("SELECT changes()").first?[0].integer == 1
        }
    }

    /// Call for BOTH successful socket writes and errors/cancellation after claiming.
    /// Socket completion is not a delivery acknowledgement. Late callbacks are harmless no-ops.
    @discardableResult public func finishOutgoingSubmission(_ submission: OutboxSubmission) throws -> Bool {
        try requireTransportOwnership()
        return try connection.transaction {
            try connection.execute("""
                UPDATE outbox SET state='unconfirmed',attempt_id=NULL
                WHERE account_id=? AND message_id=? AND state='submitting' AND attempt_id=?
                """, [.text(submission.message.accountID), .text(submission.message.id), .text(submission.attemptID)])
            return try connection.query("SELECT changes()").first?[0].integer == 1
        }
    }

    /// Only use after acquiring ownership and stopping/joining that account's sender.
    public func recoverInterruptedSubmissions(accountID: String) throws {
        try requireTransportOwnership()
        try connection.transaction {
            try connection.execute("UPDATE outbox SET state='unconfirmed',attempt_id=NULL WHERE account_id=? AND state='submitting'", [.text(accountID)])
            try connection.execute("UPDATE outgoing_updates SET state='unconfirmed',attempt_id=NULL WHERE account_id=? AND state='submitting'", [.text(accountID)])
        }
    }

    /// Caller must explicitly warn that retry can duplicate a message already accepted remotely. A file failed by
    /// `resetEncryption` is refused: it would stay queued for good, since its key material can never be opened.
    public func retryOutgoing(accountID: String, messageID: String) throws {
        try requireTransportOwnership()
        return try connection.transaction {
            try connection.execute("""
                UPDATE outbox SET state='queued',attempt_id=NULL,rejection=NULL WHERE account_id=? AND message_id=?
                AND state IN ('unconfirmed','failed') AND rejection IS NOT ?
                """, [.text(accountID), .text(messageID), .text(Self.encryptionResetRejection)])
            guard try connection.query("SELECT changes()").first?[0].integer == 1 else {
                throw MessageStoreError.invalidTransition
            }
        }
    }

    /// A server returned one of our stanzas (`<message type='error'>`): the outbox message or outgoing update whose wire
    /// id is `wireID` in `chatID` becomes `failed` with `rejection` (an RFC 6120 condition, or `blocked`), whatever the
    /// stream acknowledgement said, since server acceptance was never delivery. Left alone: a queued retry (not sent yet)
    /// and a message the peer already confirmed with a receipt or read marker. A retry clears the reason (it described
    /// the returned attempt) but the row stays marked as returned: our archive keeps a copy of that attempt, which must
    /// not pass for the retry being accepted. `firstOnly` (the archive's copy of a bounce, which may be older than a
    /// retry) leaves a row alone once it was ever returned. Returns what failed, or nil when nothing matched or the row
    /// already failed for this reason (a bounce redelivered on a resumed stream).
    @discardableResult public func rejectOutgoing(accountID: String, chatID: String, wireID: String, rejection: String,
                                                  firstOnly: Bool = false) throws -> RejectedOutgoing? {
        try requireTransportOwnership()
        guard !accountID.isEmpty, !chatID.isEmpty, !wireID.isEmpty, wireID.utf8.count <= 1_024, (1...64).contains(rejection.utf8.count),
              rejection.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }) else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let parameters: [Value] = [.text(rejection), .text(accountID), .text(wireID), .text(chatID), .integer(firstOnly ? 1 : 0)]
            try connection.execute("""
                UPDATE outbox SET state='failed',attempt_id=NULL,rejection=?1,returned=1
                WHERE account_id=?2 AND message_id=?3 AND state IN ('submitting','unconfirmed','serverAccepted','failed') AND (?5=0 OR returned=0)
                AND NOT (state='failed' AND rejection IS ?1)
                AND EXISTS (SELECT 1 FROM messages m WHERE m.account_id=?2 AND m.id=?3 AND m.chat_id=?4 AND m.outgoing=1 AND m.sender_id=?2
                    AND NOT EXISTS (SELECT 1 FROM message_events e WHERE e.account_id=?2 AND e.chat_id=?4 AND e.actor_id<>?2
                        AND e.kind IN ('delivered','displayed') AND e.target_wire_id IN (m.id, m.wire_id)))
                """, parameters)
            if try connection.query("SELECT changes()").first?[0].integer == 1 {
                return RejectedOutgoing(chatID: chatID, messageID: wireID, rejection: rejection)
            }
            try connection.execute("""
                UPDATE outgoing_updates SET state='failed',attempt_id=NULL,rejection=?1,returned=1
                WHERE account_id=?2 AND id=?3 AND chat_id=?4 AND state IN ('submitting','unconfirmed','serverAccepted','failed') AND (?5=0 OR returned=0)
                AND NOT (state='failed' AND rejection IS ?1)
                """, parameters)
            return try connection.query("SELECT changes()").first?[0].integer == 1 ? RejectedOutgoing(chatID: chatID, messageID: nil, rejection: rejection) : nil
        }
    }

    /// Marks only work rejected locally BEFORE claiming (for example unsupported addressing).
    public func failQueuedOutgoing(accountID: String, messageID: String) throws {
        try requireTransportOwnership()
        return try connection.transaction {
            try connection.execute("UPDATE outbox SET state='failed' WHERE account_id=? AND message_id=? AND state='queued'",
                                   [.text(accountID), .text(messageID)])
            guard try connection.query("SELECT changes()").first?[0].integer == 1 else {
                throw MessageStoreError.invalidTransition
            }
        }
    }

    /// One statement for the whole list: each chat's newest message with its attachment, outbox
    /// state and the sender's retraction/correction, plus the strongest peer receipt. Same result
    /// as `messages(limit: 1)` + `events` per chat (see `ChatListQueryTests`).
    public func chats(accountID: String) throws -> [StoredChat] {
        let notifications = try chatNotificationSettings(accountID: accountID)
        let unread = try unreadCounts(accountID: accountID)
        return try connection.query(Self.chatListSQL, [.text(accountID)]).map { row in
            var last: StoredMessage? = nil
            let message = Array(row[Self.chatListPrefix...])           // Self.columns order
            if case .text = message[1] {                               // id present: the chat has a message
                var decoded = try Self.decode(message)
                if case .text = row[4] {                               // a.name present: attachment
                    decoded.attachment = StoredAttachment(name: row[4].string, mediaType: row[5].string, size: row[6].integer,
                        width: Self.optionalInteger(row[7]), height: Self.optionalInteger(row[8]), hash: row[9].string,
                        cipherHash: row[10].optionalString, secret: row[11].data ?? Data(), url: row[12].optionalString,
                        uploadState: row[13].optionalString.flatMap(StoredAttachment.UploadState.init(rawValue:)), uploadTaskID: Self.optionalInteger(row[14]))
                }
                decoded.linkPreview = Self.decodeLinkPreview(row[19..<26])
                // Same precedence as `applying`: the sender's retraction wins over any correction.
                if row[15].integer != 0 {
                    decoded.isRetracted = true; decoded.isEdited = false; decoded.body = ""; decoded.attachment = nil; decoded.linkPreview = nil
                } else if let payload = row[16].optionalString, let body = MessageEvent.correctionBody(payload) {
                    decoded.body = body; decoded.isEdited = true; decoded.linkPreview = MessageEvent.correctionLinkPreview(payload)
                }
                last = decoded
            }
            let receipt: MessageEventKind? = last?.isOutgoing == true
                ? (row[18].integer != 0 ? .displayed : row[17].integer != 0 ? .delivered : nil) : nil
            return StoredChat(id: row[0].string, accountID: accountID, title: row[1].string, isPinned: row[2].integer != 0,
                              lastMessage: last, avatarHash: row[3].optionalString, lastMessageReceipt: receipt,
                              notification: notifications[row[0].string] ?? ChatNotificationSetting(),
                              unreadCount: unread[row[0].string] ?? 0)
        }
    }

    /// 4 chat + 11 attachment + 4 summary + 7 link preview columns precede `l.*` (Self.columns order).
    private static let chatListPrefix = 26
    // `?1` is the account throughout. Every step is an index seek per chat: the newest message comes
    // from the `timeline` index and is joined by primary key, so the cost follows the number of chats,
    // not of messages. The store never runs ANALYZE; plans and measurements are in the package README.
    // `last` must not alias `messages`: the outbox subquery in `Self.columns` names the table.
    // Message columns come last so added columns never shift the prefix.
    private static let chatListSQL = """
        WITH last AS (
            SELECT \(columns) FROM messages WHERE account_id=?1
        ), target AS (
            -- reactionReference: modern+authenticated uses wire_id; modern unauthenticated the room stanza-id, else wire_id; other profiles wire_id.
            SELECT l.chat_id,l.id,l.sender_id,
                   CASE WHEN l.encryption_profile='modern' AND l.wire_id_authenticated=1 THEN l.wire_id
                        WHEN l.encryption_profile='modern' THEN COALESCE(
                            (SELECT g.stanza_id FROM group_message_references g
                             WHERE g.account_id=l.account_id AND g.message_id=l.id AND g.room=l.chat_id), l.wire_id)
                        ELSE l.wire_id END AS wire_id
            FROM chats c CROSS JOIN messages l
            WHERE c.account_id=?1 AND l.account_id=?1
              AND l.id=(SELECT m.id FROM messages m WHERE m.account_id=?1 AND m.chat_id=c.id ORDER BY m.sent_at DESC,m.id DESC LIMIT 1)
        ), resolved AS MATERIALIZED (
            -- reactionTarget: exactly one authenticated match wins; else a single unauthenticated match; else nothing.
            -- The two match paths are a rowid UNION so each stays an index seek (an OR scans the chat).
            SELECT t.chat_id,t.id,t.sender_id,t.wire_id FROM target t
            WHERE t.wire_id IS NOT NULL AND t.id=(
                SELECT CASE WHEN SUM(c.wire_id_authenticated)=1 THEN MAX(CASE WHEN c.wire_id_authenticated=1 THEN c.id END)
                            WHEN SUM(c.wire_id_authenticated)=0 AND COUNT(*)=1 THEN MAX(c.id) END
                FROM messages c
                WHERE c.rowid IN (
                    SELECT m.rowid FROM messages m WHERE m.account_id=?1 AND m.chat_id=t.chat_id AND m.wire_id=t.wire_id
                    UNION
                    SELECT m.rowid FROM group_message_references g
                    JOIN messages m ON m.account_id=g.account_id AND m.id=g.message_id AND m.chat_id=g.room
                    WHERE g.account_id=?1 AND g.room=t.chat_id AND g.stanza_id=t.wire_id)
            )
        ), latest AS (
            -- events(): latest per (actor, kind); only the sender may unsend or rewrite a message.
            SELECT r.chat_id,e.actor_id,e.kind,e.payload_json,
                   ROW_NUMBER() OVER (PARTITION BY r.chat_id,e.actor_id,e.kind ORDER BY e.updated_at DESC,e.id DESC) AS position
            FROM resolved r
            CROSS JOIN message_events e ON e.account_id=?1 AND e.chat_id=r.chat_id AND e.target_wire_id=r.wire_id
            WHERE e.kind NOT IN ('retraction','correction') OR e.actor_id=r.sender_id
        ), summary AS (
            -- At most one correction row per chat survives (sender-only, one per actor and kind).
            SELECT chat_id,
                   MAX(kind='retraction') AS retracted,
                   MAX(CASE WHEN kind='correction' THEN payload_json END) AS correction,
                   MAX(kind='delivered') AS delivered,
                   MAX(kind='displayed') AS displayed
            FROM latest WHERE position=1 GROUP BY chat_id
        )
        SELECT c.id,c.title,c.pinned,c.avatar_hash,
               a.name,a.media_type,a.size,a.width,a.height,a.hash,a.cipher_hash,a.secret,a.url,a.upload_state,a.task_id,
               s.retracted,s.correction,s.delivered,s.displayed,
               p.url,p.title,p.summary,p.image_data,p.image_type,p.image_alt,p.source,
               l.*
        FROM chats c
        LEFT JOIN last l ON l.id=(SELECT m.id FROM messages m WHERE m.account_id=?1 AND m.chat_id=c.id ORDER BY m.sent_at DESC,m.id DESC LIMIT 1)
        LEFT JOIN attachments a ON a.account_id=?1 AND a.message_id=l.id
        LEFT JOIN message_link_previews p ON p.account_id=?1 AND p.message_id=l.id
        LEFT JOIN summary s ON s.chat_id=c.id
        WHERE c.account_id=?1
        ORDER BY c.pinned DESC,l.sent_at DESC,c.id
        """
    // Same body as `decodeRow`'s inline helper; kept apart so `decodeRow` stays untouched.
    private static func optionalInteger(_ value: Value) -> Int? { if case .integer(let number) = value { return number }; return nil }

    /// Records which verified avatar a chat shows; nil when the contact removed theirs.
    public func setAvatarHash(accountID: String, chatID: String, hash: String?) throws {
        try connection.execute("UPDATE chats SET avatar_hash=? WHERE account_id=? AND id=?",
                               [hash.map(Value.text) ?? .null, .text(accountID), .text(chatID)])
    }

    /// Returns the latest page in chronological order. Cursor uses both timestamp and ID for ties.
    public func messages(accountID: String, chatID: String, limit: Int = 100,
                         before: StoredMessage? = nil) throws -> [StoredMessage] {
        var sql = "SELECT \(Self.columns) FROM messages WHERE account_id=? AND chat_id=?"
        var values: [Value] = [.text(accountID), .text(chatID)]
        if let before {
            guard before.accountID == accountID, before.chatID == chatID else { throw MessageStoreError.invalidValue }
            sql += " AND (sent_at < ? OR (sent_at = ? AND id < ?))"
            values += [.real(before.sentAt.timeIntervalSince1970), .real(before.sentAt.timeIntervalSince1970), .text(before.id)]
        }
        sql += " ORDER BY sent_at DESC, id DESC LIMIT ?"
        values.append(.integer(max(0, min(limit, 1000))))
        return try connection.query(sql, values).map(decodeRow).reversed()
    }

    /// Literal substring search, not yet FTS/ranked multilingual search. Wildcards are literal.
    public func search(accountID: String, query: String, chatID: String? = nil, limit: Int = 100) throws -> [StoredMessage] {
        guard !query.isEmpty else { return [] }
        var sql = "SELECT \(Self.columns) FROM messages WHERE account_id=? AND instr(lower(body), lower(?)) > 0"
        var values: [Value] = [.text(accountID), .text(query)]
        if let chatID { sql += " AND chat_id=?"; values.append(.text(chatID)) }
        sql += " ORDER BY sent_at DESC, id DESC LIMIT ?"
        values.append(.integer(max(0, min(limit, 1000))))
        return try connection.query(sql, values).map(decodeRow)
    }

    public func setStarred(accountID: String, messageID: String, starred: Bool) throws {
        try connection.execute("UPDATE messages SET starred=? WHERE account_id=? AND id=?",
                               [.integer(starred ? 1 : 0), .text(accountID), .text(messageID)])
    }

    public func setPinned(accountID: String, chatID: String, pinned: Bool) throws {
        try connection.execute("UPDATE chats SET pinned=? WHERE account_id=? AND id=?",
                               [.integer(pinned ? 1 : 0), .text(accountID), .text(chatID)])
    }

    public func hasAnyEncryptionState() throws -> Bool {
        try !connection.query("SELECT 1 FROM encryption_state LIMIT 1").isEmpty
    }

    /// Retained ciphertext in arrival order. Nil filters keep every row; `reasons` filters by classification, `sender` by bare JID.
    public func pendingEncryptedIncoming(accountID: String, reasons: Set<PendingEncryptedReason>? = nil,
                                         sender: String? = nil) throws -> [PendingEncryptedMessage] {
        var sql = "SELECT sender,digest,wire,reason FROM pending_encrypted_inbox WHERE account_id=?"
        var values: [Value] = [.text(accountID)]
        if let reasons {
            guard !reasons.isEmpty else { return [] }
            let ordered = reasons.map(\.rawValue).sorted()
            sql += " AND reason IN (" + ordered.map { _ in "?" }.joined(separator: ",") + ")"
            values += ordered.map(Value.text)
        }
        if let sender { sql += " AND sender=?"; values.append(.text(sender)) }
        return try connection.query(sql + " ORDER BY rowid", values).map {
            guard let wire = $0[2].data else { throw MessageStoreError.invalidValue }
            return PendingEncryptedMessage(sender: $0[0].string, digest: $0[1].string, wire: wire,
                                           reason: PendingEncryptedReason(rawValue: $0[3].string) ?? .trustPending)
        }
    }

    /// One retained row by its primary key, with its wire; nil when nothing is pending for this ciphertext.
    public func pendingEncryptedIncoming(accountID: String, sender: String, digest: String) throws -> PendingEncryptedMessage? {
        guard let row = try connection.query("SELECT sender,digest,wire,reason FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?",
                                             [.text(accountID), .text(sender), .text(digest)]).first else { return nil }
        guard let wire = row[2].data else { throw MessageStoreError.invalidValue }
        return PendingEncryptedMessage(sender: row[0].string, digest: row[1].string, wire: wire,
                                       reason: PendingEncryptedReason(rawValue: row[3].string) ?? .trustPending)
    }

    /// Every retained row in arrival order without transferring its ciphertext: the conversation fields are projected
    /// from the envelope JSON in SQL. `CAST(wire AS TEXT)` is required because SQLite before 3.45 rejects BLOB arguments
    /// to JSON functions; `json_valid` (evaluated first by the outer `CASE`) turns a row that is not JSON into nil fields
    /// instead of an error. A field that is not a JSON string (an object, a number) also projects as nil.
    public func pendingEncryptedIncomingSummaries(accountID: String) throws -> [PendingEncryptedSummary] {
        func field(_ path: String) -> String {
            "CASE WHEN json_valid(CAST(wire AS TEXT)) THEN CASE WHEN json_type(CAST(wire AS TEXT), '\(path)')='text' THEN json_extract(CAST(wire AS TEXT), '\(path)') END END"
        }
        let sql = "SELECT sender,digest,reason," + ["$.message.room", "$.message.sender", "$.from", "$.to", "$.provenance"].map(field).joined(separator: ",")
            + " FROM pending_encrypted_inbox WHERE account_id=? ORDER BY rowid"
        return try connection.query(sql, [.text(accountID)]).map {
            PendingEncryptedSummary(sender: $0[0].string, digest: $0[1].string, reason: $0[2].string,
                                    room: $0[3].optionalString, roomSender: $0[4].optionalString,
                                    from: $0[5].optionalString, to: $0[6].optionalString, provenance: $0[7].optionalString)
        }
    }

    /// See `PendingRetentionLimits`. The account ceiling keeps the earlier bound (and the retry pass's cost) at 1,000 rows.
    /// 250 per known sender lets four contacts' unreviewed devices back up for days at once; 20 per stranger covers a
    /// first-contact burst; strangers stop at 200 rows in all, which leaves at least 800 for known contacts.
    public static let pendingLimits = PendingRetentionLimits(perKnownSender: 250, perStranger: 20, strangerCeiling: 200, perAccount: 1_000)

    /// Keeps ciphertext that may still decrypt later. An existing row keeps its reason: classification is explicit.
    /// `notification` names the chat of an incoming message that is waiting for trust or keys: the new row then also
    /// becomes a notification candidate, which is removed with the row when it commits or is converted.
    /// A new row beyond `pendingLimits` is not kept: `overflow` is recorded in the same transaction instead (its quiet
    /// placeholder, or only the consumed replay identity), so a full table still yields a durable final outcome and the
    /// stream and archive walk keep moving. Without `overflow` the conversation is taken to be the sender's direct chat
    /// and the identity is consumed. Returns false exactly when a limit applied the overflow.
    @discardableResult
    public func retainEncryptedIncoming(accountID: String, sender: String, digest: String, wire: Data,
                                        reason: PendingEncryptedReason = .trustPending,
                                        notification: PendingNotificationContext? = nil,
                                        overflow: RetentionOverflow? = nil) throws -> Bool {
        guard !accountID.isEmpty, !sender.isEmpty, !digest.isEmpty, !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        let chatID = overflow?.chatID ?? sender
        guard !chatID.isEmpty, chatID.utf8.count <= 3071 else { throw MessageStoreError.invalidValue }
        if let placeholder = overflow?.placeholder {
            try Self.validate(placeholder)
            guard placeholder.accountID == accountID, placeholder.reason == .retentionLimit,
                  placeholder.key == .ciphertext(sender: sender, digest: digest) else { throw MessageStoreError.invalidValue }
        }
        return try connection.transaction {
            if try hasEncryptedIncoming(accountID: accountID, sender: sender, digest: digest) { return true }
            if try !connection.query("SELECT 1 FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)]).isEmpty { return true }
            guard try admitsPending(accountID: accountID, sender: sender, chatID: chatID, approved: overflow?.senderApproved ?? false) else {
                if let placeholder = overflow?.placeholder {
                    _ = try insertUnreadableInTransaction(placeholder)
                } else {
                    try connection.execute("INSERT OR IGNORE INTO encrypted_inbox(account_id,sender,digest) VALUES(?,?,?)", [.text(accountID), .text(sender), .text(digest)])
                }
                return false
            }
            try connection.execute("INSERT INTO pending_encrypted_inbox(account_id,sender,digest,wire,reason) VALUES(?,?,?,?,?)", [.text(accountID), .text(sender), .text(digest), .blob(wire), .text(reason.rawValue)])
            if let notification, try queuesPendingNotification(accountID: accountID, sender: sender, digest: digest, context: notification) {
                try connection.execute("INSERT OR IGNORE INTO pending_notification_candidates(account_id,sender,digest,chat_id,sent_at) VALUES(?,?,?,?,?)",
                                       [.text(accountID), .text(sender), .text(digest), .text(notification.chatID), .real(notification.sentAt.timeIntervalSince1970)])
            }
            return true
        }
    }

    /// Whether one more row from `sender` fits `pendingLimits`: two primary-key range counts, and the known-sender lookup
    /// only when a stranger's limit would bind. An approved sender device's row answers to the account ceiling alone.
    private func admitsPending(accountID: String, sender: String, chatID: String, approved: Bool) throws -> Bool {
        let limits = Self.pendingLimits
        let total = try connection.query("SELECT COUNT(*) FROM pending_encrypted_inbox WHERE account_id=?", [.text(accountID)]).first![0].integer
        if approved { return total < limits.perAccount }
        let held = try connection.query("SELECT COUNT(*) FROM pending_encrypted_inbox WHERE account_id=? AND sender=?", [.text(accountID), .text(sender)]).first![0].integer
        guard total < limits.perAccount, held < limits.perKnownSender else { return false }
        guard held >= limits.perStranger || total >= limits.strangerCeiling else { return true }
        if sender == accountID { return true }
        // The account wrote in this conversation or to the sender directly, or a message of theirs was authenticated in
        // their direct chat or, decrypted, in this room (a placeholder never counts). All are prefixes of the timeline index.
        return try !connection.query("""
            SELECT 1 FROM messages WHERE account_id=?1 AND ((chat_id IN (?2,?3) AND outgoing=1)
                OR (chat_id=?3 AND sender_id=?3 AND outgoing=0 AND unreadable_reason IS NULL)
                OR (chat_id=?2 AND sender_id=?3 AND outgoing=0 AND unreadable_reason IS NULL AND encryption_profile='modern')) LIMIT 1
            """, [.text(accountID), .text(chatID), .text(sender)]).isEmpty
    }

    /// Retained ciphertext has no message row, so the shared notification rules see a stand-in with the conversation,
    /// author and time only: no body, no content, and an ID that never names a stored row.
    private func queuesPendingNotification(accountID: String, sender: String, digest: String, context: PendingNotificationContext) throws -> Bool {
        guard !context.chatID.isEmpty, context.chatID.utf8.count <= 3071, context.sentAt.timeIntervalSince1970.isFinite else { throw MessageStoreError.invalidValue }
        return try queuesNotification(accountID: accountID, message: StoredMessage(id: "pending-" + digest, accountID: accountID, chatID: context.chatID,
            senderID: sender, body: "", sentAt: context.sentAt, isOutgoing: false))
    }

    /// Re-labels a retained row; a no-op when the row no longer exists (it may have been committed or converted meanwhile).
    /// `notification` makes an existing row a notification candidate when it was retained without one because
    /// only later work (a room read) showed it waits for trust or keys. Pass it on the ciphertext's first observation
    /// only: a candidate that was already posted is gone, and a retry must not alert again.
    public func classifyPendingEncryptedIncoming(accountID: String, sender: String, digest: String, reason: PendingEncryptedReason,
                                                 notification: PendingNotificationContext? = nil) throws {
        try connection.transaction {
            try connection.execute("UPDATE pending_encrypted_inbox SET reason=? WHERE account_id=? AND sender=? AND digest=?",
                                   [.text(reason.rawValue), .text(accountID), .text(sender), .text(digest)])
            guard let notification, try connection.query("SELECT changes()").first?[0].integer == 1,
                  try queuesPendingNotification(accountID: accountID, sender: sender, digest: digest, context: notification) else { return }
            try connection.execute("INSERT OR IGNORE INTO pending_notification_candidates(account_id,sender,digest,chat_id,sent_at) VALUES(?,?,?,?,?)",
                                   [.text(accountID), .text(sender), .text(digest), .text(notification.chatID), .real(notification.sentAt.timeIntervalSince1970)])
        }
    }

    /// The keys of every retained ciphertext row (at most `pendingLimits.perAccount`), without wires. Notification cleanup
    /// keeps a delivered review notification only while its ciphertext is still retained here.
    public func retainedEncryptedIncomingKeys(accountID: String) throws -> [NotificationCandidateKey] {
        try connection.query("SELECT sender,digest FROM pending_encrypted_inbox WHERE account_id=? ORDER BY rowid LIMIT ?",
                             [.text(accountID), .integer(Self.pendingLimits.perAccount)])
            .map { .pending(sender: $0[0].string, digest: $0[1].string) }
    }

    /// Records a placeholder for a message this device will never show as content. Idempotent by `placeholder.id`
    /// (first observation wins, `sentAt` is never rewritten). A `.ciphertext` key also consumes the replay identity
    /// and removes the pending row. Returns true when the row was inserted now. Does not require transport ownership
    /// (the extension's archive walk and the app's live path both call it, exactly like `commitEncryptedIncoming`).
    /// The row is never plaintext, never authenticated and never an event target. An incoming placeholder from someone
    /// else is a notification candidate ("Sent a message this device can't read") when its reason `alerts`; an
    /// own-device one never is.
    @discardableResult public func recordUnreadableMessage(_ placeholder: UnreadableMessage) throws -> Bool {
        try Self.validate(placeholder)
        return try connection.transaction { try insertUnreadableInTransaction(placeholder) }
    }

    /// Consumes the replay identity of ciphertext that failed permanently but was never a message bubble (a key transport
    /// from a trusted device whose session no longer decrypts, or any non-bubble from a blocked device): no row, no session
    /// change, the pending copy (and its review candidate) is removed.
    public func consumeUndecryptableIncoming(accountID: String, sender: String, digest: String) throws {
        guard !accountID.isEmpty, !sender.isEmpty, !digest.isEmpty, digest.utf8.count <= 128 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            try connection.execute("INSERT OR IGNORE INTO encrypted_inbox(account_id,sender,digest) VALUES(?,?,?)", [.text(accountID), .text(sender), .text(digest)])
            try connection.execute("DELETE FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)])
        }
    }

    static let unreadableProfile = "unreadable"
    static let unreadableIDPrefix = "unreadable-"

    private static func validate(_ placeholder: UnreadableMessage) throws {
        func jid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 3071 && !value.contains(where: { $0.isWhitespace }) }
        guard jid(placeholder.accountID), jid(placeholder.chatID), jid(placeholder.senderID),
              placeholder.sentAt.timeIntervalSince1970.isFinite else { throw MessageStoreError.invalidValue }
        switch placeholder.key {
        case let .ciphertext(sender, digest):
            guard !sender.isEmpty, sender.utf8.count <= 3071, !digest.isEmpty, digest.utf8.count <= 128 else { throw MessageStoreError.invalidValue }
        case let .archive(archive, id):
            guard !archive.isEmpty, archive.utf8.count <= 3071, !id.isEmpty, id.utf8.count <= 1024 else { throw MessageStoreError.invalidValue }
        }
    }

    private func insertUnreadableInTransaction(_ placeholder: UnreadableMessage) throws -> Bool {
        let account = Value.text(placeholder.accountID)
        if case let .ciphertext(sender, digest) = placeholder.key,
           try hasEncryptedIncoming(accountID: placeholder.accountID, sender: sender, digest: digest) {
            // Already decided: an authenticated message, or an earlier placeholder. Never overwrite or repeat it.
            return false
        }
        try connection.execute("INSERT INTO chats(account_id,id,title) VALUES(?,?,?) ON CONFLICT(account_id,id) DO NOTHING",
                               [account, .text(placeholder.chatID), .text(placeholder.chatID)])
        try connection.execute("""
            INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing,starred,reply_json,encryption_profile,wire_id,wire_id_authenticated,unreadable_reason)
            VALUES(?,?,?,?,'',?,?,0,NULL,?,NULL,0,?) ON CONFLICT(account_id,id) DO NOTHING
            """, [account, .text(placeholder.id), .text(placeholder.chatID), .text(placeholder.senderID),
                  .real(placeholder.sentAt.timeIntervalSince1970), .integer(placeholder.isOutgoing ? 1 : 0),
                  .text(Self.unreadableProfile), .text(placeholder.reason.rawValue)])
        let inserted = try connection.query("SELECT changes()").first?[0].integer == 1
        if inserted, !placeholder.isOutgoing, placeholder.reason.alerts, let row = try message(accountID: placeholder.accountID, messageID: placeholder.id),
           try queuesNotification(accountID: placeholder.accountID, message: row) {
            try connection.execute("INSERT OR IGNORE INTO notification_candidates(account_id,message_id) VALUES(?,?)", [account, .text(placeholder.id)])
        }
        if case let .ciphertext(sender, digest) = placeholder.key {
            // The ciphertext identity is now consumed: re-seeing it costs one lookup and never yields a second bubble.
            try connection.execute("INSERT OR IGNORE INTO encrypted_inbox(account_id,sender,digest) VALUES(?,?,?)", [account, .text(sender), .text(digest)])
            try connection.execute("DELETE FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [account, .text(sender), .text(digest)])
        }
        return inserted
    }

    /// Correct retained context only after authenticating a matching archive envelope. Exact-byte
    /// CAS prevents overwriting a newer context or resurrecting ciphertext already consumed.
    @discardableResult public func replacePendingEncryptedIncomingContext(accountID: String, sender: String,
        digest: String, expectedWire: Data, wire: Data) throws -> Bool {
        guard !accountID.isEmpty, !sender.isEmpty, !digest.isEmpty,
              !expectedWire.isEmpty, expectedWire.count <= 1_048_576,
              !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            guard try !hasEncryptedIncoming(accountID: accountID, sender: sender, digest: digest) else { return false }
            try connection.execute("""
                UPDATE pending_encrypted_inbox SET wire=?
                WHERE account_id=? AND sender=? AND digest=? AND wire=?
                """, [.blob(wire), .text(accountID), .text(sender), .text(digest), .blob(expectedWire)])
            return try connection.query("SELECT changes()").first?[0].integer == 1
        }
    }

    /// The CAS revision alone: lets a caller that holds a decoded copy of the state skip reading and opening the blob.
    public func encryptionStateRevision(accountID: String) throws -> Int? {
        try connection.query("SELECT revision FROM encryption_state WHERE account_id=?", [.text(accountID)]).first?[0].integer
    }

    public func encryptionState(accountID: String) throws -> EncryptionState? {
        guard let row = try connection.query("SELECT revision,snapshot,sealed_account,device_id FROM encryption_state WHERE account_id=?", [.text(accountID)]).first else { return nil }
        guard let data = row[1].data, !data.isEmpty else { throw MessageStoreError.invalidValue }
        return EncryptionState(revision: row[0].integer, data: data, sealedAccount: row[2].optionalString,
                               deviceID: Self.optionalInteger(row[3]).flatMap(UInt32.init(exactly:)))
    }

    /// Records the device ID of an account's state row in plain text, once. A row already recorded under another ID is a
    /// different identity and is never relabelled.
    public func recordEncryptionDeviceID(accountID: String, deviceID: UInt32) throws {
        guard deviceID > 0, deviceID <= Int32.max else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            try connection.execute("UPDATE encryption_state SET device_id=? WHERE account_id=? AND device_id IS NULL",
                                   [.integer(Int(deviceID)), .text(accountID)])
            let row = try connection.query("SELECT device_id FROM encryption_state WHERE account_id=?", [.text(accountID)]).first
            if let recorded = row.flatMap({ Self.optionalInteger($0[0]) }), recorded != Int(deviceID) { throw MessageStoreError.conflictingIdentity }
        }
    }

    /// Own device IDs `accountID` gave up when encryption was set up again, for `profile` (every profile when nil), in
    /// any of `statuses`. Kept for good, whatever the status: no new identity of the account ever takes one.
    public func retiredOwnDevices(accountID: String, profile: String? = nil,
                                  statuses: Set<RetiredDeviceStatus> = Set(RetiredDeviceStatus.allCases)) throws -> Set<UInt32> {
        var sql = "SELECT device_id,status FROM retired_own_devices WHERE account_id=?"
        var values: [Value] = [.text(accountID)]
        if let profile { sql += " AND profile=?"; values.append(.text(profile)) }
        return Set(try connection.query(sql, values).compactMap { row in
            guard let status = RetiredDeviceStatus(rawValue: row[1].string), statuses.contains(status) else { return nil }
            return UInt32(exactly: row[0].integer)
        })
    }

    /// Moves retired own device IDs of `accountID` in `profile` on: `pending` to `removed` once a list read back lacks
    /// them, `removed` to `reclaimed` once a list names them again. IDs not in the expected status are left alone, and
    /// no other step exists: a reclaimed ID is never removed automatically again.
    public func advanceRetiredOwnDevices(accountID: String, profile: String, deviceIDs: Set<UInt32>, to status: RetiredDeviceStatus) throws {
        let from: RetiredDeviceStatus
        switch status {
        case .removed: from = .pending
        case .reclaimed: from = .removed
        case .pending: throw MessageStoreError.invalidTransition
        }
        try connection.transaction {
            for id in deviceIDs {
                try connection.execute("UPDATE retired_own_devices SET status=? WHERE account_id=? AND profile=? AND device_id=? AND status=?",
                                       [.text(status.rawValue), .text(accountID), .text(profile), .integer(Int(id)), .text(from.rawValue)])
            }
        }
    }

    /// Queued messages of `accountID` whose file can no longer be sealed once the wrapping key is lost, for the
    /// recovery screen (`unsendableFileCondition`).
    public func unsendableFileCount(accountID: String) throws -> Int {
        try connection.query("SELECT COUNT(*) FROM outbox o WHERE \(Self.unsendableFileCondition)", [.text(accountID)]).first?[0].integer ?? 0
    }

    /// `outbox.rejection` of a queued file that `resetEncryption` failed. Its key material was sealed with the lost
    /// key, so it can never be sealed: `retryOutgoing` refuses it, and only attaching the file again sends it.
    public static let encryptionResetRejection = "encryption-reset"

    /// Queued (never claimed) messages of account `?1` with a file and no prepared ciphertext: sealing them needs the
    /// file's key material, which was sealed with the lost key.
    private static let unsendableFileCondition = """
        o.account_id=?1 AND o.state='queued'
        AND EXISTS (SELECT 1 FROM attachments a WHERE a.account_id=o.account_id AND a.message_id=o.message_id)
        AND NOT EXISTS (SELECT 1 FROM encrypted_outbox e WHERE e.account_id=o.account_id AND e.message_id=o.message_id)
        """

    /// Starts encryption over after the wrapping key was lost, in one transaction under the lease: each discarded row
    /// goes (only at the revision it was assessed at), its recorded device ID is retired for both profiles, every one of
    /// that account's retained ciphertexts gets its final outcome (an `encryptionReset` placeholder, or only its consumed
    /// replay identity; a placeholder that does not validate is consumed instead), and its queued files that can no
    /// longer be sealed fail. The replacement identity, if any, is written last under a device ID no discarded or retired
    /// row of its account used. Nothing else changes: messages, chats, files, preferences and checkpoints stay.
    public func resetEncryption(_ reset: EncryptionReset) throws {
        try requireTransportOwnership()
        guard !reset.discarded.isEmpty, Set(reset.discarded.map(\.accountID)).count == reset.discarded.count else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            var revisions: [String: Int] = [:]
            for item in reset.discarded {
                let account = Value.text(item.accountID)
                guard let row = try connection.query("SELECT revision,device_id FROM encryption_state WHERE account_id=?", [account]).first,
                      row[0].integer == item.revision else { throw MessageStoreError.invalidTransition }
                revisions[item.accountID] = item.revision
                try connection.execute("DELETE FROM encryption_state WHERE account_id=?", [account])
                if let deviceID = Self.optionalInteger(row[1]) {
                    for profile in ["legacy", "modern"] {
                        try connection.execute("INSERT OR IGNORE INTO retired_own_devices(account_id,profile,device_id) VALUES(?,?,?)",
                                               [account, .text(profile), .integer(deviceID)])
                    }
                }
                var consumed = item.consumed
                for placeholder in item.placeholders {
                    guard placeholder.accountID == item.accountID, placeholder.reason == .encryptionReset,
                          case let .ciphertext(sender, digest) = placeholder.key else { throw MessageStoreError.invalidValue }
                    do { try Self.validate(placeholder) } catch { consumed.append(CiphertextIdentity(sender: sender, digest: digest)); continue }
                    _ = try insertUnreadableInTransaction(placeholder)
                }
                for identity in consumed {
                    try connection.execute("INSERT OR IGNORE INTO encrypted_inbox(account_id,sender,digest) VALUES(?,?,?)", [account, .text(identity.sender), .text(identity.digest)])
                    try connection.execute("DELETE FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [account, .text(identity.sender), .text(identity.digest)])
                }
                // Every retained row must have been decided: none of it can ever be decrypted again.
                guard try connection.query("SELECT 1 FROM pending_encrypted_inbox WHERE account_id=? LIMIT 1", [account]).isEmpty else {
                    throw MessageStoreError.invalidTransition
                }
                try connection.execute("UPDATE outbox SET state='failed',attempt_id=NULL,rejection=?2 WHERE sequence IN (SELECT o.sequence FROM outbox o WHERE \(Self.unsendableFileCondition))",
                                       [account, .text(Self.encryptionResetRejection)])
            }
            if let replacement = reset.replacement {
                let account = Value.text(replacement.accountID)
                guard !replacement.data.isEmpty, replacement.data.count <= 16_777_216, replacement.deviceID > 0, replacement.deviceID <= Int32.max,
                      try connection.query("SELECT 1 FROM encryption_state WHERE account_id=?", [account]).isEmpty,
                      try !retiredOwnDevices(accountID: replacement.accountID).contains(replacement.deviceID) else { throw MessageStoreError.invalidTransition }
                // A revision above the discarded row's, so no cache keyed by revision can mistake the new state for the old.
                try connection.execute("INSERT INTO encryption_state(account_id,revision,snapshot,device_id) VALUES(?,?,?,?)",
                                       [account, .integer((revisions[replacement.accountID] ?? 0) + 1), .blob(replacement.data), .integer(Int(replacement.deviceID))])
            }
        }
    }

    /// Every account with saved encryption state, in the spelling its row is keyed by.
    public func encryptionStateAccountIDs() throws -> [String] {
        try connection.query("SELECT account_id FROM encryption_state").map { $0[0].string }
    }

    /// A failed comparison or any persistence error rolls back the whole operation. The caller
    /// must discard its mutated in-memory engine and reload; no crypto callback writes separately.
    public func saveEncryptionState(accountID: String, expectedRevision: Int?, data: Data, control: EncryptionControl? = nil) throws {
        try connection.transaction {
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: data)
            if let control { try insertEncryptionControl(accountID: accountID, control: control) }
        }
    }

    /// A key transport is sealed the moment it exists: its wire never depends on later preparation.
    private func insertEncryptionControl(accountID: String, control: EncryptionControl) throws {
        guard !control.id.isEmpty, control.id.utf8.count <= 1024,
              !control.recipient.isEmpty, control.recipient.utf8.count <= 3071,
              !control.wire.isEmpty, control.wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try insertUpdate(accountID: accountID, id: control.id, kind: .keyTransport, chatID: control.recipient, createdAt: Date(),
                         targetMessageID: nil, targetWireID: nil, reactionsJSON: nil, wire: control.wire)
    }

    /// Outgoing stream message IDs must identify exactly one durable operation, whatever its kind.
    private func insertUpdate(accountID: String, id: String, kind: StoredUpdate.Kind, chatID: String, createdAt: Date,
                              targetMessageID: String?, targetWireID: String?, reactionsJSON: String?, wire: Data?) throws {
        guard try message(accountID: accountID, messageID: id) == nil,
              try connection.query("SELECT 1 FROM outgoing_updates WHERE account_id=? AND id=?", [.text(accountID), .text(id)]).isEmpty else { throw MessageStoreError.conflictingIdentity }
        try connection.execute("INSERT INTO outgoing_updates(account_id,id,kind,chat_id,target_message_id,target_wire_id,reactions_json,created_at,state,wire) VALUES(?,?,?,?,?,?,?,?,'queued',?)",
                               [.text(accountID), .text(id), .text(kind.rawValue), .text(chatID), targetMessageID.map(Value.text) ?? .null, targetWireID.map(Value.text) ?? .null,
                                reactionsJSON.map(Value.text) ?? .null, .real(createdAt.timeIntervalSince1970), wire.map(Value.blob) ?? .null])
    }

    private func writeEncryptionState(accountID: String, expectedRevision: Int?, data: Data) throws {
        guard !accountID.isEmpty, !data.isEmpty, data.count <= 16_777_216 else { throw MessageStoreError.invalidValue }
        let current = try connection.query("SELECT revision FROM encryption_state WHERE account_id=?", [.text(accountID)]).first?[0].integer
        guard current == expectedRevision, (current ?? 0) < Int.max else { throw MessageStoreError.invalidTransition }
        try connection.execute("""
            INSERT INTO encryption_state(account_id,revision,snapshot) VALUES(?,?,?)
            ON CONFLICT(account_id) DO UPDATE SET revision=excluded.revision,snapshot=excluded.snapshot,sealed_account=NULL
            """, [.text(accountID), .integer((current ?? 0) + 1), .blob(data)])
    }

    /// A message whose file has not finished uploading is durable but not yet sendable.
    /// A message waits while it, or anything queued before it in the same chat, is a file still uploading, so the
    /// peer sees files and the caption sent after them in the order they were written.
    /// The hold is bounded by the app: a file the server keeps refusing is failed (`UploadFailureBudget`), which
    /// takes it out of 'queued' and releases the chat.
    private static let uploadedOnly = """
         AND NOT EXISTS (SELECT 1 FROM outbox o JOIN attachments a ON a.account_id=o.account_id AND a.message_id=o.message_id AND a.upload_state='pending'
         JOIN messages m ON m.account_id=o.account_id AND m.id=o.message_id
         WHERE o.account_id=outbox.account_id AND o.state='queued' AND o.sequence<=outbox.sequence
         AND m.chat_id=(SELECT chat_id FROM messages WHERE account_id=outbox.account_id AND id=outbox.message_id))
        """

    public func queuedOutgoing(accountID: String) throws -> [StoredMessage] {
        try connection.query("""
            SELECT \(Self.columns) FROM messages WHERE account_id=? AND id IN
            (SELECT message_id FROM outbox WHERE account_id=? AND state='queued'\(Self.uploadedOnly))
            ORDER BY (SELECT sequence FROM outbox WHERE outbox.account_id=messages.account_id AND outbox.message_id=messages.id) LIMIT 1000
            """, [.text(accountID), .text(accountID)]).map(decodeRow)
    }

    /// Queued messages whose file still needs a PUT, oldest first.
    public func attachmentsAwaitingUpload(accountID: String) throws -> [StoredMessage] {
        try connection.query("""
            SELECT \(Self.columns) FROM messages WHERE account_id=? AND id IN
            (SELECT message_id FROM outbox WHERE account_id=? AND state='queued')
            AND EXISTS (SELECT 1 FROM attachments a WHERE a.account_id=messages.account_id AND a.message_id=messages.id AND a.upload_state='pending')
            ORDER BY (SELECT sequence FROM outbox WHERE outbox.account_id=messages.account_id AND outbox.message_id=messages.id) LIMIT 100
            """, [.text(accountID), .text(accountID)]).map(decodeRow)
    }

    /// Records the background task carrying this file and the slot's GET URL, so a relaunch can
    /// reattach and a finished task knows where the bytes landed. Nil clears both for a new slot.
    public func setAttachmentUploadTask(accountID: String, messageID: String, taskID: Int?, url: String?) throws {
        guard (taskID == nil) == (url == nil), url.map({ $0.utf8.count <= 2_048 }) ?? true else { throw MessageStoreError.invalidValue }
        try connection.execute("UPDATE attachments SET task_id=?,url=? WHERE account_id=? AND message_id=? AND upload_state='pending'",
                               [taskID.map(Value.integer) ?? .null, url.map(Value.text) ?? .null, .text(accountID), .text(messageID)])
    }

    /// The PUT returned success: the ciphertext at the recorded URL is what every attempt shares.
    public func markAttachmentUploaded(accountID: String, messageID: String) throws {
        try connection.execute("UPDATE attachments SET upload_state='uploaded',task_id=NULL WHERE account_id=? AND message_id=? AND upload_state='pending' AND url IS NOT NULL",
                               [.text(accountID), .text(messageID)])
    }

    /// The lowercased hosts of every file URL the account has stored: its upload slots' GET URLs and the files it
    /// received. Link previews never fetch from them.
    public func attachmentHosts(accountID: String) throws -> Set<String> {
        Set(try connection.query("SELECT DISTINCT url FROM attachments WHERE account_id=? AND url IS NOT NULL", [.text(accountID)])
            .compactMap { URL(string: $0[0].string)?.host()?.lowercased() })
    }

    public func encryptedOutgoing(accountID: String, messageID: String) throws -> Data? {
        try connection.query("SELECT wire FROM encrypted_outbox WHERE account_id=? AND message_id=?", [.text(accountID), .text(messageID)]).first?[0].data
    }

    /// Converts an already durable queued intention into exact ciphertext and commits the ratchet
    /// advancement in the SAME transaction. Never overwrites an existing encrypted attempt.
    public func sealQueuedOutgoing(accountID: String, messageID: String, profile: String,
                                   expectedRevision: Int, state: Data, wire: Data, authenticateWireID: Bool = true, clearReply: Bool = false,
                                   clearLinkPreview: Bool = false) throws {
        guard !profile.isEmpty, !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard try encryptedOutgoing(accountID: accountID, messageID: messageID) == nil,
                  try connection.query("SELECT state FROM outbox WHERE account_id=? AND message_id=?", [.text(accountID), .text(messageID)]).first?[0].string == "queued" else { throw MessageStoreError.invalidTransition }
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: state)
            try connection.execute("INSERT INTO encrypted_outbox(account_id,message_id,wire) VALUES(?,?,?)", [.text(accountID), .text(messageID), .blob(wire)])
            try connection.execute("UPDATE messages SET encryption_profile=?,wire_id=?,wire_id_authenticated=? WHERE account_id=? AND id=?", [.text(profile), authenticateWireID ? .text(messageID) : .null, .integer(profile == "modern" && authenticateWireID ? 1 : 0), .text(accountID), .text(messageID)])
            // The sealed content left the reply out; the stored message must not claim one.
            if clearReply { try connection.execute("UPDATE messages SET reply_json=NULL WHERE account_id=? AND id=?", [.text(accountID), .text(messageID)]) }
            // Nor a link preview: our bubble shows what the peer got.
            if clearLinkPreview { try connection.execute("DELETE FROM message_link_previews WHERE account_id=? AND message_id=?", [.text(accountID), .text(messageID)]) }
        }
    }

    public func hasEncryptedIncoming(accountID: String, sender: String, digest: String) throws -> Bool {
        try !connection.query("SELECT 1 FROM encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)]).isEmpty
    }

    /// Authenticated plaintext, consumed prekeys/ratchet changes and replay outcome are inseparable.
    /// A key-transport-only message commits state and replay outcome without creating an empty bubble.
    public func commitEncryptedIncoming(accountID: String, sender: String, digest: String,
                                        expectedRevision: Int, state: Data, message: StoredMessage?, control: EncryptionControl? = nil, reaction: AuthenticatedReaction? = nil,
                                        event: MessageEvent? = nil, groupRoom: String? = nil, roomStanzaID: String? = nil,
                                        groupMembers: [String] = [], archiveStanzaID: String? = nil, readMarker: OwnReadMarker? = nil,
                                        correctsEarlierMessage: Bool = false) throws {
        guard !sender.isEmpty, !digest.isEmpty,
              // Another device of this account said it displayed a peer message: nothing else rides with it.
              readMarker.map({ _ in message == nil && reaction == nil && event == nil && groupRoom == nil && sender == accountID }) ?? true,
              // A room's ids travel as `roomStanzaID`; this one is the account's own archive's.
              archiveStanzaID == nil || groupRoom == nil,
              message.map({ $0.accountID == accountID && $0.senderID == sender && $0.encryptionProfile != nil }) ?? true else { throw MessageStoreError.invalidValue }
        if let groupRoom {
            guard message.map({ $0.chatID == groupRoom }) ?? reaction.map({ $0.chatID == groupRoom }) ?? false, event == nil else { throw MessageStoreError.invalidValue }
        } else if roomStanzaID != nil || !groupMembers.isEmpty { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard try !hasEncryptedIncoming(accountID: accountID, sender: sender, digest: digest) else { throw MessageStoreError.invalidTransition }
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: state)
            if let reaction {
                guard message == nil, reaction.actorID == sender else { throw MessageStoreError.invalidValue }
                // Authenticated (SCE) reactions only reach here; plaintext ones go through `recordReaction` and never alert.
                let previous = try latestReaction(accountID: accountID, reaction: reaction)
                try insertEvent(accountID: accountID, event: try reaction.event(), groupRoom: groupRoom)
                try queueReactionNotification(accountID: accountID, reaction: reaction, previous: previous)
            }
            if let event {
                // Authenticated content about another message, never a bubble of its own: a peer's receipt, or a retraction/correction.
                guard message == nil, reaction == nil, groupRoom == nil, event.actorID == sender,
                      [.delivered, .displayed, .retraction, .correction].contains(event.kind) else { throw MessageStoreError.invalidValue }
                try insertEvent(accountID: accountID, event: event)
            }
            if let message {
                try connection.execute("INSERT INTO chats(account_id,id,title) VALUES(?,?,?) ON CONFLICT(account_id,id) DO NOTHING", [.text(accountID), .text(message.chatID), .text(message.chatID)])
                let inserted = try insertMessageInTransaction(message)
                if let groupRoom {
                    try connection.execute("INSERT INTO group_ciphertext_messages VALUES(?,?,?,?)", [.text(accountID), .text(sender), .text(digest), .text(message.id)])
                    if let roomStanzaID { try bindGroupReference(accountID: accountID, room: groupRoom, messageID: message.id, stanzaID: roomStanzaID) }
                }
                if let archiveStanzaID { try bindDirectStanzaID(accountID: accountID, messageID: message.id, stanzaID: archiveStanzaID) }
                // A room correction is still stored as its own row (the group decoder cannot resolve its target yet),
                // but it edits a message the user was already alerted about: it never alerts as a new message.
                if inserted, !correctsEarlierMessage, try queuesNotification(accountID: accountID, message: message, groupMembers: groupMembers) {
                    try connection.execute("INSERT INTO notification_candidates(account_id,message_id) VALUES(?,?)", [.text(accountID), .text(message.id)])
                }
            }
            try connection.execute("INSERT INTO encrypted_inbox(account_id,sender,digest,message_id) VALUES(?,?,?,?)",
                                   [.text(accountID), .text(sender), .text(digest), message.map { .text($0.id) } ?? .null])
            if let readMarker { _ = try advanceReadPointer(accountID: accountID, ownMarker: readMarker) }
            try connection.execute("DELETE FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)])
            if let control {
                guard control.recipient == sender else { throw MessageStoreError.invalidValue }
                try insertEncryptionControl(accountID: accountID, control: control)
            }
        }
    }

    /// Whether a newly committed incoming message may alert. Each notification rule (own/outgoing,
    /// read pointer, mute) is its own small condition here; runs inside the commit transaction.
    /// `groupMembers` are the room's members at decryption (bare JIDs), for the mass-mention rule.
    private func queuesNotification(accountID: String, message: StoredMessage, groupMembers: [String] = []) throws -> Bool {
        guard !message.isOutgoing, message.senderID != accountID else { return false }
        guard try isAfterReadPointer(accountID: accountID, message: message) else { return false }
        return try chatNotificationAllows(accountID: accountID, message: message, groupMembers: groupMembers)
    }

    /// Mute and mentions: a muted chat queues nothing; a mentions-only chat queues a message whose
    /// decrypted body mentions this account. Reads only local state; nothing here reaches the server.
    private func chatNotificationAllows(accountID: String, message: StoredMessage, groupMembers: [String], now: Date = Date()) throws -> Bool {
        guard let row = try connection.query("SELECT notification_level,muted_until,room_nickname FROM chats WHERE account_id=? AND id=?",
                                             [.text(accountID), .text(message.chatID)]).first else { return true }
        let setting = Self.notificationSetting(level: row[0], mutedUntil: row[1])
        if setting.isMuted(at: now) { return false }
        switch setting.level {
        case .all: return true
        case .mentions: return Mention.mentions(message.body, account: accountID, nickname: row[2].optionalString, members: groupMembers)
        }
    }

    private static func notificationSetting(level: Value, mutedUntil: Value) -> ChatNotificationSetting {
        let until: Date?
        switch mutedUntil {
        case .real(let seconds): until = Date(timeIntervalSince1970: seconds)
        case .integer(let seconds): until = Date(timeIntervalSince1970: TimeInterval(seconds))
        default: until = nil
        }
        return ChatNotificationSetting(level: ChatNotificationLevel(rawValue: level.string) ?? .all, mutedUntil: until)
    }

    public func chatNotificationSetting(accountID: String, chatID: String) throws -> ChatNotificationSetting {
        guard let row = try connection.query("SELECT notification_level,muted_until FROM chats WHERE account_id=? AND id=?",
                                             [.text(accountID), .text(chatID)]).first else { return ChatNotificationSetting() }
        return Self.notificationSetting(level: row[0], mutedUntil: row[1])
    }

    /// Every chat of the account with a setting other than the default, by chat ID.
    public func chatNotificationSettings(accountID: String) throws -> [String: ChatNotificationSetting] {
        var result: [String: ChatNotificationSetting] = [:]
        for row in try connection.query("SELECT id,notification_level,muted_until FROM chats WHERE account_id=? AND (notification_level<>'all' OR muted_until IS NOT NULL)", [.text(accountID)]) {
            result[row[0].string] = Self.notificationSetting(level: row[1], mutedUntil: row[2])
        }
        return result
    }

    /// Local only. A mute that is in force deletes the chat's pending candidates in the same transaction, so a later
    /// extension run cannot alert for them; notifications already delivered stay (muting stops future alerts only).
    /// A level change applies to messages committed afterwards.
    public func setChatNotificationSetting(accountID: String, chatID: String, _ setting: ChatNotificationSetting) throws {
        guard !accountID.isEmpty, !chatID.isEmpty, setting.mutedUntil.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            try connection.execute("UPDATE chats SET notification_level=?,muted_until=? WHERE account_id=? AND id=?",
                                   [.text(setting.level.rawValue), setting.mutedUntil.map { .real($0.timeIntervalSince1970) } ?? .null, .text(accountID), .text(chatID)])
            guard try connection.query("SELECT changes()").first?[0].integer == 1 else { throw MessageStoreError.invalidValue }
            if setting.isMuted() {
                try connection.execute("""
                    DELETE FROM notification_candidates WHERE account_id=?1
                    AND message_id IN (SELECT id FROM messages WHERE account_id=?1 AND chat_id=?2)
                    """, [.text(accountID), .text(chatID)])
                try connection.execute("DELETE FROM pending_notification_candidates WHERE account_id=? AND chat_id=?", [.text(accountID), .text(chatID)])
                try connection.execute("DELETE FROM reaction_notification_candidates WHERE account_id=? AND chat_id=?", [.text(accountID), .text(chatID)])
            }
        }
    }

    /// This account's own nickname in `room`, kept on the device so a commit (app or extension) can detect mentions.
    public func setGroupNickname(accountID: String, room: String, nickname: String) throws {
        guard !accountID.isEmpty, !room.isEmpty, !nickname.isEmpty, nickname.utf8.count <= 128 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            try connection.execute("UPDATE chats SET room_nickname=? WHERE account_id=? AND id=?", [.text(nickname), .text(accountID), .text(room)])
            guard try connection.query("SELECT changes()").first?[0].integer == 1 else { throw MessageStoreError.invalidValue }
        }
    }

    /// The nickname `setGroupNickname` kept for `room`; nil for a room joined before the store kept it. The extension
    /// and notification actions rejoin with it, so the room sees the same occupant the app is.
    public func groupNickname(accountID: String, room: String) throws -> String? {
        try connection.query("SELECT room_nickname FROM chats WHERE account_id=? AND id=?", [.text(accountID), .text(room)]).first?[0].optionalString
    }

    /// Test seam: the queued candidates' message IDs, oldest first.
    func pendingNotificationMessageIDs(accountID: String) throws -> [String] {
        try connection.query("SELECT message_id FROM notification_candidates WHERE account_id=? ORDER BY sequence", [.text(accountID)]).map { $0[0].string }
    }

    /// Read-state condition (stream B): a message at or below its chat's read pointer was already read, on this device
    /// or another (MAM catch-up of history an other device displayed), so it never alerts. The row exists already.
    private func isAfterReadPointer(accountID: String, message: StoredMessage) throws -> Bool {
        if try connection.query("SELECT 1 FROM messages WHERE account_id=? AND id=?", [.text(accountID), .text(message.id)]).isEmpty {
            // Retained ciphertext has no row yet: compare its time with the chat's pointer and with the history
            // baseline of the archive that holds the chat, the same two rules a message row is held to.
            guard try connection.query("SELECT 1 FROM chat_read_state WHERE account_id=? AND chat_id=? AND read_sent_at>=?",
                                       [.text(accountID), .text(message.chatID), .real(message.sentAt.timeIntervalSince1970)]).isEmpty else { return false }
            return try !isReactionHistory(accountID: accountID, chatID: message.chatID, at: message.sentAt)
        }
        return try connection.query("SELECT 1 FROM messages m \(Self.readJoins) WHERE m.account_id=?1 AND m.id=?2 AND NOT \(Self.unreadCondition)",
                             [.text(accountID), .text(message.id)]).isEmpty
    }

    public func notificationPreviewsEnabled(accountID: String) throws -> Bool { try accountPreferences(accountID: accountID).notificationPreviews }

    public func setNotificationPreviews(accountID: String, enabled: Bool) throws {
        var preferences = try accountPreferences(accountID: accountID)
        preferences.notificationPreviews = enabled
        try setAccountPreferences(accountID: accountID, preferences)
    }

    public func accountPreferences(accountID: String) throws -> AccountPreferences {
        guard let row = try connection.query("SELECT previews,delivery_receipts,read_receipts,last_seen,reaction_alerts FROM account_preferences WHERE account_id=?", [.text(accountID)]).first else { return AccountPreferences() }
        return AccountPreferences(notificationPreviews: row[0].integer != 0, deliveryReceipts: row[1].integer != 0, readReceipts: row[2].integer != 0, lastSeen: row[3].integer != 0,
                                  reactionNotifications: row[4].integer != 0)
    }

    /// Turning reaction alerts off also drops the reaction candidates still waiting, so a later run cannot post them.
    public func setAccountPreferences(accountID: String, _ preferences: AccountPreferences) throws {
        try requireTransportOwnership()
        guard !accountID.isEmpty else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            try connection.execute("INSERT INTO account_preferences(account_id,previews,delivery_receipts,read_receipts,last_seen,reaction_alerts) VALUES(?,?,?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET previews=excluded.previews,delivery_receipts=excluded.delivery_receipts,read_receipts=excluded.read_receipts,last_seen=excluded.last_seen,reaction_alerts=excluded.reaction_alerts",
                                   [.text(accountID), .integer(preferences.notificationPreviews ? 1 : 0), .integer(preferences.deliveryReceipts ? 1 : 0),
                                    .integer(preferences.readReceipts ? 1 : 0), .integer(preferences.lastSeen ? 1 : 0), .integer(preferences.reactionNotifications ? 1 : 0)])
            if !preferences.reactionNotifications {
                try connection.execute("DELETE FROM reaction_notification_candidates WHERE account_id=?", [.text(accountID)])
            }
        }
    }

    /// The foreground owner has already presented these messages. This is notification
    /// bookkeeping, not a read receipt. It cannot race the extension's transport owner.
    public func dismissPendingMessageNotifications(accountID: String) throws {
        try requireTransportOwnership()
        try connection.transaction {
            try connection.execute("DELETE FROM notification_candidates WHERE account_id=?", [.text(accountID)])
            try connection.execute("DELETE FROM pending_notification_candidates WHERE account_id=?", [.text(accountID)])
            try connection.execute("DELETE FROM reaction_notification_candidates WHERE account_id=?", [.text(accountID)])
        }
    }

    /// The chat was opened: its reactions are on screen, so none of them may still alert, and none that was delivered is
    /// current any more. Reactions have no read pointer of their own. Delivered ones go with the chat's thread
    /// (`DeliveredNotificationCleaner.removeThread`). Like `dismissPendingMessageNotifications` it needs the transport
    /// lease, so it cannot race an extension run that already read the candidates it is about to post.
    public func dismissReactionNotifications(accountID: String, chatID: String) throws {
        try requireTransportOwnership()
        try connection.transaction {
            try connection.execute("DELETE FROM reaction_notification_candidates WHERE account_id=? AND chat_id=?", [.text(accountID), .text(chatID)])
            try connection.execute("DELETE FROM reaction_notifications_posted WHERE account_id=? AND chat_id=?", [.text(accountID), .text(chatID)])
        }
    }

    /// Plan D8 cap: reaction requests per run. Older reaction rows of the same run are claimed without a request.
    public static let reactionNotificationsPerRun = 8

    /// Plan D4 limits: requests per chat and per run.
    public static let notificationsPerChat = 8
    public static let notificationsPerRun = 20

    /// A bounded, read-only claim of the account's notification candidates. The newest `perChat` of each chat
    /// and the newest `total` overall are selected and returned oldest first; older candidates of a selected chat are
    /// folded into that chat's "and N more" and claimed with it; chats beyond the total cap stay for a later run and are
    /// counted in `deferredChatCount`, which the planner turns into one visible summary request. Messages their sender
    /// has since unsent are claimed without taking a slot, so they never hide an older message's "and N more".
    /// Nothing is deleted here: the caller posts, then passes `claimed` to `removeNotificationCandidates`. A crash in
    /// between reposts the same stable identifiers, which replace rather than duplicate.
    public func pendingNotifications(accountID: String, perChat: Int = MessageStore.notificationsPerChat,
                                     total: Int = MessageStore.notificationsPerRun) throws -> MessageNotification {
        try requireTransportOwnership()
        guard perChat > 0, total > 0, total <= 64 else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let account = Value.text(accountID)
            let rows = try connection.query("""
                SELECT 0,n.message_id,NULL,NULL,m.chat_id,m.sent_at,n.sequence FROM notification_candidates n
                JOIN messages m ON m.account_id=n.account_id AND m.id=n.message_id WHERE n.account_id=?
                UNION ALL
                SELECT 1,NULL,p.sender,p.digest,p.chat_id,p.sent_at,p.sequence FROM pending_notification_candidates p WHERE p.account_id=?
                ORDER BY 6 DESC,1,7 DESC LIMIT 1000
                """, [account, account])
            struct Row { let key: NotificationCandidateKey; let chatID: String; let sentAt: Double }
            let candidates = rows.map { row in
                Row(key: row[0].integer == 0 ? .message(row[1].string) : .pending(sender: row[2].string, digest: row[3].string),
                    chatID: row[4].string, sentAt: row[5].double)
            }
            // Newest first: the first `perChat` shown rows of a chat are its window; a chat's unselected rows are older than its selected ones.
            var selected: [(row: Row, candidate: NotificationCandidate)] = [], selectedPerChat: [String: Int] = [:]
            var unselected: [Row] = [], silent: [NotificationCandidateKey] = []
            for row in candidates {
                let count = selectedPerChat[row.chatID, default: 0]
                guard count < perChat, selected.count < total else { unselected.append(row); continue }
                guard let candidate = try notificationCandidate(accountID: accountID, key: row.key, chatID: row.chatID,
                                                                sentAt: Date(timeIntervalSince1970: row.sentAt), earlierCount: 0),
                      !candidate.isRetracted else { silent.append(row.key); continue }
                selected.append((row, candidate)); selectedPerChat[row.chatID] = count + 1
            }
            let summarized = unselected.filter { selectedPerChat[$0.chatID] != nil }
            let deferred = unselected.filter { selectedPerChat[$0.chatID] == nil }
            let earlier = Dictionary(grouping: summarized, by: \.chatID).mapValues(\.count)
            var oldestSelected: [String: NotificationCandidateKey] = [:]
            for entry in selected { oldestSelected[entry.row.chatID] = entry.row.key }
            let result = selected.reversed().map { entry in
                oldestSelected[entry.row.chatID] == entry.row.key ? entry.candidate.withEarlierCount(earlier[entry.row.chatID] ?? 0) : entry.candidate
            }
            let (reactions, reactionClaims) = try pendingReactionNotifications(accountID: accountID)
            return MessageNotification(candidates: result, claimed: selected.map(\.row.key) + silent + summarized.map(\.key) + reactionClaims,
                                       deferredCount: deferred.count, deferredChatCount: Set(deferred.map(\.chatID)).count,
                                       previewsEnabled: try notificationPreviewsEnabled(accountID: accountID), reactions: reactions)
        }
    }

    private func notificationCandidate(accountID: String, key: NotificationCandidateKey, chatID: String, sentAt: Date,
                                       earlierCount: Int) throws -> NotificationCandidate? {
        let senderID: String, content: NotificationCandidate.Content, when: Date
        switch key {
        case let .message(id):
            guard let stored = try message(accountID: accountID, messageID: id) else { return nil }
            senderID = stored.senderID; when = stored.sentAt
            if stored.unreadableReason != nil || stored.encryptionProfile == Self.unreadableProfile {
                content = .unreadable(messageID: id)
            } else {
                content = .message(stored.applying(try events(accountID: accountID, chatID: stored.chatID, messageID: stored.id)))
            }
        case let .pending(sender, _):
            senderID = sender; when = sentAt; content = .pendingEncrypted
        case .reaction:
            return nil
        }
        let chat = try connection.query("SELECT title,avatar_hash FROM chats WHERE account_id=? AND id=?", [.text(accountID), .text(chatID)]).first
        let isGroup = chatID != senderID
        let sender = isGroup ? try participant(accountID: accountID, id: senderID) : nil
        return NotificationCandidate(key: key, accountID: accountID, chatID: chatID, chatTitle: chat?[0].string, chatAvatarHash: chat?[1].optionalString,
                                     senderID: senderID, senderTitle: sender?.title, senderAvatarHash: sender?.avatarHash, isGroup: isGroup,
                                     sentAt: when, content: content, earlierCount: earlierCount,
                                     groupMembers: isGroup ? try groupMembers(accountID: accountID, room: chatID, excluding: senderID) : [])
    }

    /// A person as notifications name them: the title and avatar of their direct chat, when there is one.
    private func participant(accountID: String, id: String) throws -> NotificationParticipant {
        let row = try connection.query("SELECT title,avatar_hash FROM chats WHERE account_id=? AND id=?", [.text(accountID), .text(id)]).first
        return NotificationParticipant(id: id, title: row?[0].string, avatarHash: row?[1].optionalString)
    }

    /// Other members a room's recent history shows (never the account itself), newest speakers first, at most eight.
    /// Local knowledge only: a communication notification names them as the conversation's other recipients.
    private func groupMembers(accountID: String, room: String, excluding author: String) throws -> [NotificationParticipant] {
        try connection.query("""
            SELECT sender_id FROM (SELECT sender_id,MAX(sent_at) AS newest FROM (
                SELECT sender_id,sent_at FROM messages WHERE account_id=?1 AND chat_id=?2 ORDER BY sent_at DESC,id DESC LIMIT 200)
            WHERE sender_id<>?1 AND sender_id<>?3 AND sender_id<>?2 GROUP BY sender_id) ORDER BY newest DESC,sender_id LIMIT 8
            """, [.text(accountID), .text(room), .text(author)]).map { try participant(accountID: accountID, id: $0[0].string) }
    }

    // MARK: Reaction notifications

    /// This actor's newest stored reaction set on the same target wire ID, before a new event is inserted.
    private func latestReaction(accountID: String, reaction: AuthenticatedReaction) throws -> (id: String, reactions: [String])? {
        guard let row = try connection.query("""
            SELECT id,payload_json FROM message_events WHERE account_id=? AND chat_id=? AND actor_id=? AND target_wire_id=? AND kind='reaction'
            ORDER BY updated_at DESC,id DESC LIMIT 1
            """, [.text(accountID), .text(reaction.chatID), .text(reaction.actorID), .text(reaction.targetWireID)]).first else { return nil }
        return (row[0].string, (try? JSONDecoder().decode([String].self, from: Data(row[1].string.utf8))) ?? [])
    }

    /// Inside the commit transaction of an authenticated reaction. Another person's reaction to one of this account's
    /// messages becomes (or replaces) one candidate per actor and target, holding the emoji they added. A removal, or a
    /// replacement that drops emoji, trims or deletes the waiting candidate; delivered notifications of a withdrawn
    /// reaction are removed by cleanup (`liveReactionNotifications`). Never for own reactions, reactions to other
    /// people's messages, an event older than the actor's newest, a muted chat, history before the archive baseline, or
    /// with the account's reaction switch off.
    private func queueReactionNotification(accountID: String, reaction: AuthenticatedReaction, previous: (id: String, reactions: [String])?) throws {
        guard reaction.actorID != accountID,
              let latest = try latestReaction(accountID: accountID, reaction: reaction), latest.id == reaction.id,
              let target = try reactionTarget(accountID: accountID, chatID: reaction.chatID, wireID: reaction.targetWireID),
              target.isOutgoing || target.senderID == accountID else { return }
        let key: [Value] = [.text(accountID), .text(reaction.chatID), .text(reaction.actorID), .text(target.id)]
        let waiting = try connection.query("""
            SELECT reactions_json FROM reaction_notification_candidates WHERE account_id=? AND chat_id=? AND actor_id=? AND target_message_id=?
            """, key).first.map { (try? JSONDecoder().decode([String].self, from: Data($0[0].string.utf8))) ?? [] }
        let current = Set(reaction.reactions)
        let added = current.subtracting(previous.map { previous in previous.id == reaction.id ? current : Set(previous.reactions) } ?? [])
        var shown: [String]
        if added.isEmpty {
            guard let waiting else { return }
            shown = waiting.filter(current.contains)
        } else {
            guard try accountPreferences(accountID: accountID).reactionNotifications,
                  try !chatNotificationSetting(accountID: accountID, chatID: reaction.chatID).isMuted(),
                  try !isReactionHistory(accountID: accountID, chatID: reaction.chatID, at: reaction.updatedAt) else { return }
            shown = Array(Set(waiting ?? []).intersection(current).union(added))
        }
        shown.sort()
        // A new row (and sequence) per version: a run that claimed the old one deletes only what it posted.
        try connection.execute("DELETE FROM reaction_notification_candidates WHERE account_id=? AND chat_id=? AND actor_id=? AND target_message_id=?", key)
        guard !shown.isEmpty else { return }
        try connection.execute("""
            INSERT INTO reaction_notification_candidates(account_id,chat_id,actor_id,target_message_id,reactions_json,reacted_at) VALUES(?,?,?,?,?,?)
            """, key + [.text(try Self.reactionJSON(shown)), .real(reaction.updatedAt.timeIntervalSince1970)])
    }

    /// No newer than the history baseline of the archive that holds the chat: fetched history, never news. Shared by
    /// reactions and retained ciphertext, which have no message row to hold to `unreadCondition`.
    private func isReactionHistory(accountID: String, chatID: String, at date: Date) throws -> Bool {
        try !connection.query("""
            SELECT 1 WHERE ?3 <= COALESCE((SELECT sent_at FROM read_baselines WHERE account_id=?1 AND archive_id=?2),
                                          (SELECT sent_at FROM read_baselines WHERE account_id=?1 AND archive_id=?1), -1e308)
            """, [.text(accountID), .text(chatID), .real(date.timeIntervalSince1970)]).isEmpty
    }

    /// Runs inside `pendingNotifications`' transaction: the newest reaction rows (at most `reactionNotificationsPerRun`
    /// with a current target) oldest first, and every row considered, which the run deletes after posting.
    private func pendingReactionNotifications(accountID: String) throws -> ([ReactionNotificationCandidate], [NotificationCandidateKey]) {
        let rows = try connection.query("""
            SELECT sequence,chat_id,actor_id,target_message_id,reactions_json,reacted_at FROM reaction_notification_candidates
            WHERE account_id=? ORDER BY reacted_at DESC,sequence DESC LIMIT 200
            """, [.text(accountID)])
        var result: [ReactionNotificationCandidate] = []
        for row in rows where result.count < Self.reactionNotificationsPerRun {
            let chatID = row[1].string, actorID = row[2].string
            guard let stored = try message(accountID: accountID, messageID: row[3].string), stored.chatID == chatID,
                  stored.isOutgoing || stored.senderID == accountID,
                  let reactions = try? JSONDecoder().decode([String].self, from: Data(row[4].string.utf8)), !reactions.isEmpty else { continue }
            let target = stored.applying(try events(accountID: accountID, chatID: chatID, messageID: stored.id))
            guard !target.isRetracted else { continue }
            let chat = try connection.query("SELECT title,avatar_hash FROM chats WHERE account_id=? AND id=?", [.text(accountID), .text(chatID)]).first
            let isGroup = chatID != actorID
            result.append(ReactionNotificationCandidate(key: .reaction(sequence: row[0].integer), accountID: accountID, chatID: chatID,
                chatTitle: chat?[0].string, chatAvatarHash: chat?[1].optionalString,
                actor: isGroup ? try participant(accountID: accountID, id: actorID)
                               : NotificationParticipant(id: actorID, title: chat?[0].string, avatarHash: chat?[1].optionalString),
                isGroup: isGroup, target: target, reactions: reactions, reactedAt: Date(timeIntervalSince1970: row[5].double),
                groupMembers: isGroup ? try groupMembers(accountID: accountID, room: chatID, excluding: actorID) : []))
        }
        return (result.reversed(), rows.map { .reaction(sequence: $0[0].integer) })
    }

    /// Of the reaction notifications cleanup finds delivered, keyed by their target messages: which are still current.
    /// One is current while a newer version waits to replace it, or while everything it showed is still among the
    /// actor's reactions. A delivered one missing here was withdrawn, in part or whole, its target is gone, or its chat
    /// was read or opened since it was posted (reactions have no read state of their own).
    public func liveReactionNotifications(accountID: String, targetMessageIDs: Set<String>) throws -> Set<LiveReactionNotification> {
        guard targetMessageIDs.count <= 1000 else { throw MessageStoreError.invalidValue }
        var live = Set<LiveReactionNotification>()
        for id in targetMessageIDs.sorted() {
            guard let stored = try message(accountID: accountID, messageID: id), stored.isOutgoing || stored.senderID == accountID else { continue }
            let current = Dictionary(try reactions(accountID: accountID, chatID: stored.chatID, messageID: id).map { ($0.actorID, Set($0.reactions)) },
                                     uniquingKeysWith: { first, _ in first })
            let waiting = Set(try connection.query("SELECT actor_id FROM reaction_notification_candidates WHERE account_id=? AND chat_id=? AND target_message_id=?",
                                                   [.text(accountID), .text(stored.chatID), .text(id)]).map { $0[0].string })
            let posted = try connection.query("SELECT actor_id,reactions_json FROM reaction_notifications_posted WHERE account_id=? AND chat_id=? AND target_message_id=?",
                                              [.text(accountID), .text(stored.chatID), .text(id)])
            var actors = waiting
            for row in posted {
                let shown = Set((try? JSONDecoder().decode([String].self, from: Data(row[1].string.utf8))) ?? [])
                if let now = current[row[0].string], !shown.isEmpty, shown.isSubset(of: now) { actors.insert(row[0].string) }
            }
            for actor in actors where actor != accountID {
                live.insert(LiveReactionNotification(chatID: stored.chatID, actorID: actor, targetMessageID: id))
            }
        }
        return live
    }

    /// Test seam: each waiting reaction candidate as (actor, target message, emoji), oldest first.
    func pendingReactionCandidates(accountID: String) throws -> [(actor: String, target: String, reactions: [String])] {
        try connection.query("SELECT actor_id,target_message_id,reactions_json FROM reaction_notification_candidates WHERE account_id=? ORDER BY sequence", [.text(accountID)])
            .map { ($0[0].string, $0[1].string, (try? JSONDecoder().decode([String].self, from: Data($0[2].string.utf8))) ?? []) }
    }

    /// Deletes exactly the claimed rows, after their requests were posted. Rows that disappeared meanwhile are ignored.
    public func removeNotificationCandidates(accountID: String, keys: [NotificationCandidateKey]) throws {
        try requireTransportOwnership()
        guard keys.count <= 2000 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            for key in keys {
                switch key {
                case let .message(id):
                    try connection.execute("DELETE FROM notification_candidates WHERE account_id=? AND message_id=?", [.text(accountID), .text(id)])
                case let .pending(sender, digest):
                    try connection.execute("DELETE FROM pending_notification_candidates WHERE account_id=? AND sender=? AND digest=?",
                                           [.text(accountID), .text(sender), .text(digest)])
                case let .reaction(sequence):
                    // Remember what was posted; a replacement that arrived meanwhile has a new sequence and stays.
                    try connection.execute("""
                        INSERT INTO reaction_notifications_posted(account_id,chat_id,actor_id,target_message_id,reactions_json)
                        SELECT account_id,chat_id,actor_id,target_message_id,reactions_json FROM reaction_notification_candidates
                        WHERE account_id=? AND sequence=?
                        ON CONFLICT(account_id,chat_id,actor_id,target_message_id) DO UPDATE SET reactions_json=excluded.reactions_json
                        """, [.text(accountID), .integer(sequence)])
                    try connection.execute("DELETE FROM reaction_notification_candidates WHERE account_id=? AND sequence=?",
                                           [.text(accountID), .integer(sequence)])
                }
            }
        }
    }

    /// Of the messages behind delivered notifications, those that should no longer be shown: missing, or retracted by
    /// their sender. Read state is a separate rule.
    public func staleNotificationMessageIDs(accountID: String, messageIDs: [String]) throws -> Set<String> {
        guard messageIDs.count <= 1000 else { throw MessageStoreError.invalidValue }
        var stale = Set<String>()
        for id in Set(messageIDs) {
            guard let stored = try message(accountID: accountID, messageID: id) else { stale.insert(id); continue }
            if stored.applying(try events(accountID: accountID, chatID: stored.chatID, messageID: id)).isRetracted { stale.insert(id) }
        }
        return stale
    }

    public func message(accountID: String, messageID: String) throws -> StoredMessage? {
        try connection.query("SELECT \(Self.columns) FROM messages WHERE account_id=? AND id=?",
                             [.text(accountID), .text(messageID)]).first.map(decodeRow)
    }

    /// Caller first verifies authenticated self-archive/carbon provenance, recipient and complete
    /// ciphertext envelope. Exact saved bytes fence replacement/cross-account associations here.
    /// An archived copy proves server acceptance even if a manual retry has returned it to queued.
    @discardableResult public func reconcileArchivedOutgoing(accountID: String, messageID: String,
                                                              expectedEncryptedWire: Data, groupRoom: String? = nil, roomStanzaID: String? = nil) throws -> Bool {
        try requireTransportOwnership()
        guard !accountID.isEmpty, !messageID.isEmpty, !expectedEncryptedWire.isEmpty,
              expectedEncryptedWire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            guard try encryptedOutgoing(accountID: accountID, messageID: messageID) == expectedEncryptedWire else { return false }
            if let groupRoom, let roomStanzaID { try bindGroupReference(accountID: accountID, room: groupRoom, messageID: messageID, stanzaID: roomStanzaID) }
            else if roomStanzaID != nil { throw MessageStoreError.invalidValue }
            // Our archive keeps what we sent before the server routes it, so a returned message has an archived copy
            // too: it proves acceptance, never delivery, and cannot tell a retry from the attempt that was returned.
            try connection.execute("""
                UPDATE outbox SET state='serverAccepted',attempt_id=NULL WHERE account_id=? AND message_id=?
                AND state IN ('queued','submitting','unconfirmed','failed','serverAccepted') AND returned=0
                AND EXISTS (SELECT 1 FROM messages WHERE messages.account_id=outbox.account_id
                            AND messages.id=outbox.message_id AND messages.outgoing=1 AND messages.sender_id=?)
                """, [.text(accountID), .text(messageID), .text(accountID)])
            return try connection.query("SELECT changes()").first?[0].integer == 1
        }
    }

    public func streamManagementState(accountID: String) throws -> StreamManagementState? {
        guard let row = try connection.query("SELECT revision,snapshot FROM stream_management WHERE account_id=?", [.text(accountID)]).first else { return nil }
        guard let data = row[1].data else { throw MessageStoreError.invalidValue }
        return StreamManagementState(revision: row[0].integer, data: data)
    }

    /// Protocol validates the authenticated SM counter/window before calling this method. Snapshot
    /// trimming and server-acceptance metadata commit together; late socket callbacks cannot regress it.
    /// Only local outbox identities can be acknowledged, never arbitrary incoming sender claims.
    @discardableResult public func saveStreamManagement(accountID: String, expectedRevision: Int?, data: Data,
                                                        acknowledgedMessageIDs: [String] = []) throws -> Int {
        try requireTransportOwnership()
        guard !accountID.isEmpty, !data.isEmpty, data.count <= 4_194_304,
              acknowledgedMessageIDs.count <= 2000,
              acknowledgedMessageIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let current = try connection.query("SELECT revision FROM stream_management WHERE account_id=?", [.text(accountID)]).first?[0].integer
            guard current == expectedRevision, (current ?? 0) < Int.max else { throw MessageStoreError.invalidTransition }
            let next = (current ?? 0) + 1
            try connection.execute("""
                INSERT INTO stream_management(account_id,revision,snapshot) VALUES(?,?,?)
                ON CONFLICT(account_id) DO UPDATE SET revision=excluded.revision,snapshot=excluded.snapshot
                """, [.text(accountID), .integer(next), .blob(data)])
            for id in Set(acknowledgedMessageIDs) {
                // Controls/IQs may also have stream IDs but never become message-delivery metadata.
                try connection.execute("""
                    UPDATE outbox SET state='serverAccepted',attempt_id=NULL
                    WHERE account_id=? AND message_id=? AND state IN ('submitting','unconfirmed','serverAccepted')
                    """, [.text(accountID), .text(id)])
                try connection.execute("UPDATE outgoing_updates SET state='serverAccepted',attempt_id=NULL WHERE account_id=? AND id=? AND state IN ('submitting','unconfirmed','serverAccepted')", [.text(accountID), .text(id)])
            }
            return next
        }
    }

    /// Bounded deliberate-rejection receipt for authenticated archive wrappers with
    /// unsupported inner content. No plaintext, author claim or secret material is stored.
    /// An optional placeholder commits in the same transaction; its validation failure rolls back both.
    public func recordArchiveRejection(accountID: String, archiveID: String, messageID: String, reason: String,
                                       placeholder: UnreadableMessage? = nil) throws {
        try requireTransportOwnership()
        guard !accountID.isEmpty, accountID.utf8.count <= 3071, !archiveID.isEmpty, archiveID.utf8.count <= 3071, !messageID.isEmpty, messageID.utf8.count <= 1024,
              Self.archiveRejectionReasons.contains(reason) else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            try connection.execute("INSERT INTO archive_rejections(account_id,archive_id,message_id,reason) VALUES(?,?,?,?) ON CONFLICT(account_id,archive_id,message_id) DO NOTHING", [.text(accountID), .text(archiveID), .text(messageID), .text(reason)])
            if let placeholder {
                guard placeholder.accountID == accountID else { throw MessageStoreError.invalidValue }
                try Self.validate(placeholder)
                _ = try insertUnreadableInTransaction(placeholder)
            }
            try connection.execute("DELETE FROM archive_rejections WHERE account_id=? AND sequence NOT IN (SELECT sequence FROM archive_rejections WHERE account_id=? ORDER BY sequence DESC LIMIT 1000)", [.text(accountID), .text(accountID)])
        }
    }
    /// Raw values of every protocol `XMPPArchiveRejection` case.
    private static let archiveRejectionReasons: Set<String> = ["unverifiableEncryptedGroup", "foreignSender", "unsupportedDirectContent", "malformedEncryptedContent"]
    public func hasArchiveRejection(accountID: String, archiveID: String, messageID: String) throws -> Bool {
        try !connection.query("SELECT 1 FROM archive_rejections WHERE account_id=? AND archive_id=? AND message_id=?", [.text(accountID), .text(archiveID), .text(messageID)]).isEmpty
    }

    public func archiveCheckpoint(accountID: String, archiveID: String) throws -> ArchiveCheckpoint? {
        guard let row = try connection.query("SELECT revision,cursor,stamp FROM archive_checkpoints WHERE account_id=? AND archive_id=?", [.text(accountID), .text(archiveID)]).first else { return nil }
        return ArchiveCheckpoint(revision: row[0].integer, cursor: row[1].string, stamp: row[2].optionalDate)
    }

    /// Advance only after all page results have committed to durable inbox/message storage. CAS
    /// prevents a late page from another synchronization run from overwriting newer progress.
    /// `stamp` is the archive time of the entry `cursor` names (`ArchiveCheckpoint.stamp`).
    @discardableResult public func saveArchiveCheckpoint(accountID: String, archiveID: String,
                                                         expectedRevision: Int?, cursor: String, stamp: Date? = nil) throws -> Int {
        try requireTransportOwnership()
        guard !accountID.isEmpty, !archiveID.isEmpty, !cursor.isEmpty, cursor.utf8.count <= 4096 else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let current = try connection.query("SELECT revision FROM archive_checkpoints WHERE account_id=? AND archive_id=?", [.text(accountID), .text(archiveID)]).first?[0].integer
            guard current == expectedRevision, (current ?? 0) < Int.max else { throw MessageStoreError.invalidTransition }
            let next = (current ?? 0) + 1
            try connection.execute("""
                INSERT INTO archive_checkpoints(account_id,archive_id,revision,cursor,stamp) VALUES(?,?,?,?,?)
                ON CONFLICT(account_id,archive_id) DO UPDATE SET revision=excluded.revision,cursor=excluded.cursor,stamp=excluded.stamp
                """, [.text(accountID), .text(archiveID), .integer(next), .text(cursor), stamp.map { .real($0.timeIntervalSince1970) } ?? .null])
            return next
        }
    }

    /// Records that the server no longer held `cursor`, once per lost cursor (see `ArchiveGap`).
    public func recordArchiveGap(accountID: String, archiveID: String, cursor: String, since: Date?, detectedAt: Date = Date()) throws {
        try requireTransportOwnership()
        guard !accountID.isEmpty, !archiveID.isEmpty, !cursor.isEmpty, cursor.utf8.count <= 4096 else { throw MessageStoreError.invalidValue }
        try connection.execute("INSERT OR IGNORE INTO archive_gaps(account_id,archive_id,cursor,since,detected_at) VALUES(?,?,?,?,?)",
                               [.text(accountID), .text(archiveID), .text(cursor), since.map { .real($0.timeIntervalSince1970) } ?? .null,
                                .real(detectedAt.timeIntervalSince1970)])
    }

    /// Every recorded gap of the account, oldest detection first.
    public func archiveGaps(accountID: String) throws -> [ArchiveGap] {
        try connection.query("SELECT archive_id,since,detected_at FROM archive_gaps WHERE account_id=? ORDER BY detected_at,archive_id", [.text(accountID)]).map {
            ArchiveGap(archiveID: $0[0].string, since: $0[1].optionalDate, detectedAt: Date(timeIntervalSince1970: $0[2].double))
        }
    }

    /// The oldest archive ID this device holds for one archive's history, and whether the archive has nothing older.
    /// nil when the archive was never synchronized newest-first (see the v16 migration note).
    public func archiveBackfillCursor(accountID: String, archiveID: String) throws -> ArchiveBackfillCursor? {
        guard let row = try connection.query("SELECT revision,oldest_id,complete FROM archive_backfill WHERE account_id=? AND archive_id=?", [.text(accountID), .text(archiveID)]).first else { return nil }
        return ArchiveBackfillCursor(revision: row[0].integer, oldestID: row[1].string, complete: row[2].integer != 0)
    }

    /// Moves the backfill cursor only after the page it names has committed. CAS on `expectedRevision`
    /// (nil = no row yet), like `saveArchiveCheckpoint`, so a stale backfill run cannot rewind newer progress.
    @discardableResult public func saveArchiveBackfillCursor(accountID: String, archiveID: String, expectedRevision: Int?,
                                                             oldestID: String, complete: Bool) throws -> Int {
        try requireTransportOwnership()
        guard !accountID.isEmpty, !archiveID.isEmpty, !oldestID.isEmpty, oldestID.utf8.count <= 4096 else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let current = try connection.query("SELECT revision FROM archive_backfill WHERE account_id=? AND archive_id=?", [.text(accountID), .text(archiveID)]).first?[0].integer
            guard current == expectedRevision, (current ?? 0) < Int.max else { throw MessageStoreError.invalidTransition }
            let next = (current ?? 0) + 1
            try connection.execute("""
                INSERT INTO archive_backfill(account_id,archive_id,revision,oldest_id,complete) VALUES(?,?,?,?,?)
                ON CONFLICT(account_id,archive_id) DO UPDATE SET revision=excluded.revision,oldest_id=excluded.oldest_id,complete=excluded.complete
                """, [.text(accountID), .text(archiveID), .integer(next), .text(oldestID), .integer(complete ? 1 : 0)])
            return next
        }
    }

    /// The first page of a newest-first sync: the archive's first forward checkpoint and its backfill cursor commit in
    /// one transaction, so an interruption can never leave one without the other. Requires that the archive has no
    /// checkpoint yet, or, with `replacing`, that its checkpoint is at that revision: a walk whose cursor the server no
    /// longer holds and whose checkpoint has no `stamp` restarts from the newest page. A backfill row that is already
    /// there (an interrupted first sync of an earlier build, or history behind the lost cursor) is replaced: paging back
    /// from this newer page walks through whatever lies between, and reprocessing an entry is idempotent, whereas keeping
    /// the older cursor would leave the entries between the two pages unfetched by either walk.
    /// Returns the new checkpoint revision.
    /// `stamp` is the archive time of the entry `cursor` names (`ArchiveCheckpoint.stamp`).
    /// `historyThrough` is the newest archive timestamp in the page: the archive's read baseline (see `read_baselines`).
    @discardableResult public func saveNewestArchivePage(accountID: String, archiveID: String, cursor: String, stamp: Date? = nil,
                                                         oldestID: String, complete: Bool, historyThrough: Date? = nil,
                                                         replacing expectedRevision: Int? = nil) throws -> Int {
        try requireTransportOwnership()
        guard !accountID.isEmpty, !archiveID.isEmpty, !cursor.isEmpty, cursor.utf8.count <= 4096,
              !oldestID.isEmpty, oldestID.utf8.count <= 4096 else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let key: [Value] = [.text(accountID), .text(archiveID)]
            let current = try connection.query("SELECT revision FROM archive_checkpoints WHERE account_id=? AND archive_id=?", key).first?[0].integer
            guard current == expectedRevision, (current ?? 0) < Int.max else { throw MessageStoreError.invalidTransition }
            let backfill = try connection.query("SELECT revision FROM archive_backfill WHERE account_id=? AND archive_id=?", key).first?[0].integer
            guard (backfill ?? 0) < Int.max else { throw MessageStoreError.invalidTransition }
            try connection.execute("""
                INSERT INTO archive_backfill(account_id,archive_id,revision,oldest_id,complete) VALUES(?,?,?,?,?)
                ON CONFLICT(account_id,archive_id) DO UPDATE SET revision=excluded.revision,oldest_id=excluded.oldest_id,complete=excluded.complete
                """, key + [.integer((backfill ?? 0) + 1), .text(oldestID), .integer(complete ? 1 : 0)])
            let next = (current ?? 0) + 1
            try connection.execute("""
                INSERT INTO archive_checkpoints(account_id,archive_id,revision,cursor,stamp) VALUES(?,?,?,?,?)
                ON CONFLICT(account_id,archive_id) DO UPDATE SET revision=excluded.revision,cursor=excluded.cursor,stamp=excluded.stamp
                """, key + [.integer(next), .text(cursor), stamp.map { .real($0.timeIntervalSince1970) } ?? .null])
            if let historyThrough { try recordReadBaseline(accountID: accountID, archiveID: archiveID, sentAt: historyThrough) }
            return next
        }
    }

    /// Reference source stays separate: a room assigns stanza IDs after encryption.
    public func reactionReference(accountID: String, messageID: String) throws -> String? {
        guard let message = try message(accountID: accountID, messageID: messageID), message.encryptionProfile == "modern" else { return nil }
        if message.wireIDAuthenticated { return message.wireID }
        return try connection.query("SELECT stanza_id FROM group_message_references WHERE account_id=? AND message_id=? AND room=?", [.text(accountID), .text(messageID), .text(message.chatID)]).first?[0].string
    }
    private func bindGroupReference(accountID: String, room: String, messageID: String, stanzaID: String) throws {
        guard !stanzaID.isEmpty, stanzaID.utf8.count <= 1024, !stanzaID.contains(where: { $0.isWhitespace }),
              let message = try message(accountID: accountID, messageID: messageID), message.chatID == room,
              message.encryptionProfile == "modern", !message.wireIDAuthenticated else { throw MessageStoreError.invalidValue }
        if let old = try connection.query("SELECT room,stanza_id FROM group_message_references WHERE account_id=? AND message_id=?", [.text(accountID), .text(messageID)]).first {
            guard old[0].string == room, old[1].string == stanzaID else { throw MessageStoreError.conflictingIdentity }
            return
        }
        try connection.execute("INSERT INTO group_message_references VALUES(?,?,?,?)", [.text(accountID), .text(room), .text(messageID), .text(stanzaID)])
    }
    /// The caller supplies an authenticated archive assignment for the exact replayed ciphertext.
    public func bindArchivedGroupReference(accountID: String, sender: String, digest: String, room: String, stanzaID: String) throws {
        try connection.transaction {
            guard let id = try connection.query("SELECT message_id FROM group_ciphertext_messages WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)]).first?[0].string else { return }
            try bindGroupReference(accountID: accountID, room: room, messageID: id, stanzaID: stanzaID)
        }
    }

    // MARK: Read state

    /// The newest message this account has read in a chat, on any of its devices; nil when nothing was ever read.
    public func readPointer(accountID: String, chatID: String) throws -> ReadPointer? {
        guard let row = try connection.query("SELECT read_message_id,read_sent_at,publish_pending FROM chat_read_state WHERE account_id=? AND chat_id=?",
                                             [.text(accountID), .text(chatID)]).first else { return nil }
        return ReadPointer(messageID: row[0].string, sentAt: Date(timeIntervalSince1970: row[1].double), publishPending: row[2].integer != 0)
    }

    /// This device showed the chat up to `messageID` (the newest message was on screen in the foreground). Forward only;
    /// queues an XEP-0490 publication. The peer's read marker is separate and stays under the read-receipts switch.
    /// Returns true when the pointer moved.
    @discardableResult public func markRead(accountID: String, chatID: String, throughMessageID messageID: String) throws -> Bool {
        try connection.transaction {
            guard let target = try message(accountID: accountID, messageID: messageID), target.chatID == chatID else { throw MessageStoreError.invalidValue }
            return try advanceReadPointer(accountID: accountID, target: target, publish: true)
        }
    }

    /// The user marked the whole chat read: the pointer moves to its newest message. False when it was already there.
    @discardableResult public func markChatRead(accountID: String, chatID: String) throws -> Bool {
        try connection.transaction {
            guard let newest = try messages(accountID: accountID, chatID: chatID, limit: 1).last else { return false }
            return try advanceReadPointer(accountID: accountID, target: newest, publish: true)
        }
    }

    /// Another device of this account sent an XEP-0333 `displayed` for a peer message; the caller has established that it
    /// came from our own account (a carbon or our own archive). Unknown, ambiguous and own targets are ignored, the rule
    /// XEP-0490 gives for unknown ids. Never publishes: the displaying device owns its state. True when the pointer moved.
    @discardableResult public func recordOwnDisplayed(accountID: String, chatID: String, targetWireID: String) throws -> Bool {
        try connection.transaction { try advanceReadPointer(accountID: accountID, ownMarker: OwnReadMarker(chatID: chatID, targetWireID: targetWireID)) }
    }

    /// An XEP-0490 item for `chatID`, fetched after bind or pushed by our own PEP service (the caller verified the
    /// publisher). The id resolves only through the archive that assigned it: ours for a direct chat (`by` = account),
    /// the room's for a group (`by` = chat). Unknown ids are ignored and older state never moves the pointer back
    /// (XEP-0490 business rules). True when the pointer moved.
    @discardableResult public func applyDisplayedSync(accountID: String, chatID: String, stanzaID: String, by: String) throws -> Bool {
        guard !accountID.isEmpty, !chatID.isEmpty, chatID != accountID, Self.validStanzaID(stanzaID) else { return false }
        return try connection.transaction {
            let matches: [[Value]]
            if by == accountID {
                matches = try connection.query("SELECT id FROM messages WHERE account_id=? AND chat_id=? AND stanza_id=? LIMIT 2",
                                               [.text(accountID), .text(chatID), .text(stanzaID)])
            } else if by == chatID {
                matches = try connection.query("""
                    SELECT g.message_id FROM group_message_references g JOIN messages m ON m.account_id=g.account_id AND m.id=g.message_id AND m.chat_id=g.room
                    WHERE g.account_id=? AND g.room=? AND g.stanza_id=? LIMIT 2
                    """, [.text(accountID), .text(chatID), .text(stanzaID)])
            } else { return false }
            guard matches.count == 1, let target = try message(accountID: accountID, messageID: matches[0][0].string) else { return false }
            let moved = try advanceReadPointer(accountID: accountID, target: target, publish: false)
            // The server holds this id now. Publishing it again would be a no-op; a newer local read stays pending. An
            // item older than our pointer (another device overwrote the node with older state) means the server is
            // behind: publish our newer state again, or every device that pulls later inherits the older one.
            try connection.execute("""
                UPDATE chat_read_state SET published_stanza_id=?1,
                    publish_pending=CASE WHEN read_message_id=?2 THEN 0 WHEN ?5 THEN 1 ELSE publish_pending END
                WHERE account_id=?3 AND chat_id=?4
                """, [.text(stanzaID), .text(target.id), .text(accountID), .text(chatID), .integer(moved ? 0 : 1)])
            return moved
        }
    }

    /// Local reads still to publish: for each chat, the stanza-id of the newest incoming message at or below its
    /// pointer that has one (XEP-0490: outgoing messages are never published). A chat with no such id, or whose id the
    /// server already holds, is settled here without a publication.
    public func pendingDisplayedSyncPublications(accountID: String) throws -> [DisplayedSyncPublication] {
        try connection.transaction {
            let pending = try connection.query("SELECT chat_id,read_sent_at,read_message_id,published_stanza_id FROM chat_read_state WHERE account_id=? AND publish_pending=1 ORDER BY chat_id LIMIT 200",
                                               [.text(accountID)])
            var result: [DisplayedSyncPublication] = []
            for row in pending {
                let chatID = row[0].string, pointer = row[2].string
                let reference = try connection.query("""
                    SELECT g.stanza_id,m.stanza_id FROM messages m
                    LEFT JOIN group_message_references g ON g.account_id=m.account_id AND g.message_id=m.id AND g.room=m.chat_id
                    WHERE m.account_id=?1 AND m.chat_id=?2 AND m.outgoing=0 AND m.sender_id<>?1
                      AND (m.sent_at,m.id) <= (?3,?4) AND (m.stanza_id IS NOT NULL OR g.stanza_id IS NOT NULL)
                    ORDER BY m.sent_at DESC,m.id DESC LIMIT 1
                    """, [.text(accountID), .text(chatID), row[1], .text(pointer)]).first
                let publication = reference.map { reference in
                    reference[0].optionalString.map { DisplayedSyncPublication(chatID: chatID, stanzaID: $0, by: chatID, pointerMessageID: pointer) }
                        ?? DisplayedSyncPublication(chatID: chatID, stanzaID: reference[1].string, by: accountID, pointerMessageID: pointer)
                }
                if let publication, publication.stanzaID != row[3].optionalString { result.append(publication) }
                else { try connection.execute("UPDATE chat_read_state SET publish_pending=0 WHERE account_id=? AND chat_id=? AND read_message_id=?", [.text(accountID), .text(chatID), .text(pointer)]) }
            }
            return result
        }
    }

    /// The server accepted `publication`. Pending clears only while the pointer is still the one it was computed from.
    public func finishDisplayedSyncPublication(accountID: String, _ publication: DisplayedSyncPublication) throws {
        try connection.execute("""
            UPDATE chat_read_state SET published_stanza_id=?1, publish_pending=CASE WHEN read_message_id=?2 THEN 0 ELSE publish_pending END
            WHERE account_id=?3 AND chat_id=?4
            """, [.text(publication.stanzaID), .text(publication.pointerMessageID), .text(accountID), .text(publication.chatID)])
    }

    /// Chats (with their titles) where this account sent an encrypted message at or after `date`: each advanced an
    /// encryption session that a restore of older data would roll back.
    public func chatsWithEncryptedSends(accountID: String, since date: Date) throws -> [String] {
        try Self.chatsWithEncryptedSends(connection, accountID: accountID, since: date)
    }

    /// The same for a database file nobody has open as a store (a kept copy, or a store an older build wrote): every
    /// account in it. Only reads; opens nothing that does not exist.
    public static func chatsWithEncryptedSends(inFileAt url: URL, since date: Date) throws -> [String] {
        let file = try Connection(url: url, create: false)
        defer { try? file.close() }
        return try chatsWithEncryptedSends(file, accountID: nil, since: date)
    }

    private static func chatsWithEncryptedSends(_ connection: Connection, accountID: String?, since date: Date) throws -> [String] {
        try connection.query("""
            SELECT DISTINCT c.title FROM chats c WHERE (?1 IS NULL OR c.account_id=?1) AND EXISTS (SELECT 1 FROM messages m
            WHERE m.account_id=c.account_id AND m.chat_id=c.id AND m.outgoing=1 AND m.sent_at>=?2
            AND m.encryption_profile IN ('legacy','modern')) ORDER BY c.title
            """, [accountID.map(Value.text) ?? .null, .real(date.timeIntervalSince1970)]).map { $0[0].string }
    }

    /// Incoming messages after each chat's read pointer and newer than its archive's history baseline, by chat; chats
    /// with none are absent. A chat never read counts every incoming message since this device joined. One index range
    /// per chat. Placeholders whose reason never `alerts` (a blocked device, a retention limit) are left out, so neither
    /// can raise the chat's count or the app badge.
    public func unreadCounts(accountID: String) throws -> [String: Int] {
        let quiet = UnreadableReason.allCases.filter { !$0.alerts }.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let rows = try connection.query("""
            SELECT c.id,(SELECT COUNT(*) FROM messages m WHERE m.account_id=?1 AND m.chat_id=c.id AND m.outgoing=0 AND m.sender_id<>?1
                         AND COALESCE(m.unreadable_reason,'') NOT IN (\(quiet)) AND \(Self.unreadCondition))
            FROM chats c LEFT JOIN chat_read_state r ON r.account_id=c.account_id AND r.chat_id=c.id
            LEFT JOIN read_baselines bc ON bc.account_id=c.account_id AND bc.archive_id=c.id
            LEFT JOIN read_baselines ba ON ba.account_id=c.account_id AND ba.archive_id=c.account_id
            WHERE c.account_id=?1
            """, [.text(accountID)])
        var result: [String: Int] = [:]
        for row in rows where row[1].integer > 0 { result[row[0].string] = row[1].integer }
        return result
    }

    /// Which of `messageIDs` are at or below their chat's read pointer: their notifications may be removed. For the
    /// extension's end-of-run cleanup and the app's; unknown IDs are simply absent.
    public func readNotificationMessageIDs(accountID: String, messageIDs: Set<String>) throws -> Set<String> {
        guard !messageIDs.isEmpty else { return [] }
        guard messageIDs.count <= 1000 else { throw MessageStoreError.invalidValue }
        let ids = messageIDs.sorted()
        return Set(try connection.query("""
            SELECT m.id FROM messages m \(Self.readJoins)
            WHERE m.account_id=? AND m.id IN (\(ids.map { _ in "?" }.joined(separator: ","))) AND NOT \(Self.unreadCondition)
            """, [.text(accountID)] + ids.map(Value.text)).map { $0[0].string })
    }

    /// The own archive's XEP-0359 id of a direct message; nil when it is not known (or the message is a group's).
    public func archiveStanzaID(accountID: String, messageID: String) throws -> String? {
        try connection.query("SELECT stanza_id FROM messages WHERE account_id=? AND id=?", [.text(accountID), .text(messageID)]).first?[0].optionalString
    }

    /// A validated own-archive copy of ciphertext already consumed (live, before its archive id was known): bind the id
    /// to the message it became. A no-op for ciphertext that became no message or consumed before v19.
    public func bindArchivedDirectStanzaID(accountID: String, sender: String, digest: String, stanzaID: String) throws {
        try connection.transaction {
            guard let id = try connection.query("SELECT message_id FROM encrypted_inbox WHERE account_id=? AND sender=? AND digest=? AND message_id IS NOT NULL",
                                                [.text(accountID), .text(sender), .text(digest)]).first?[0].string else { return }
            try bindDirectStanzaID(accountID: accountID, messageID: id, stanzaID: stanzaID)
        }
    }

    /// First binding wins; a later, different id for the same message is ignored rather than trusted. Group messages
    /// keep their room's id in `group_message_references`.
    private func bindDirectStanzaID(accountID: String, messageID: String, stanzaID: String) throws {
        guard Self.validStanzaID(stanzaID) else { return }
        try connection.execute("""
            UPDATE messages SET stanza_id=?1 WHERE account_id=?2 AND id=?3 AND stanza_id IS NULL
            AND NOT EXISTS (SELECT 1 FROM group_message_references WHERE account_id=?2 AND message_id=?3)
            """, [.text(stanzaID), .text(accountID), .text(messageID)])
    }

    /// The read test's joins for a message `m`: its chat's pointer `r` and the history baselines of the chat's own archive
    /// (`bc`, a room) and of the account's archive (`ba`).
    private static let readJoins = """
        LEFT JOIN chat_read_state r ON r.account_id=m.account_id AND r.chat_id=m.chat_id
        LEFT JOIN read_baselines bc ON bc.account_id=m.account_id AND bc.archive_id=m.chat_id
        LEFT JOIN read_baselines ba ON ba.account_id=m.account_id AND ba.archive_id=m.account_id
        """
    /// Unread: after the pointer (if any) and newer than the history baseline (if any). Written as two ranges so the
    /// timeline index still bounds a count.
    private static let unreadCondition = """
        ((m.sent_at,m.id) > (COALESCE(r.read_sent_at,-1e308),COALESCE(r.read_message_id,'')) AND m.sent_at > COALESCE(bc.sent_at,ba.sent_at,-1e308))
        """

    /// The first (newest) page of `archiveID` was history through `sentAt`. First baseline wins; candidates it covers go,
    /// as a pointer's would. Runs inside the caller's transaction.
    private func recordReadBaseline(accountID: String, archiveID: String, sentAt: Date) throws {
        guard sentAt.timeIntervalSince1970.isFinite else { throw MessageStoreError.invalidValue }
        try connection.execute("INSERT INTO read_baselines(account_id,archive_id,sent_at) VALUES(?,?,?) ON CONFLICT(account_id,archive_id) DO NOTHING",
                               [.text(accountID), .text(archiveID), .real(sentAt.timeIntervalSince1970)])
        try connection.execute("""
            DELETE FROM notification_candidates WHERE account_id=?1 AND message_id IN (
                SELECT m.id FROM notification_candidates n JOIN messages m ON m.account_id=n.account_id AND m.id=n.message_id
                \(Self.readJoins) WHERE n.account_id=?1 AND NOT \(Self.unreadCondition))
            """, [.text(accountID)])
        // Retained ciphertext from the same history page was retained before the baseline existed.
        try connection.execute("""
            DELETE FROM pending_notification_candidates WHERE account_id=?1 AND sent_at <= COALESCE(
                (SELECT sent_at FROM read_baselines WHERE account_id=?1 AND archive_id=pending_notification_candidates.chat_id),
                (SELECT sent_at FROM read_baselines WHERE account_id=?1 AND archive_id=?1), -1e308)
            """, [.text(accountID)])
        try connection.execute("""
            DELETE FROM reaction_notification_candidates WHERE account_id=?1 AND reacted_at <= COALESCE(
                (SELECT sent_at FROM read_baselines WHERE account_id=?1 AND archive_id=reaction_notification_candidates.chat_id),
                (SELECT sent_at FROM read_baselines WHERE account_id=?1 AND archive_id=?1), -1e308)
            """, [.text(accountID)])
    }

    private static func validStanzaID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    /// Forward only, compared in SQL on the stored timestamp so no Date round trip can reorder equal instants. Removes the
    /// notification candidates the pointer now covers: a read message never alerts. Runs inside the caller's transaction.
    private func advanceReadPointer(accountID: String, target: StoredMessage, publish: Bool) throws -> Bool {
        let values: [Value] = [.text(accountID), .text(target.chatID), .text(target.id)]
        guard try connection.query("""
            SELECT 1 FROM chat_read_state r JOIN messages m ON m.account_id=r.account_id AND m.id=?3
            WHERE r.account_id=?1 AND r.chat_id=?2 AND (m.sent_at,m.id) <= (r.read_sent_at,r.read_message_id)
            """, values).isEmpty else { return false }
        try connection.execute("""
            INSERT INTO chat_read_state(account_id,chat_id,read_sent_at,read_message_id,publish_pending)
            SELECT ?1,?2,sent_at,id,?4 FROM messages WHERE account_id=?1 AND chat_id=?2 AND id=?3
            ON CONFLICT(account_id,chat_id) DO UPDATE SET read_sent_at=excluded.read_sent_at,read_message_id=excluded.read_message_id,
                publish_pending=MAX(publish_pending,excluded.publish_pending)
            """, values + [.integer(publish ? 1 : 0)])
        try connection.execute("""
            DELETE FROM notification_candidates WHERE account_id=?1 AND message_id IN (
                SELECT n.message_id FROM notification_candidates n
                JOIN messages m ON m.account_id=n.account_id AND m.id=n.message_id AND m.chat_id=?2
                JOIN chat_read_state r ON r.account_id=m.account_id AND r.chat_id=m.chat_id
                WHERE n.account_id=?1 AND (m.sent_at,m.id) <= (r.read_sent_at,r.read_message_id))
            """, Array(values.prefix(2)))
        try connection.execute("""
            DELETE FROM pending_notification_candidates WHERE account_id=?1 AND chat_id=?2
            AND sent_at <= (SELECT read_sent_at FROM chat_read_state WHERE account_id=?1 AND chat_id=?2)
            """, Array(values.prefix(2)))
        // Reactions have no read state of their own: the chat was read after they arrived, so they were seen, and
        // delivered ones are no longer current (cleanup removes them, here or on the next extension run).
        try connection.execute("DELETE FROM reaction_notification_candidates WHERE account_id=? AND chat_id=?", Array(values.prefix(2)))
        try connection.execute("DELETE FROM reaction_notifications_posted WHERE account_id=? AND chat_id=?", Array(values.prefix(2)))
        return true
    }

    /// An own XEP-0333 marker names a peer message by its wire id, resolved like every event target.
    private func advanceReadPointer(accountID: String, ownMarker: OwnReadMarker) throws -> Bool {
        guard !ownMarker.chatID.isEmpty, ownMarker.chatID != accountID, !ownMarker.targetWireID.isEmpty, ownMarker.targetWireID.utf8.count <= 1024,
              let target = try reactionTarget(accountID: accountID, chatID: ownMarker.chatID, wireID: ownMarker.targetWireID),
              !target.isOutgoing, target.senderID != accountID else { return false }
        return try advanceReadPointer(accountID: accountID, target: target, publish: false)
    }

    /// Resolve a single wire ID within this account and conversation. An authenticated (SCE) ID
    /// always wins; a peer-supplied one resolves only when nothing authenticated matches and it is
    /// unique, so a forged ID cannot hijack or disable an authenticated target. Sending still
    /// requires `reactionReference`.
    public func reactionTarget(accountID: String, chatID: String, wireID: String) throws -> StoredMessage? {
        let rows = try connection.query("SELECT \(Self.columns) FROM messages WHERE account_id=? AND chat_id=? AND (wire_id=? OR id IN (SELECT message_id FROM group_message_references WHERE account_id=? AND room=? AND stanza_id=?)) ORDER BY wire_id_authenticated DESC LIMIT 2", [.text(accountID), .text(chatID), .text(wireID), .text(accountID), .text(chatID), .text(wireID)])
        let matches = try rows.map(decodeRow)
        guard let first = matches.first, matches.count == 1 || (first.wireIDAuthenticated && !matches[1].wireIDAuthenticated) else { return nil }
        return first
    }

    /// Returns each authenticated actor's latest complete set, including an empty withdrawal.
    public func reactions(accountID: String, chatID: String, messageID: String) throws -> [AuthenticatedReaction] {
        try events(accountID: accountID, chatID: chatID, messageID: messageID).compactMap(AuthenticatedReaction.init)
    }

    /// Each actor's latest event per kind for one message, sorted by actor.
    public func events(accountID: String, chatID: String, messageID: String) throws -> [MessageEvent] {
        guard let message = try message(accountID: accountID, messageID: messageID), message.chatID == chatID,
              let wireID = try reactionReference(accountID: accountID, messageID: messageID) ?? message.wireID,
              try reactionTarget(accountID: accountID, chatID: chatID, wireID: wireID)?.id == messageID else { return [] }
        let rows = try connection.query("SELECT \(Self.eventColumns) FROM message_events WHERE account_id=? AND chat_id=? AND target_wire_id=? ORDER BY updated_at DESC,id DESC", [.text(accountID), .text(chatID), .text(wireID)])
        var seen: Set<String> = [], result: [MessageEvent] = []
        for row in rows {
            let event = try Self.decodeEvent(row)
            // Only the sender may unsend or rewrite a message; anyone else's claim is not a projection.
            guard !Self.senderOnly(event.kind) || event.actorID == message.senderID else { continue }
            if seen.insert(event.actorID + "\u{0}" + event.kind.rawValue).inserted { result.append(event) }
        }
        return result.sorted { ($0.actorID, $0.kind.rawValue) < ($1.actorID, $1.kind.rawValue) }
    }
    private static func senderOnly(_ kind: MessageEventKind) -> Bool { kind == .retraction || kind == .correction }

    /// One bounded query for a displayed timeline: every kind, latest per actor. Ambiguity is
    /// checked against the entire conversation, including colliding message IDs outside the page.
    public func eventsForChat(accountID: String, chatID: String,
                              messageIDs: Set<String>) throws -> [String: [MessageEvent]] {
        guard messageIDs.count <= 1000 else { throw MessageStoreError.invalidValue }
        guard !messageIDs.isEmpty else { return [:] }
        let ids = messageIDs.sorted()
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try connection.query("""
            WITH valid_references AS (
                SELECT account_id,chat_id,id,wire_id,wire_id_authenticated AS authenticated FROM messages WHERE account_id=? AND chat_id=? AND wire_id IS NOT NULL
                UNION ALL
                SELECT r.account_id,r.room,r.message_id,r.stanza_id,0 FROM group_message_references r JOIN messages m
                ON m.account_id=r.account_id AND m.id=r.message_id AND m.chat_id=r.room AND m.encryption_profile='modern'
                WHERE r.account_id=? AND r.room=?
            ), requested AS (
                SELECT id,wire_id,authenticated FROM valid_references
                WHERE account_id=? AND chat_id=? AND id IN (\(placeholders))
            ), unique_targets AS (
                -- Same rule as reactionTarget: authenticated wins, unauthenticated must be alone.
                SELECT r.id,r.wire_id FROM requested r WHERE (
                    SELECT COUNT(*) FROM valid_references m WHERE m.account_id=? AND m.chat_id=?
                    AND m.wire_id=r.wire_id AND m.authenticated>=r.authenticated
                )=1
            ), latest AS (
                SELECT t.id AS message_id,e.id,e.chat_id,e.actor_id,e.target_wire_id,e.kind,e.payload_json,e.updated_at,
                ROW_NUMBER() OVER (PARTITION BY t.id,e.actor_id,e.kind ORDER BY e.updated_at DESC,e.id DESC) AS position
                FROM unique_targets t JOIN message_events e
                ON e.account_id=? AND e.chat_id=? AND e.target_wire_id=t.wire_id
                JOIN messages m ON m.account_id=e.account_id AND m.chat_id=e.chat_id AND m.id=t.id
                -- Only the sender may unsend or rewrite a message.
                WHERE e.kind NOT IN ('retraction','correction') OR e.actor_id=m.sender_id
            )
            SELECT message_id,id,chat_id,actor_id,target_wire_id,kind,payload_json,updated_at
            FROM latest WHERE position=1 ORDER BY message_id,actor_id,kind
            """, [.text(accountID), .text(chatID), .text(accountID), .text(chatID), .text(accountID), .text(chatID)] + ids.map(Value.text) +
                 [.text(accountID), .text(chatID), .text(accountID), .text(chatID)])
        var result: [String: [MessageEvent]] = [:]
        for row in rows { result[row[0].string, default: []].append(try Self.decodeEvent(Array(row.dropFirst()))) }
        return result
    }

    @discardableResult public func enqueueReaction(_ update: StoredReactionUpdate, groupRoom: String? = nil) throws -> Bool {
        guard update.actorID == update.accountID else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let event = try AuthenticatedReaction(id: update.id, chatID: update.chatID, actorID: update.actorID, targetWireID: update.targetWireID, reactions: update.reactions, updatedAt: update.createdAt).event()
            try Self.validateEvent(accountID: update.accountID, event: event, groupRoom: groupRoom)
            guard let target = try reactionTarget(accountID: update.accountID, chatID: update.chatID, wireID: update.targetWireID),
                  target.id == update.targetMessageID else { throw MessageStoreError.invalidValue }
            if let existing = try reactionUpdate(accountID: update.accountID, updateID: update.id) {
                var comparison = update; comparison.transportState = existing.transportState
                guard comparison == existing else { throw MessageStoreError.conflictingIdentity }
                return false
            }
            try insertUpdate(accountID: update.accountID, id: update.id, kind: .reaction, chatID: update.chatID, createdAt: update.createdAt,
                             targetMessageID: update.targetMessageID, targetWireID: update.targetWireID, reactionsJSON: try Self.reactionJSON(update.reactions), wire: nil)
            try insertEvent(accountID: update.accountID, event: event, groupRoom: groupRoom)
            return true
        }
    }

    /// An unencrypted XEP-0444 event: the actor is server-authenticated only. Same projection rules.
    public func recordReaction(accountID: String, reaction: AuthenticatedReaction) throws {
        try insertEvent(accountID: accountID, event: try reaction.event())
    }

    /// Any inbound message-scoped event whose actor the caller has authenticated (or, for plain
    /// stanzas, the server has). Idempotent per (actor, id); a missing target is retained.
    public func recordEvent(accountID: String, event: MessageEvent) throws {
        try connection.transaction { try insertEvent(accountID: accountID, event: event) }
    }

    /// Unsend or rewrite one of our own messages: the queued stanza and its optimistic projection,
    /// in one transaction. The outbox seals the wire later; the event is what the timeline shows now. A correction's
    /// `linkPreview` is the one it sends with the new body (nil sends none, which removes the old one for the peer too).
    @discardableResult public func enqueueMessageUpdate(accountID: String, id: String, kind: StoredUpdate.Kind, chatID: String,
                                                       targetMessageID: String, body: String = "", linkPreview: StoredLinkPreview? = nil,
                                                       createdAt: Date = Date()) throws -> Bool {
        let eventKind: MessageEventKind
        switch kind { case .retraction: eventKind = .retraction; case .correction: eventKind = .correction; default: throw MessageStoreError.invalidValue }
        guard let target = try message(accountID: accountID, messageID: targetMessageID), target.chatID == chatID,
              target.isOutgoing, target.senderID == accountID,
              let wireID = try reactionReference(accountID: accountID, messageID: targetMessageID) ?? target.wireID,
              try reactionTarget(accountID: accountID, chatID: chatID, wireID: wireID)?.id == targetMessageID else { throw MessageStoreError.invalidValue }
        guard linkPreview == nil || eventKind == .correction else { throw MessageStoreError.invalidValue }
        let payload = eventKind == .correction ? try MessageEvent.correctionPayload(body, linkPreview: linkPreview) : "{}"
        let event = MessageEvent(id: id, chatID: chatID, actorID: accountID, targetWireID: wireID, kind: eventKind, payload: payload, updatedAt: createdAt)
        try Self.validateEvent(accountID: accountID, event: event)
        return try connection.transaction {
            if let existing = try update(accountID: accountID, updateID: id) {
                guard existing.kind == kind, existing.chatID == chatID, existing.targetMessageID == targetMessageID, existing.payload == payload else { throw MessageStoreError.conflictingIdentity }
                return false
            }
            try insertUpdate(accountID: accountID, id: id, kind: kind, chatID: chatID, createdAt: event.updatedAt,
                             targetMessageID: targetMessageID, targetWireID: wireID, reactionsJSON: payload, wire: nil)
            try insertEvent(accountID: accountID, event: event)
            return true
        }
    }

    /// A peer's receipt or marker, plain or authenticated, about one of our own messages.
    public func recordReceipt(accountID: String, event: MessageEvent) throws {
        guard event.kind == .delivered || event.kind == .displayed else { throw MessageStoreError.invalidValue }
        try insertEvent(accountID: accountID, event: event)
    }

    /// Queue `<received/>` (`.receipt`) or `<displayed/>` (`.marker`) for a peer message. The per-account
    /// switch is enforced here, the one place every path goes through; nil means nothing was queued.
    /// A receipt is one row per message. A marker is cumulative, so one queued row per chat is kept
    /// and replaced only by a newer target; once submitting it is immutable and a newer target is a new row.
    public func enqueueReceipt(accountID: String, chatID: String, targetMessageID: String, kind: StoredUpdate.Kind, createdAt: Date = Date()) throws -> String? {
        guard kind == .receipt || kind == .marker, !accountID.isEmpty else { throw MessageStoreError.invalidValue }
        let preferences = try accountPreferences(accountID: accountID)
        guard kind == .receipt ? preferences.deliveryReceipts : preferences.readReceipts else { return nil }
        return try connection.transaction {
            guard let target = try message(accountID: accountID, messageID: targetMessageID), target.chatID == chatID, !target.isOutgoing,
                  let wireID = target.wireID, try reactionTarget(accountID: accountID, chatID: chatID, wireID: wireID)?.id == target.id else { throw MessageStoreError.invalidValue }
            let existing = try connection.query("""
                SELECT u.state FROM outgoing_updates u JOIN messages m ON m.account_id=u.account_id AND m.id=u.target_message_id
                WHERE u.account_id=? AND u.kind=? AND u.chat_id=? AND (u.target_message_id=? OR (?='marker' AND m.sent_at>=?))
                """, [.text(accountID), .text(kind.rawValue), .text(chatID), .text(targetMessageID), .text(kind.rawValue), .real(target.sentAt.timeIntervalSince1970)])
            if !existing.isEmpty { return nil } // Already asserted this, or something newer, for this chat.
            if kind == .marker {
                try connection.execute("DELETE FROM outgoing_updates WHERE account_id=? AND kind='marker' AND chat_id=? AND state='queued'", [.text(accountID), .text(chatID)])
            }
            let id = UUID().uuidString
            try insertUpdate(accountID: accountID, id: id, kind: kind, chatID: chatID, createdAt: createdAt,
                             targetMessageID: targetMessageID, targetWireID: wireID, reactionsJSON: nil, wire: nil)
            return id
        }
    }

    public func queuedReceipts(accountID: String) throws -> [StoredUpdate] {
        try connection.query("SELECT \(Self.updateColumns) FROM outgoing_updates WHERE account_id=? AND kind IN ('receipt','marker') AND state='queued' ORDER BY sequence LIMIT 1000", [.text(accountID)]).map(Self.decodeUpdate)
    }

    public func queuedReactions(accountID: String) throws -> [StoredReactionUpdate] {
        try connection.query("SELECT \(Self.reactionColumns) FROM outgoing_updates WHERE account_id=? AND kind='reaction' AND state='queued' ORDER BY sequence LIMIT 1000", [.text(accountID)]).map(Self.decodeReaction)
    }

    public func reactionUpdate(accountID: String, updateID: String) throws -> StoredReactionUpdate? {
        try connection.query("SELECT \(Self.reactionColumns) FROM outgoing_updates WHERE account_id=? AND kind='reaction' AND id=?", [.text(accountID), .text(updateID)]).first.map(Self.decodeReaction)
    }

    public func queuedUpdates(accountID: String, kind: StoredUpdate.Kind) throws -> [StoredUpdate] {
        try connection.query("SELECT \(Self.updateColumns) FROM outgoing_updates WHERE account_id=? AND kind=? AND state='queued' ORDER BY sequence LIMIT 1000", [.text(accountID), .text(kind.rawValue)]).map(Self.decodeUpdate)
    }

    public func update(accountID: String, updateID: String) throws -> StoredUpdate? {
        try connection.query("SELECT \(Self.updateColumns) FROM outgoing_updates WHERE account_id=? AND id=?", [.text(accountID), .text(updateID)]).first.map(Self.decodeUpdate)
    }

    /// The sealed wire: exact plain stanza bytes, or the prepared envelope for an encrypted update.
    public func updateWire(accountID: String, updateID: String) throws -> Data? {
        try connection.query("SELECT wire FROM outgoing_updates WHERE account_id=? AND id=?", [.text(accountID), .text(updateID)]).first?[0].data
    }

    /// Converts a durable queued intention into exact ciphertext and commits the ratchet advancement
    /// in the SAME transaction. Never overwrites an existing sealed wire. `clearLinkPreview`: a correction sealed
    /// without the link preview it was queued with (the chat fell back to legacy OMEMO); its queued payload and its
    /// event lose the preview too, so our edited bubble shows what the peer got.
    public func sealQueuedUpdate(accountID: String, updateID: String, expectedRevision: Int, state: Data, wire: Data,
                                 clearLinkPreview: Bool = false) throws {
        guard !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard try sealableUpdate(accountID: accountID, updateID: updateID), try updateWire(accountID: accountID, updateID: updateID) == nil else { throw MessageStoreError.invalidTransition }
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: state)
            try connection.execute("UPDATE outgoing_updates SET wire=? WHERE account_id=? AND id=?", [.blob(wire), .text(accountID), .text(updateID)])
            if clearLinkPreview, let queued = try update(accountID: accountID, updateID: updateID), queued.kind == .correction,
               let payload = queued.payload, let body = MessageEvent.correctionBody(payload) {
                let plain = try MessageEvent.correctionPayload(body)
                try connection.execute("UPDATE outgoing_updates SET reactions_json=? WHERE account_id=? AND id=?", [.text(plain), .text(accountID), .text(updateID)])
                try connection.execute("UPDATE message_events SET payload_json=? WHERE account_id=? AND actor_id=? AND id=? AND kind='correction'",
                                       [.text(plain), .text(accountID), .text(accountID), .text(updateID)])
            }
        }
    }

    /// A plain stanza for a legacy peer: the exact bytes are the wire, no ratchet state moves. Idempotent for identical bytes.
    public func sealQueuedUpdate(accountID: String, updateID: String, wire: Data) throws {
        guard !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard try sealableUpdate(accountID: accountID, updateID: updateID) else { throw MessageStoreError.invalidTransition }
            if let existing = try updateWire(accountID: accountID, updateID: updateID) {
                guard existing == wire else { throw MessageStoreError.invalidTransition }
                return
            }
            try connection.execute("UPDATE outgoing_updates SET wire=? WHERE account_id=? AND id=?", [.blob(wire), .text(accountID), .text(updateID)])
        }
    }

    /// Queued, and for a reaction still bound to exactly the message it was queued against.
    private func sealableUpdate(accountID: String, updateID: String) throws -> Bool {
        guard let update = try update(accountID: accountID, updateID: updateID), update.transportState == .queued else { return false }
        guard update.kind != .keyTransport else { return true }
        guard let targetWireID = update.targetWireID, let targetMessageID = update.targetMessageID else { return false }
        return try reactionTarget(accountID: accountID, chatID: update.chatID, wireID: targetWireID)?.id == targetMessageID
    }

    /// FIFO by durable enqueue order across kinds. `nil` claims any sealed update.
    public func claimNextUpdate(accountID: String, updateIDs: Set<String>? = nil) throws -> UpdateSubmission? {
        try Task.checkCancellation(); try requireTransportOwnership()
        if let updateIDs, updateIDs.isEmpty { return nil }
        guard (updateIDs?.count ?? 0) <= 1000 else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let ordered = updateIDs?.sorted() ?? []
            let selection = updateIDs == nil ? "" : " AND id IN (" + ordered.map { _ in "?" }.joined(separator: ",") + ")"
            guard let row = try connection.query("SELECT id,wire FROM outgoing_updates WHERE account_id=? AND state='queued' AND wire IS NOT NULL" + selection + " ORDER BY sequence LIMIT 1", [.text(accountID)] + ordered.map(Value.text)).first,
                  let wire = row[1].data else { return nil }
            let id = row[0].string, attempt = UUID().uuidString
            try connection.execute("UPDATE outgoing_updates SET state='submitting',attempt_id=? WHERE account_id=? AND id=?", [.text(attempt), .text(accountID), .text(id)])
            guard let update = try update(accountID: accountID, updateID: id) else { throw MessageStoreError.invalidTransition }
            return UpdateSubmission(update: update, wire: wire, attemptID: attempt)
        }
    }

    /// Call for BOTH successful socket writes and errors after claiming; socket completion is not delivery.
    @discardableResult public func finishUpdateSubmission(accountID: String, updateID: String, attemptID: String) throws -> Bool {
        try requireTransportOwnership()
        try connection.execute("UPDATE outgoing_updates SET state='unconfirmed',attempt_id=NULL WHERE account_id=? AND id=? AND state='submitting' AND attempt_id=?", [.text(accountID), .text(updateID), .text(attemptID)])
        return try connection.query("SELECT changes()").first?[0].integer == 1
    }

    /// Only call when no socket operation was attempted.
    @discardableResult public func releaseUnsentUpdateSubmission(accountID: String, updateID: String, attemptID: String) throws -> Bool {
        try requireTransportOwnership()
        try connection.execute("UPDATE outgoing_updates SET state='queued',attempt_id=NULL WHERE account_id=? AND id=? AND state='submitting' AND attempt_id=?", [.text(accountID), .text(updateID), .text(attemptID)])
        return try connection.query("SELECT changes()").first?[0].integer == 1
    }

    public func retryUpdate(accountID: String, updateID: String) throws {
        try requireTransportOwnership()
        try connection.execute("UPDATE outgoing_updates SET state='queued',attempt_id=NULL,rejection=NULL WHERE account_id=? AND id=? AND state IN ('unconfirmed','failed')", [.text(accountID), .text(updateID)])
        guard try connection.query("SELECT changes()").first?[0].integer == 1 else { throw MessageStoreError.invalidTransition }
    }

    /// Authenticated archive/carbon caller must also compare recipient/profile/envelope before use.
    @discardableResult public func reconcileArchivedUpdate(accountID: String, updateID: String, expectedWire: Data) throws -> Bool {
        try requireTransportOwnership()
        guard try updateWire(accountID: accountID, updateID: updateID) == expectedWire else { return false }
        // As for messages: an archived copy of a returned update is not acceptance of a retry.
        try connection.execute("UPDATE outgoing_updates SET state='serverAccepted',attempt_id=NULL WHERE account_id=? AND id=? AND returned=0", [.text(accountID), .text(updateID)])
        return try connection.query("SELECT changes()").first?[0].integer == 1
    }

    private func insertEvent(accountID: String, event: MessageEvent, groupRoom: String? = nil) throws {
        try Self.validateEvent(accountID: accountID, event: event, groupRoom: groupRoom)
        if event.kind == .delivered || event.kind == .displayed,
           let target = try reactionTarget(accountID: accountID, chatID: event.chatID, wireID: event.targetWireID), !target.isOutgoing {
            // A peer can only confirm our messages. An unknown target is retained: it may still arrive from the archive.
            throw MessageStoreError.invalidValue
        }
        var event = event
        if Self.senderOnly(event.kind), try reactionTarget(accountID: accountID, chatID: event.chatID, wireID: event.targetWireID) == nil,
           let original = try connection.query("SELECT target_wire_id FROM message_events WHERE account_id=? AND chat_id=? AND actor_id=? AND id=? AND kind='correction'",
                                               [.text(accountID), .text(event.chatID), .text(event.actorID), .text(event.targetWireID)]).first?[0].string {
            // XEP-0308 lets a correction name the previous correction instead of the original; the chain is one hop per event.
            event = MessageEvent(id: event.id, chatID: event.chatID, actorID: event.actorID, targetWireID: original, kind: event.kind, payload: event.payload, updatedAt: event.updatedAt)
        }
        // Missing targets remain retained. Ambiguous/missing authenticated IDs never get a projection.
        // A replayed authenticated event ID cannot replace the first accepted content under that ID.
        try connection.execute("INSERT INTO message_events(account_id,actor_id,id,chat_id,target_wire_id,kind,payload_json,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(account_id,actor_id,id) DO NOTHING", [.text(accountID), .text(event.actorID), .text(event.id), .text(event.chatID), .text(event.targetWireID), .text(event.kind.rawValue), .text(event.payload), .real(event.updatedAt.timeIntervalSince1970)])
        if event.kind == .retraction, let target = try reactionTarget(accountID: accountID, chatID: event.chatID, wireID: event.targetWireID), target.senderID == event.actorID {
            // An unsent message no longer deserves an alert; a corrected one alerts with its new text through the projection.
            try connection.execute("DELETE FROM notification_candidates WHERE account_id=? AND message_id=?", [.text(accountID), .text(target.id)])
            try connection.execute("DELETE FROM reaction_notification_candidates WHERE account_id=? AND target_message_id=?", [.text(accountID), .text(target.id)])
            try connection.execute("DELETE FROM reaction_notifications_posted WHERE account_id=? AND target_message_id=?", [.text(accountID), .text(target.id)])
            // An unsent message keeps no preview: the sender took the link back.
            try connection.execute("DELETE FROM message_link_previews WHERE account_id=? AND message_id=?", [.text(accountID), .text(target.id)])
        }
    }

    /// Who may assert what about a message, by kind. Shape rules for the payload live here too.
    private static func validateEvent(accountID: String, event: MessageEvent, groupRoom: String? = nil) throws {
        guard !accountID.isEmpty, !event.chatID.isEmpty, event.chatID.utf8.count <= 3071,
              !event.id.isEmpty, event.id.utf8.count <= 1024, !event.targetWireID.isEmpty, event.targetWireID.utf8.count <= 1024,
              event.updatedAt.timeIntervalSince1970.isFinite else { throw MessageStoreError.invalidValue }
        switch event.kind {
        case .reaction:
            // Any participant may react: us, the direct peer, or a member of the room.
            guard groupRoom == nil ? (event.actorID == accountID || event.actorID == event.chatID)
                    : (groupRoom == event.chatID && !event.actorID.isEmpty && event.actorID.utf8.count <= 3071),
                  let reactions = try? JSONDecoder().decode([String].self, from: Data(event.payload.utf8)),
                  reactions.count <= 12, Set(reactions).count == reactions.count,
                  reactions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { throw MessageStoreError.invalidValue }
        case .retraction, .correction:
            // Direct chats only for now: us or the peer may claim; the read side keeps only the sender's claim.
            // ponytail: rooms need a real-JID actor (muc_nonanonymous) and a room-scoped rule; add with group retract/edit.
            guard groupRoom == nil, event.actorID == accountID || event.actorID == event.chatID,
                  event.kind == .retraction || MessageEvent.correctionBody(event.payload) != nil else { throw MessageStoreError.invalidValue }
        case .delivered, .displayed:
            // Only the direct peer confirms delivery or reading; group receipts are not accepted.
            guard groupRoom == nil, event.actorID == event.chatID, event.payload == "{}" else { throw MessageStoreError.invalidValue }
        }
    }
    private static let eventColumns = "id,chat_id,actor_id,target_wire_id,kind,payload_json,updated_at"
    private static func decodeEvent(_ row: [Value]) throws -> MessageEvent {
        guard let kind = MessageEventKind(rawValue: row[4].string) else { throw MessageStoreError.invalidValue }
        return MessageEvent(id: row[0].string, chatID: row[1].string, actorID: row[2].string, targetWireID: row[3].string,
                            kind: kind, payload: row[5].string, updatedAt: Date(timeIntervalSince1970: row[6].double))
    }
    private static func reactionJSON(_ values: [String]) throws -> String { String(decoding: try JSONEncoder().encode(values.sorted()), as: UTF8.self) }
    private static let reactionColumns = "account_id,id,chat_id,target_message_id,target_wire_id,reactions_json,created_at,state"
    private static func decodeReaction(_ row: [Value]) throws -> StoredReactionUpdate {
        // Outgoing updates are always our own: the actor is the account.
        StoredReactionUpdate(id: row[1].string, accountID: row[0].string, chatID: row[2].string, targetMessageID: row[3].string,
                             targetWireID: row[4].string, actorID: row[0].string,
                             reactions: try JSONDecoder().decode([String].self, from: Data(row[5].string.utf8)),
                             createdAt: Date(timeIntervalSince1970: row[6].double), transportState: OutgoingTransportState(rawValue: row[7].string))
    }
    private static let updateColumns = "account_id,id,kind,chat_id,state,target_message_id,target_wire_id,reactions_json"
    private static func decodeUpdate(_ row: [Value]) throws -> StoredUpdate {
        guard let kind = StoredUpdate.Kind(rawValue: row[2].string) else { throw MessageStoreError.invalidValue }
        func text(_ value: Value) -> String? { if case .null = value { nil } else { value.string } }
        return StoredUpdate(id: row[1].string, accountID: row[0].string, kind: kind, chatID: row[3].string, transportState: OutgoingTransportState(rawValue: row[4].string),
                            targetMessageID: text(row[5]), targetWireID: text(row[6]), payload: text(row[7]))
    }

    private static let columns = """
        account_id,id,chat_id,sender_id,body,sent_at,outgoing,starred,
        (SELECT state FROM outbox WHERE outbox.account_id=messages.account_id AND outbox.message_id=messages.id),reply_json,encryption_profile,wire_id,wire_id_authenticated,
        unreadable_reason,
        (SELECT rejection FROM outbox WHERE outbox.account_id=messages.account_id AND outbox.message_id=messages.id)
        """
    private static func validateReply(_ reply: MessageReply) throws {
        guard !reply.messageID.isEmpty, reply.messageID.utf8.count <= 1_024,
              !reply.senderID.isEmpty, reply.senderID.utf8.count <= 3_071,
              reply.body.utf8.count <= 16_384,
              reply.wireID.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true else { throw MessageStoreError.invalidValue }
    }

    // ponytail: one extra lookup per message row (bounded by the 1000-row page); join when it shows in traces.
    private func decodeRow(_ row: [Value]) throws -> StoredMessage {
        var message = try Self.decode(row)
        if let attachment = try connection.query("SELECT name,media_type,size,width,height,hash,cipher_hash,secret,url,upload_state,task_id,sealed_account FROM attachments WHERE account_id=? AND message_id=?",
                                                 [.text(message.accountID), .text(message.id)]).first {
            func integer(_ value: Value) -> Int? { if case .integer(let number) = value { return number }; return nil }
            func text(_ value: Value) -> String? { if case .text(let string) = value { return string }; return nil }
            message.attachment = StoredAttachment(name: attachment[0].string, mediaType: attachment[1].string, size: attachment[2].integer,
                                                  width: integer(attachment[3]), height: integer(attachment[4]), hash: attachment[5].string,
                                                  cipherHash: text(attachment[6]), secret: attachment[7].data ?? Data(), url: text(attachment[8]),
                                                  uploadState: text(attachment[9]).flatMap(StoredAttachment.UploadState.init(rawValue:)), uploadTaskID: integer(attachment[10]))
            message.attachment?.sealedAccount = text(attachment[11])
        }
        message.linkPreview = try connection.query("SELECT \(Self.linkPreviewColumns) FROM message_link_previews WHERE account_id=? AND message_id=?",
                                                   [.text(message.accountID), .text(message.id)]).first.flatMap { Self.decodeLinkPreview($0[...]) }
        return message
    }

    private static let linkPreviewColumns = "url,title,summary,image_data,image_type,image_alt,source"
    /// `linkPreviewColumns` in order; nil when the row has no preview (a NULL url from an outer join).
    private static func decodeLinkPreview(_ row: ArraySlice<Value>) -> StoredLinkPreview? {
        let values = Array(row)
        guard values.count == 7, let url = values[0].optionalString, let source = values[6].optionalString.flatMap(StoredLinkPreview.Source.init) else { return nil }
        return StoredLinkPreview(url: url, title: values[1].optionalString, summary: values[2].optionalString, imageData: values[3].data,
                                 imageType: values[4].optionalString, imageAlt: values[5].optionalString, source: source)
    }

    private static func decode(_ row: [Value]) throws -> StoredMessage {
        let reply: MessageReply?
        if case .null = row[9] {
            reply = nil
        } else {
            let decoded = try JSONDecoder().decode(MessageReply.self, from: Data(row[9].string.utf8))
            try validateReply(decoded)
            reply = decoded
        }
        var message = StoredMessage(id: row[1].string, accountID: row[0].string, chatID: row[2].string,
                      senderID: row[3].string, body: row[4].string,
                      sentAt: Date(timeIntervalSince1970: row[5].double),
                      isOutgoing: row[6].integer != 0, isStarred: row[7].integer != 0,
                      transportState: OutgoingTransportState(rawValue: row[8].string), reply: reply,
                      encryptionProfile: row[10].string.isEmpty ? nil : row[10].string,
                      wireID: row[11].string.isEmpty ? nil : row[11].string, wireIDAuthenticated: row[12].integer != 0,
                      unreadableReason: row[13].optionalString.flatMap(UnreadableReason.init(rawValue:)))
        message.rejection = row[14].optionalString
        return message
    }
}

enum Value {
    case text(String), integer(Int), real(Double), blob(Data), null
    var data: Data? { if case let .blob(value) = self { return value }; return nil }
    var string: String { if case let .text(value) = self { return value }; return "" }
    var optionalString: String? { if case let .text(value) = self { return value }; return nil }
    var integer: Int { if case let .integer(value) = self { return value }; return 0 }
    var double: Double {
        if case let .real(value) = self { return value }
        if case let .integer(value) = self { return Double(value) }
        return 0
    }
    /// A nullable REAL column holding seconds since 1970.
    var optionalDate: Date? {
        switch self {
        case .real(let seconds): Date(timeIntervalSince1970: seconds)
        case .integer(let seconds): Date(timeIntervalSince1970: TimeInterval(seconds))
        default: nil
        }
    }
}

/// Owned exclusively by its MessageStore actor after initialization.
final class Connection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    var isOpen: Bool { handle != nil }
    init(url: URL, create: Bool = true) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        if result != SQLITE_OK {
            let failure = error(result)
            sqlite3_close(handle)
            handle = nil
            throw failure
        }
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { try? close() }
    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw error(result) }
        self.handle = nil
    }
    func error(_ code: Int32) -> MessageStoreError {
        .database(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database")
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func execute(_ sql: String, _ values: [Value] = []) throws { _ = try query(sql, values) }
    func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        guard let handle else { throw MessageStoreError.closed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw error(prepared) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text):
                result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case let .integer(number): result = sqlite3_bind_int64(statement, index, Int64(number))
            case let .real(number): result = sqlite3_bind_double(statement, index, number)
            case let .blob(data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw error(result) }
        }
        var rows: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw error(step) }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .integer(Int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
                case SQLITE_BLOB:
                    return .blob(Data(bytes: sqlite3_column_blob(statement, column)!, count: Int(sqlite3_column_bytes(statement, column))))
                case SQLITE_TEXT:
                    let bytes = sqlite3_column_text(statement, column)!
                    return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self))
                default: return .null
                }
            })
        }
    }
}

/// No timer lease: suspension must not let another process send concurrently with a live socket.
/// The sidecar is never removed, so all owners lock the same inode. CLOEXEC prevents inheritance
/// into launched helpers; process death closes the descriptor and releases ownership.
private final class TransportOwnership: @unchecked Sendable {
    private let descriptor: Int32
    private(set) var isHeld = false
    init(url: URL) throws {
        let lockPath = url.resolvingSymlinksInPath().path + ".transport-lock"
        descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw MessageStoreError.database(code: errno, message: "Unable to open transport lock") }
    }
    func acquire() throws {
        if isHeld { return }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw MessageStoreError.transportOwnedElsewhere }
            throw MessageStoreError.database(code: errno, message: "Unable to acquire transport lock")
        }
        isHeld = true
    }
    func release() {
        if isHeld { _ = flock(descriptor, LOCK_UN); isHeld = false }
    }
    deinit { Darwin.close(descriptor) }
}

/// Device and inode of a path: which file a connection opened, compared again once the lease is held.
struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino)
    }
}

/// What a verified snapshot must match: the schema version and the row count of every table, read in one transaction.
public struct StoreSnapshotSummary: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let rowCounts: [String: Int]

    init(_ connection: Connection) throws {
        schemaVersion = try connection.query("PRAGMA user_version").first?[0].integer ?? 0
        let tables = try connection.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .compactMap { $0.first?.optionalString }
        var counts: [String: Int] = [:]
        for table in tables {
            counts[table] = try connection.query("SELECT count(*) FROM \"\(table.replacingOccurrences(of: "\"", with: "\"\""))\"").first?[0].integer ?? 0
        }
        rowCounts = counts
    }
}

// MARK: Link preview cache

extension MessageStore: LinkPreviewCaching {
    private static let cacheColumns = "account_id,url,fetched_at,status,title,summary,image_alt,image_path,image_width,image_height"

    private static func decodeCacheEntry(_ row: [Value]) -> LinkPreviewCacheEntry? {
        guard let status = LinkPreviewCacheEntry.Status(rawValue: row[3].string) else { return nil }
        return LinkPreviewCacheEntry(accountID: row[0].string, url: row[1].string, fetchedAt: Date(timeIntervalSince1970: row[2].double), status: status,
                                     title: row[4].optionalString, summary: row[5].optionalString, imageAlt: row[6].optionalString,
                                     imagePath: row[7].optionalString, imageWidth: optionalInteger(row[8]), imageHeight: optionalInteger(row[9]))
    }

    public func linkPreviewCacheEntry(accountID: String, url: String) throws -> LinkPreviewCacheEntry? {
        try connection.query("SELECT \(Self.cacheColumns) FROM link_preview_cache WHERE account_id=? AND url=?", [.text(accountID), .text(url)])
            .first.flatMap(Self.decodeCacheEntry)
    }

    @discardableResult public func saveLinkPreviewCacheEntry(_ entry: LinkPreviewCacheEntry) throws -> String? {
        try entry.validate()
        return try connection.transaction {
            let previous = try linkPreviewCacheEntry(accountID: entry.accountID, url: entry.url)?.imagePath
            try connection.execute("""
                INSERT OR REPLACE INTO link_preview_cache(\(Self.cacheColumns)) VALUES(?,?,?,?,?,?,?,?,?,?)
                """, [.text(entry.accountID), .text(entry.url), .real(entry.fetchedAt.timeIntervalSince1970), .text(entry.status.rawValue),
                      entry.title.map(Value.text) ?? .null, entry.summary.map(Value.text) ?? .null, entry.imageAlt.map(Value.text) ?? .null,
                      entry.imagePath.map(Value.text) ?? .null, entry.imageWidth.map(Value.integer) ?? .null, entry.imageHeight.map(Value.integer) ?? .null])
            return previous == entry.imagePath ? nil : previous
        }
    }

    public func pruneLinkPreviewCache(accountID: String, fetchedBefore date: Date, keeping: Int) throws -> [String] {
        guard date.timeIntervalSince1970.isFinite, keeping >= 0 else { throw MessageStoreError.invalidValue }
        let account = Value.text(accountID)
        // Older than `date`, or beyond the newest `keeping`: one statement for each, so the paths match the rows gone.
        let condition = """
            account_id=?1 AND (fetched_at<?2 OR url IN (
                SELECT url FROM link_preview_cache WHERE account_id=?1 ORDER BY fetched_at DESC,url DESC LIMIT -1 OFFSET ?3))
            """
        let values: [Value] = [account, .real(date.timeIntervalSince1970), .integer(keeping)]
        return try connection.transaction {
            let paths = try connection.query("SELECT image_path FROM link_preview_cache WHERE \(condition) AND image_path IS NOT NULL", values).map { $0[0].string }
            try connection.execute("DELETE FROM link_preview_cache WHERE \(condition)", values)
            return paths
        }
    }

    public func deleteLinkPreviewCache(accountID: String) throws -> [String] {
        try connection.transaction {
            let paths = try connection.query("SELECT image_path FROM link_preview_cache WHERE account_id=? AND image_path IS NOT NULL", [.text(accountID)]).map { $0[0].string }
            try connection.execute("DELETE FROM link_preview_cache WHERE account_id=?", [.text(accountID)])
            return paths
        }
    }
}
