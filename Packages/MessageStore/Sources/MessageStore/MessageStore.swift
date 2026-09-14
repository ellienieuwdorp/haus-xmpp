import Foundation
import CSQLite
import Darwin

/// Protected-directory SQLite persistence. The caller validates authenticated transport identities.
/// Crypto writes use revision CAS; socket work additionally requires exclusive OS ownership.
public actor MessageStore {
    private let connection: Connection
    private let transportOwnership: TransportOwnership

    public init(url: URL) throws {
        transportOwnership = try TransportOwnership(url: url)
        connection = try Connection(url: url)
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA synchronous = FULL")
        try connection.transaction {
            let version = try connection.query("PRAGMA user_version").first?[0].integer ?? 0
            guard version <= 8 else { throw MessageStoreError.unsupportedSchema(version) }
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
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS encryption_controls (
                    account_id TEXT NOT NULL,id TEXT NOT NULL,recipient TEXT NOT NULL,wire BLOB NOT NULL,
                    state TEXT NOT NULL DEFAULT 'queued', PRIMARY KEY(account_id,id)
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
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS reaction_updates (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL, id TEXT NOT NULL,
                    chat_id TEXT NOT NULL, target_message_id TEXT NOT NULL, target_wire_id TEXT NOT NULL,
                    actor_id TEXT NOT NULL, reactions_json TEXT NOT NULL, created_at REAL NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('queued','submitting','unconfirmed','failed','serverAccepted')),
                    attempt_id TEXT, wire BLOB, UNIQUE(account_id,id),
                    FOREIGN KEY(account_id,target_message_id) REFERENCES messages(account_id,id)
                )
                """)
            try connection.execute("CREATE INDEX IF NOT EXISTS reaction_update_queue ON reaction_updates(account_id,state,sequence)")
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS reaction_events (
                    account_id TEXT NOT NULL, actor_id TEXT NOT NULL, id TEXT NOT NULL,
                    chat_id TEXT NOT NULL, target_wire_id TEXT NOT NULL, reactions_json TEXT NOT NULL, updated_at REAL NOT NULL,
                    PRIMARY KEY(account_id,actor_id,id)
                )
                """)
            try connection.execute("CREATE INDEX IF NOT EXISTS reaction_target ON reaction_events(account_id,chat_id,target_wire_id,actor_id,updated_at,id)")
            try connection.execute("CREATE TABLE IF NOT EXISTS notification_preferences (account_id TEXT PRIMARY KEY, previews INTEGER NOT NULL DEFAULT 1)")
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
            try connection.execute("PRAGMA user_version = 8")
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
              !message.wireIDAuthenticated || (message.wireID != nil && message.encryptionProfile == "modern") else { throw MessageStoreError.invalidValue }
        let replyJSON: Value
        if let reply = message.reply {
            try Self.validateReply(reply)
            replyJSON = .text(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
        } else {
            replyJSON = .null
        }
        if let existing = try connection.query("SELECT \(Self.columns) FROM messages WHERE account_id=? AND id=?",
                                               [.text(message.accountID), .text(message.id)]).first.map(Self.decode) {
            var comparison = message
            comparison.isStarred = existing.isStarred
            comparison.transportState = existing.transportState
            guard existing == comparison else { throw MessageStoreError.conflictingIdentity }
            return false
        }
        try connection.execute("""
            INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing,starred,reply_json,encryption_profile,wire_id,wire_id_authenticated)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(message.accountID), .text(message.id), .text(message.chatID), .text(message.senderID),
                  .text(message.body), .real(message.sentAt.timeIntervalSince1970),
                  .integer(message.isOutgoing ? 1 : 0), .integer(message.isStarred ? 1 : 0), replyJSON, message.encryptionProfile.map(Value.text) ?? .null,
                  message.wireID.map(Value.text) ?? .null, .integer(message.wireIDAuthenticated ? 1 : 0)])
        return true
    }

    /// Atomically saves the message and queued work before any socket operation.
    /// The supplied message ID must also be the stable outgoing stanza/origin ID.
    /// Repeating an enqueue never resets an existing transport attempt.
    @discardableResult public func enqueueOutgoing(_ message: StoredMessage) throws -> Bool {
        guard message.isOutgoing, !message.body.isEmpty, message.body.utf8.count <= 65_536 else { throw MessageStoreError.invalidValue }
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
            try connection.execute("UPDATE encryption_controls SET state='unconfirmed' WHERE state='submitting'")
            try connection.execute("UPDATE reaction_updates SET state='unconfirmed',attempt_id=NULL WHERE state='submitting'")
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
            guard let row = try connection.query("SELECT message_id FROM outbox WHERE account_id=? AND state='queued'" + selection + " ORDER BY sequence LIMIT 1", parameters).first else { return nil }
            let attemptID = UUID().uuidString
            try connection.execute("UPDATE outbox SET state='submitting',attempt_id=? WHERE account_id=? AND message_id=? AND state='queued'",
                                   [.text(attemptID), .text(accountID), .text(row[0].string)])
            let message = try connection.query("SELECT \(Self.columns) FROM messages WHERE account_id=? AND id=?",
                                               [.text(accountID), .text(row[0].string)]).first.map(Self.decode)!
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
            try connection.execute("UPDATE encryption_controls SET state='unconfirmed' WHERE account_id=? AND state='submitting'", [.text(accountID)])
            try connection.execute("UPDATE reaction_updates SET state='unconfirmed',attempt_id=NULL WHERE account_id=? AND state='submitting'", [.text(accountID)])
        }
    }

    /// Caller must explicitly warn that retry can duplicate a message already accepted remotely.
    public func retryOutgoing(accountID: String, messageID: String) throws {
        try requireTransportOwnership()
        return try connection.transaction {
            try connection.execute("""
                UPDATE outbox SET state='queued',attempt_id=NULL WHERE account_id=? AND message_id=?
                AND state IN ('unconfirmed','failed')
                """, [.text(accountID), .text(messageID)])
            guard try connection.query("SELECT changes()").first?[0].integer == 1 else {
                throw MessageStoreError.invalidTransition
            }
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

    public func chats(accountID: String) throws -> [StoredChat] {
        let rows = try connection.query("""
            SELECT c.id,c.title,c.pinned FROM chats c WHERE c.account_id=?
            ORDER BY c.pinned DESC,
            (SELECT MAX(sent_at) FROM messages m WHERE m.account_id=c.account_id AND m.chat_id=c.id) DESC, c.id
            """, [.text(accountID)])
        return try rows.map { row in
            let latest = try messages(accountID: accountID, chatID: row[0].string, limit: 1).first
            return StoredChat(id: row[0].string, accountID: accountID, title: row[1].string,
                              isPinned: row[2].integer != 0, lastMessage: latest)
        }
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
        return try connection.query(sql, values).map(Self.decode).reversed()
    }

    /// Literal substring search, not yet FTS/ranked multilingual search. Wildcards are literal.
    public func search(accountID: String, query: String, chatID: String? = nil, limit: Int = 100) throws -> [StoredMessage] {
        guard !query.isEmpty else { return [] }
        var sql = "SELECT \(Self.columns) FROM messages WHERE account_id=? AND instr(lower(body), lower(?)) > 0"
        var values: [Value] = [.text(accountID), .text(query)]
        if let chatID { sql += " AND chat_id=?"; values.append(.text(chatID)) }
        sql += " ORDER BY sent_at DESC, id DESC LIMIT ?"
        values.append(.integer(max(0, min(limit, 1000))))
        return try connection.query(sql, values).map(Self.decode)
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

    public func pendingEncryptedIncoming(accountID: String) throws -> [PendingEncryptedMessage] {
        try connection.query("SELECT sender,digest,wire FROM pending_encrypted_inbox WHERE account_id=? ORDER BY rowid", [.text(accountID)]).map {
            guard let wire = $0[2].data else { throw MessageStoreError.invalidValue }
            return PendingEncryptedMessage(sender: $0[0].string, digest: $0[1].string, wire: wire)
        }
    }

    public func retainEncryptedIncoming(accountID: String, sender: String, digest: String, wire: Data) throws {
        guard !accountID.isEmpty, !sender.isEmpty, !digest.isEmpty, !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            if try hasEncryptedIncoming(accountID: accountID, sender: sender, digest: digest) { return }
            if try !connection.query("SELECT 1 FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)]).isEmpty { return }
            guard try connection.query("SELECT COUNT(*) FROM pending_encrypted_inbox WHERE account_id=?", [.text(accountID)]).first![0].integer < 1000 else { throw MessageStoreError.invalidValue }
            try connection.execute("INSERT INTO pending_encrypted_inbox(account_id,sender,digest,wire) VALUES(?,?,?,?)", [.text(accountID), .text(sender), .text(digest), .blob(wire)])
        }
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

    public func encryptionState(accountID: String) throws -> EncryptionState? {
        guard let row = try connection.query("SELECT revision,snapshot FROM encryption_state WHERE account_id=?", [.text(accountID)]).first else { return nil }
        guard let data = row[1].data, !data.isEmpty else { throw MessageStoreError.invalidValue }
        return EncryptionState(revision: row[0].integer, data: data)
    }

    /// A failed comparison or any persistence error rolls back the whole operation. The caller
    /// must discard its mutated in-memory engine and reload; no crypto callback writes separately.
    public func saveEncryptionState(accountID: String, expectedRevision: Int?, data: Data, control: EncryptionControl? = nil) throws {
        try connection.transaction {
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: data)
            if let control { try insertEncryptionControl(accountID: accountID, control: control) }
        }
    }

    private func insertEncryptionControl(accountID: String, control: EncryptionControl) throws {
        guard !control.id.isEmpty, control.id.utf8.count <= 1024,
              !control.recipient.isEmpty, control.recipient.utf8.count <= 3071,
              !control.wire.isEmpty, control.wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try connection.execute("INSERT INTO encryption_controls(account_id,id,recipient,wire) VALUES(?,?,?,?)",
                               [.text(accountID), .text(control.id), .text(control.recipient), .blob(control.wire)])
    }

    private func writeEncryptionState(accountID: String, expectedRevision: Int?, data: Data) throws {
        guard !accountID.isEmpty, !data.isEmpty, data.count <= 16_777_216 else { throw MessageStoreError.invalidValue }
        let current = try connection.query("SELECT revision FROM encryption_state WHERE account_id=?", [.text(accountID)]).first?[0].integer
        guard current == expectedRevision, (current ?? 0) < Int.max else { throw MessageStoreError.invalidTransition }
        try connection.execute("""
            INSERT INTO encryption_state(account_id,revision,snapshot) VALUES(?,?,?)
            ON CONFLICT(account_id) DO UPDATE SET revision=excluded.revision,snapshot=excluded.snapshot
            """, [.text(accountID), .integer((current ?? 0) + 1), .blob(data)])
    }

    public func queuedOutgoing(accountID: String) throws -> [StoredMessage] {
        try connection.query("""
            SELECT \(Self.columns) FROM messages WHERE account_id=? AND id IN
            (SELECT message_id FROM outbox WHERE account_id=? AND state='queued')
            ORDER BY (SELECT sequence FROM outbox WHERE outbox.account_id=messages.account_id AND outbox.message_id=messages.id) LIMIT 1000
            """, [.text(accountID), .text(accountID)]).map(Self.decode)
    }

    public func encryptedOutgoing(accountID: String, messageID: String) throws -> Data? {
        try connection.query("SELECT wire FROM encrypted_outbox WHERE account_id=? AND message_id=?", [.text(accountID), .text(messageID)]).first?[0].data
    }

    /// Converts an already durable queued intention into exact ciphertext and commits the ratchet
    /// advancement in the SAME transaction. Never overwrites an existing encrypted attempt.
    public func sealQueuedOutgoing(accountID: String, messageID: String, profile: String,
                                   expectedRevision: Int, state: Data, wire: Data, authenticateWireID: Bool = true) throws {
        guard !profile.isEmpty, !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard try encryptedOutgoing(accountID: accountID, messageID: messageID) == nil,
                  try connection.query("SELECT state FROM outbox WHERE account_id=? AND message_id=?", [.text(accountID), .text(messageID)]).first?[0].string == "queued" else { throw MessageStoreError.invalidTransition }
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: state)
            try connection.execute("INSERT INTO encrypted_outbox(account_id,message_id,wire) VALUES(?,?,?)", [.text(accountID), .text(messageID), .blob(wire)])
            try connection.execute("UPDATE messages SET encryption_profile=?,wire_id=?,wire_id_authenticated=? WHERE account_id=? AND id=?", [.text(profile), profile == "modern" && authenticateWireID ? .text(messageID) : .null, .integer(profile == "modern" && authenticateWireID ? 1 : 0), .text(accountID), .text(messageID)])
        }
    }

    public func hasEncryptedIncoming(accountID: String, sender: String, digest: String) throws -> Bool {
        try !connection.query("SELECT 1 FROM encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)]).isEmpty
    }

    /// Authenticated plaintext, consumed prekeys/ratchet changes and replay outcome are inseparable.
    /// A key-transport-only message commits state and replay outcome without creating an empty bubble.
    public func commitEncryptedIncoming(accountID: String, sender: String, digest: String,
                                        expectedRevision: Int, state: Data, message: StoredMessage?, control: EncryptionControl? = nil, reaction: AuthenticatedReaction? = nil, groupRoom: String? = nil, roomStanzaID: String? = nil) throws {
        guard !sender.isEmpty, !digest.isEmpty,
              message.map({ $0.accountID == accountID && $0.senderID == sender && $0.encryptionProfile != nil }) ?? true else { throw MessageStoreError.invalidValue }
        if let groupRoom {
            guard message.map({ $0.chatID == groupRoom }) ?? reaction.map({ $0.chatID == groupRoom }) ?? false else { throw MessageStoreError.invalidValue }
        } else if roomStanzaID != nil { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard try !hasEncryptedIncoming(accountID: accountID, sender: sender, digest: digest) else { throw MessageStoreError.invalidTransition }
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: state)
            if let reaction {
                guard message == nil, reaction.actorID == sender else { throw MessageStoreError.invalidValue }
                try insertReactionEvent(accountID: accountID, reaction: reaction, groupRoom: groupRoom)
            }
            if let message {
                try connection.execute("INSERT INTO chats(account_id,id,title) VALUES(?,?,?) ON CONFLICT(account_id,id) DO NOTHING", [.text(accountID), .text(message.chatID), .text(message.chatID)])
                let inserted = try insertMessageInTransaction(message)
                if let groupRoom {
                    try connection.execute("INSERT INTO group_ciphertext_messages VALUES(?,?,?,?)", [.text(accountID), .text(sender), .text(digest), .text(message.id)])
                    if let roomStanzaID { try bindGroupReference(accountID: accountID, room: groupRoom, messageID: message.id, stanzaID: roomStanzaID) }
                }
                if inserted, !message.isOutgoing, message.senderID != accountID {
                    try connection.execute("INSERT INTO notification_candidates(account_id,message_id) VALUES(?,?)", [.text(accountID), .text(message.id)])
                }
            }
            try connection.execute("INSERT INTO encrypted_inbox(account_id,sender,digest) VALUES(?,?,?)", [.text(accountID), .text(sender), .text(digest)])
            try connection.execute("DELETE FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)])
            if let control {
                guard control.recipient == sender else { throw MessageStoreError.invalidValue }
                try insertEncryptionControl(accountID: accountID, control: control)
            }
        }
    }

    public func claimEncryptionControl(accountID: String) throws -> EncryptionControl? {
        try requireTransportOwnership()
        return try connection.transaction {
            guard let row = try connection.query("SELECT id,recipient,wire FROM encryption_controls WHERE account_id=? AND state='queued' ORDER BY rowid LIMIT 1", [.text(accountID)]).first,
                  let wire = row[2].data else { return nil }
            try connection.execute("UPDATE encryption_controls SET state='submitting' WHERE account_id=? AND id=?", [.text(accountID), .text(row[0].string)])
            return EncryptionControl(id: row[0].string, recipient: row[1].string, wire: wire)
        }
    }

    public func notificationPreviewsEnabled(accountID: String) throws -> Bool {
        (try connection.query("SELECT previews FROM notification_preferences WHERE account_id=?", [.text(accountID)]).first?[0].integer ?? 1) != 0
    }

    public func setNotificationPreviews(accountID: String, enabled: Bool) throws {
        try requireTransportOwnership()
        guard !accountID.isEmpty else { throw MessageStoreError.invalidValue }
        try connection.execute("INSERT INTO notification_preferences(account_id,previews) VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET previews=excluded.previews", [.text(accountID), .integer(enabled ? 1 : 0)])
    }

    /// The foreground owner has already presented these messages. This is notification
    /// bookkeeping, not a read receipt. It cannot race the extension's transport owner.
    public func dismissPendingMessageNotifications(accountID: String) throws {
        try requireTransportOwnership()
        try connection.execute("DELETE FROM notification_candidates WHERE account_id=?", [.text(accountID)])
    }

    /// Consume only authenticated incoming messages committed with their ratchet state.
    /// Replayed ciphertext, key controls, plaintext and outgoing carbons never enter this queue.
    /// Crash before this transaction leaves candidates for the next wakeup; after it, the OS
    /// retains the original generic remote alert if delivery of this richer content fails.
    public func takeMessageNotification(accountID: String) throws -> MessageNotification {
        try requireTransportOwnership()
        return try connection.transaction {
            let values: [Value] = [.text(accountID)]
            let count = try connection.query("SELECT COUNT(*),COUNT(DISTINCT m.chat_id) FROM notification_candidates n JOIN messages m ON m.account_id=n.account_id AND m.id=n.message_id WHERE n.account_id=?", values).first!
            let newest = try connection.query("SELECT n.message_id FROM notification_candidates n JOIN messages m ON m.account_id=n.account_id AND m.id=n.message_id WHERE n.account_id=? ORDER BY m.sent_at DESC,n.sequence DESC LIMIT 1", values).first?[0].string
            let latest = try newest.flatMap { try message(accountID: accountID, messageID: $0) }
            let title = try latest.flatMap { message in
                try connection.query("SELECT title FROM chats WHERE account_id=? AND id=?", [.text(accountID), .text(message.chatID)]).first?[0].string
            }
            let result = MessageNotification(latest: latest, chatTitle: title, messageCount: count[0].integer,
                conversationCount: count[1].integer, previewsEnabled: try notificationPreviewsEnabled(accountID: accountID))
            try dismissPendingMessageNotifications(accountID: accountID)
            return result
        }
    }

    public func finishEncryptionControl(accountID: String, id: String) throws {
        try requireTransportOwnership()
        try connection.execute("UPDATE encryption_controls SET state='unconfirmed' WHERE account_id=? AND id=? AND state='submitting'", [.text(accountID), .text(id)])
    }

    public func message(accountID: String, messageID: String) throws -> StoredMessage? {
        try connection.query("SELECT \(Self.columns) FROM messages WHERE account_id=? AND id=?",
                             [.text(accountID), .text(messageID)]).first.map(Self.decode)
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
            try connection.execute("""
                UPDATE outbox SET state='serverAccepted',attempt_id=NULL WHERE account_id=? AND message_id=?
                AND state IN ('queued','submitting','unconfirmed','failed','serverAccepted')
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
                try connection.execute("UPDATE reaction_updates SET state='serverAccepted',attempt_id=NULL WHERE account_id=? AND id=? AND state IN ('submitting','unconfirmed','serverAccepted')", [.text(accountID), .text(id)])
            }
            return next
        }
    }

    /// Bounded deliberate-rejection receipt for authenticated archive wrappers with
    /// unsupported inner content. No plaintext, author claim or secret material is stored.
    public func recordArchiveRejection(accountID: String, archiveID: String, messageID: String, reason: String) throws {
        try requireTransportOwnership()
        guard !accountID.isEmpty, accountID.utf8.count <= 3071, !archiveID.isEmpty, archiveID.utf8.count <= 3071, !messageID.isEmpty, messageID.utf8.count <= 1024,
              reason == "unverifiableEncryptedGroup" else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            try connection.execute("INSERT INTO archive_rejections(account_id,archive_id,message_id,reason) VALUES(?,?,?,?) ON CONFLICT(account_id,archive_id,message_id) DO NOTHING", [.text(accountID), .text(archiveID), .text(messageID), .text(reason)])
            try connection.execute("DELETE FROM archive_rejections WHERE account_id=? AND sequence NOT IN (SELECT sequence FROM archive_rejections WHERE account_id=? ORDER BY sequence DESC LIMIT 1000)", [.text(accountID), .text(accountID)])
        }
    }
    public func hasArchiveRejection(accountID: String, archiveID: String, messageID: String) throws -> Bool {
        try !connection.query("SELECT 1 FROM archive_rejections WHERE account_id=? AND archive_id=? AND message_id=?", [.text(accountID), .text(archiveID), .text(messageID)]).isEmpty
    }

    public func archiveCheckpoint(accountID: String, archiveID: String) throws -> ArchiveCheckpoint? {
        guard let row = try connection.query("SELECT revision,cursor FROM archive_checkpoints WHERE account_id=? AND archive_id=?", [.text(accountID), .text(archiveID)]).first else { return nil }
        return ArchiveCheckpoint(revision: row[0].integer, cursor: row[1].string)
    }

    /// Advance only after all page results have committed to durable inbox/message storage. CAS
    /// prevents a late page from another synchronization run from overwriting newer progress.
    @discardableResult public func saveArchiveCheckpoint(accountID: String, archiveID: String,
                                                         expectedRevision: Int?, cursor: String) throws -> Int {
        try requireTransportOwnership()
        guard !accountID.isEmpty, !archiveID.isEmpty, !cursor.isEmpty, cursor.utf8.count <= 4096 else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let current = try connection.query("SELECT revision FROM archive_checkpoints WHERE account_id=? AND archive_id=?", [.text(accountID), .text(archiveID)]).first?[0].integer
            guard current == expectedRevision, (current ?? 0) < Int.max else { throw MessageStoreError.invalidTransition }
            let next = (current ?? 0) + 1
            try connection.execute("""
                INSERT INTO archive_checkpoints(account_id,archive_id,revision,cursor) VALUES(?,?,?,?)
                ON CONFLICT(account_id,archive_id) DO UPDATE SET revision=excluded.revision,cursor=excluded.cursor
                """, [.text(accountID), .text(archiveID), .integer(next), .text(cursor)])
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

    /// Resolve only a single authenticated modern origin ID within this account and conversation.
    public func reactionTarget(accountID: String, chatID: String, wireID: String) throws -> StoredMessage? {
        let rows = try connection.query("SELECT \(Self.columns) FROM messages WHERE account_id=? AND chat_id=? AND encryption_profile='modern' AND ((wire_id=? AND wire_id_authenticated=1) OR id IN (SELECT message_id FROM group_message_references WHERE account_id=? AND room=? AND stanza_id=?)) LIMIT 2", [.text(accountID), .text(chatID), .text(wireID), .text(accountID), .text(chatID), .text(wireID)])
        guard rows.count == 1 else { return nil }
        return try Self.decode(rows[0])
    }

    /// Returns each authenticated actor's latest complete set, including an empty withdrawal.
    public func reactions(accountID: String, chatID: String, messageID: String) throws -> [AuthenticatedReaction] {
        guard let message = try message(accountID: accountID, messageID: messageID), message.chatID == chatID,
              let wireID = try reactionReference(accountID: accountID, messageID: messageID),
              try reactionTarget(accountID: accountID, chatID: chatID, wireID: wireID)?.id == messageID else { return [] }
        let rows = try connection.query("SELECT id,chat_id,actor_id,target_wire_id,reactions_json,updated_at FROM reaction_events WHERE account_id=? AND chat_id=? AND target_wire_id=? ORDER BY updated_at DESC,id DESC", [.text(accountID), .text(chatID), .text(wireID)])
        var seen: Set<String> = [], result: [AuthenticatedReaction] = []
        for row in rows where seen.insert(row[2].string).inserted {
            result.append(AuthenticatedReaction(id: row[0].string, chatID: row[1].string, actorID: row[2].string, targetWireID: row[3].string,
                                                reactions: try JSONDecoder().decode([String].self, from: Data(row[4].string.utf8)), updatedAt: Date(timeIntervalSince1970: row[5].double)))
        }
        return result.sorted { $0.actorID < $1.actorID }
    }

    /// One bounded query for a displayed timeline. Ambiguity is checked against the entire
    /// conversation, including colliding message IDs outside the displayed page.
    public func reactionsForChat(accountID: String, chatID: String,
                                 messageIDs: Set<String>) throws -> [String: [AuthenticatedReaction]] {
        guard messageIDs.count <= 1000 else { throw MessageStoreError.invalidValue }
        guard !messageIDs.isEmpty else { return [:] }
        let ids = messageIDs.sorted()
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try connection.query("""
            WITH valid_references AS (
                SELECT account_id,chat_id,id,wire_id FROM messages WHERE account_id=? AND chat_id=? AND wire_id_authenticated=1 AND encryption_profile='modern'
                UNION ALL
                SELECT r.account_id,r.room,r.message_id,r.stanza_id FROM group_message_references r JOIN messages m
                ON m.account_id=r.account_id AND m.id=r.message_id AND m.chat_id=r.room AND m.encryption_profile='modern'
                WHERE r.account_id=? AND r.room=?
            ), requested AS (
                SELECT id,wire_id FROM valid_references
                WHERE account_id=? AND chat_id=? AND id IN (\(placeholders))
            ), unique_targets AS (
                SELECT r.id,r.wire_id FROM requested r WHERE (
                    SELECT COUNT(*) FROM valid_references m WHERE m.account_id=? AND m.chat_id=?
                    AND m.wire_id=r.wire_id
                )=1
            ), latest AS (
                SELECT t.id AS message_id,e.id,e.chat_id,e.actor_id,e.target_wire_id,e.reactions_json,e.updated_at,
                ROW_NUMBER() OVER (PARTITION BY t.id,e.actor_id ORDER BY e.updated_at DESC,e.id DESC) AS position
                FROM unique_targets t JOIN reaction_events e
                ON e.account_id=? AND e.chat_id=? AND e.target_wire_id=t.wire_id
            )
            SELECT message_id,id,chat_id,actor_id,target_wire_id,reactions_json,updated_at
            FROM latest WHERE position=1 ORDER BY message_id,actor_id
            """, [.text(accountID), .text(chatID), .text(accountID), .text(chatID), .text(accountID), .text(chatID)] + ids.map(Value.text) +
                 [.text(accountID), .text(chatID), .text(accountID), .text(chatID)])
        var result: [String: [AuthenticatedReaction]] = [:]
        for row in rows {
            result[row[0].string, default: []].append(AuthenticatedReaction(
                id: row[1].string, chatID: row[2].string, actorID: row[3].string, targetWireID: row[4].string,
                reactions: try JSONDecoder().decode([String].self, from: Data(row[5].string.utf8)),
                updatedAt: Date(timeIntervalSince1970: row[6].double)))
        }
        return result
    }

    @discardableResult public func enqueueReaction(_ update: StoredReactionUpdate, groupRoom: String? = nil) throws -> Bool {
        guard update.actorID == update.accountID else { throw MessageStoreError.invalidValue }
        return try connection.transaction {
            let event = AuthenticatedReaction(id: update.id, chatID: update.chatID, actorID: update.actorID, targetWireID: update.targetWireID, reactions: update.reactions, updatedAt: update.createdAt)
            try Self.validateReaction(accountID: update.accountID, reaction: event, groupRoom: groupRoom)
            guard let target = try reactionTarget(accountID: update.accountID, chatID: update.chatID, wireID: update.targetWireID),
                  target.id == update.targetMessageID else { throw MessageStoreError.invalidValue }
            if let existing = try reactionUpdate(accountID: update.accountID, updateID: update.id) {
                var comparison = update; comparison.transportState = existing.transportState
                guard comparison == existing else { throw MessageStoreError.conflictingIdentity }
                return false
            }
            // Outgoing stream message IDs must identify exactly one durable operation.
            guard try message(accountID: update.accountID, messageID: update.id) == nil,
                  try connection.query("SELECT 1 FROM encryption_controls WHERE account_id=? AND id=?", [.text(update.accountID), .text(update.id)]).isEmpty else { throw MessageStoreError.conflictingIdentity }
            try connection.execute("INSERT INTO reaction_updates(account_id,id,chat_id,target_message_id,target_wire_id,actor_id,reactions_json,created_at,state) VALUES(?,?,?,?,?,?,?,?,'queued')", [.text(update.accountID), .text(update.id), .text(update.chatID), .text(update.targetMessageID), .text(update.targetWireID), .text(update.actorID), .text(try Self.reactionJSON(update.reactions)), .real(update.createdAt.timeIntervalSince1970)])
            try insertReactionEvent(accountID: update.accountID, reaction: event, groupRoom: groupRoom)
            return true
        }
    }

    public func queuedReactions(accountID: String) throws -> [StoredReactionUpdate] {
        try connection.query("SELECT \(Self.reactionColumns) FROM reaction_updates WHERE account_id=? AND state='queued' ORDER BY sequence LIMIT 1000", [.text(accountID)]).map(Self.decodeReaction)
    }

    public func reactionUpdate(accountID: String, updateID: String) throws -> StoredReactionUpdate? {
        try connection.query("SELECT \(Self.reactionColumns) FROM reaction_updates WHERE account_id=? AND id=?", [.text(accountID), .text(updateID)]).first.map(Self.decodeReaction)
    }

    public func encryptedReaction(accountID: String, updateID: String) throws -> Data? {
        try connection.query("SELECT wire FROM reaction_updates WHERE account_id=? AND id=?", [.text(accountID), .text(updateID)]).first?[0].data
    }

    public func sealQueuedReaction(accountID: String, updateID: String, expectedRevision: Int, state: Data, wire: Data) throws {
        guard !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard let update = try reactionUpdate(accountID: accountID, updateID: updateID), update.transportState == .queued,
                  try encryptedReaction(accountID: accountID, updateID: updateID) == nil,
                  try reactionTarget(accountID: accountID, chatID: update.chatID, wireID: update.targetWireID)?.id == update.targetMessageID else { throw MessageStoreError.invalidTransition }
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: state)
            try connection.execute("UPDATE reaction_updates SET wire=? WHERE account_id=? AND id=?", [.blob(wire), .text(accountID), .text(updateID)])
        }
    }

    public func claimNextReaction(accountID: String, updateIDs: Set<String>) throws -> ReactionSubmission? {
        try Task.checkCancellation(); try requireTransportOwnership()
        guard updateIDs.count <= 1000 else { throw MessageStoreError.invalidValue }
        guard !updateIDs.isEmpty else { return nil }
        return try connection.transaction {
            let ordered = updateIDs.sorted()
            let selection = ordered.map { _ in "?" }.joined(separator: ",")
            guard let row = try connection.query("SELECT id FROM reaction_updates WHERE account_id=? AND state='queued' AND wire IS NOT NULL AND id IN (\(selection)) ORDER BY sequence LIMIT 1", [.text(accountID)] + ordered.map(Value.text)).first else { return nil }
            let id = row[0].string, attempt = UUID().uuidString
            try connection.execute("UPDATE reaction_updates SET state='submitting',attempt_id=? WHERE account_id=? AND id=?", [.text(attempt), .text(accountID), .text(id)])
            guard let update = try reactionUpdate(accountID: accountID, updateID: id) else { throw MessageStoreError.invalidTransition }
            return ReactionSubmission(update: update, attemptID: attempt)
        }
    }

    @discardableResult public func finishReactionSubmission(accountID: String, updateID: String, attemptID: String) throws -> Bool {
        try requireTransportOwnership()
        try connection.execute("UPDATE reaction_updates SET state='unconfirmed',attempt_id=NULL WHERE account_id=? AND id=? AND state='submitting' AND attempt_id=?", [.text(accountID), .text(updateID), .text(attemptID)])
        return try connection.query("SELECT changes()").first?[0].integer == 1
    }

    /// Only call when no socket operation was attempted.
    @discardableResult public func releaseUnsentReactionSubmission(accountID: String, updateID: String, attemptID: String) throws -> Bool {
        try requireTransportOwnership()
        try connection.execute("UPDATE reaction_updates SET state='queued',attempt_id=NULL WHERE account_id=? AND id=? AND state='submitting' AND attempt_id=?", [.text(accountID), .text(updateID), .text(attemptID)])
        return try connection.query("SELECT changes()").first?[0].integer == 1
    }

    public func retryReaction(accountID: String, updateID: String) throws {
        try requireTransportOwnership()
        try connection.execute("UPDATE reaction_updates SET state='queued',attempt_id=NULL WHERE account_id=? AND id=? AND state IN ('unconfirmed','failed')", [.text(accountID), .text(updateID)])
        guard try connection.query("SELECT changes()").first?[0].integer == 1 else { throw MessageStoreError.invalidTransition }
    }

    /// Authenticated archive/carbon caller must also compare recipient/profile/envelope before use.
    @discardableResult public func reconcileArchivedReaction(accountID: String, updateID: String, expectedEncryptedWire: Data) throws -> Bool {
        try requireTransportOwnership()
        guard try encryptedReaction(accountID: accountID, updateID: updateID) == expectedEncryptedWire else { return false }
        try connection.execute("UPDATE reaction_updates SET state='serverAccepted',attempt_id=NULL WHERE account_id=? AND id=?", [.text(accountID), .text(updateID)])
        return try connection.query("SELECT changes()").first?[0].integer == 1
    }

    private func insertReactionEvent(accountID: String, reaction: AuthenticatedReaction, groupRoom: String? = nil) throws {
        try Self.validateReaction(accountID: accountID, reaction: reaction, groupRoom: groupRoom)
        // Missing targets remain retained. Ambiguous/missing authenticated IDs never get a projection.
        // A replayed authenticated event ID cannot replace the first accepted content under that ID.
        try connection.execute("INSERT INTO reaction_events(account_id,actor_id,id,chat_id,target_wire_id,reactions_json,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(account_id,actor_id,id) DO NOTHING", [.text(accountID), .text(reaction.actorID), .text(reaction.id), .text(reaction.chatID), .text(reaction.targetWireID), .text(try Self.reactionJSON(reaction.reactions)), .real(reaction.updatedAt.timeIntervalSince1970)])
    }

    private static func validateReaction(accountID: String, reaction: AuthenticatedReaction, groupRoom: String? = nil) throws {
        guard !accountID.isEmpty, !reaction.chatID.isEmpty, reaction.chatID.utf8.count <= 3071,
              (groupRoom == nil ? (reaction.actorID == accountID || reaction.actorID == reaction.chatID) : (groupRoom == reaction.chatID && !reaction.actorID.isEmpty && reaction.actorID.utf8.count <= 3071)),
              !reaction.id.isEmpty, reaction.id.utf8.count <= 1024, !reaction.targetWireID.isEmpty, reaction.targetWireID.utf8.count <= 1024,
              reaction.reactions.count <= 12, Set(reaction.reactions).count == reaction.reactions.count,
              reaction.reactions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              reaction.updatedAt.timeIntervalSince1970.isFinite else { throw MessageStoreError.invalidValue }
    }
    private static func reactionJSON(_ values: [String]) throws -> String { String(decoding: try JSONEncoder().encode(values.sorted()), as: UTF8.self) }
    private static let reactionColumns = "account_id,id,chat_id,target_message_id,target_wire_id,actor_id,reactions_json,created_at,state"
    private static func decodeReaction(_ row: [Value]) throws -> StoredReactionUpdate {
        StoredReactionUpdate(id: row[1].string, accountID: row[0].string, chatID: row[2].string, targetMessageID: row[3].string,
                             targetWireID: row[4].string, actorID: row[5].string,
                             reactions: try JSONDecoder().decode([String].self, from: Data(row[6].string.utf8)),
                             createdAt: Date(timeIntervalSince1970: row[7].double), transportState: OutgoingTransportState(rawValue: row[8].string))
    }

    private static let columns = """
        account_id,id,chat_id,sender_id,body,sent_at,outgoing,starred,
        (SELECT state FROM outbox WHERE outbox.account_id=messages.account_id AND outbox.message_id=messages.id),reply_json,encryption_profile,wire_id,wire_id_authenticated
        """
    private static func validateReply(_ reply: MessageReply) throws {
        guard !reply.messageID.isEmpty, reply.messageID.utf8.count <= 1_024,
              !reply.senderID.isEmpty, reply.senderID.utf8.count <= 3_071,
              reply.body.utf8.count <= 16_384,
              reply.wireID.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true else { throw MessageStoreError.invalidValue }
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
        return StoredMessage(id: row[1].string, accountID: row[0].string, chatID: row[2].string,
                      senderID: row[3].string, body: row[4].string,
                      sentAt: Date(timeIntervalSince1970: row[5].double),
                      isOutgoing: row[6].integer != 0, isStarred: row[7].integer != 0,
                      transportState: OutgoingTransportState(rawValue: row[8].string), reply: reply,
                      encryptionProfile: row[10].string.isEmpty ? nil : row[10].string,
                      wireID: row[11].string.isEmpty ? nil : row[11].string, wireIDAuthenticated: row[12].integer != 0)
    }
}

private enum Value {
    case text(String), integer(Int), real(Double), blob(Data), null
    var data: Data? { if case let .blob(value) = self { return value }; return nil }
    var string: String { if case let .text(value) = self { return value }; return "" }
    var integer: Int { if case let .integer(value) = self { return value }; return 0 }
    var double: Double {
        if case let .real(value) = self { return value }
        if case let .integer(value) = self { return Double(value) }
        return 0
    }
}

/// Owned exclusively by its MessageStore actor after initialization.
private final class Connection: @unchecked Sendable {
    private var handle: OpaquePointer?
    var isOpen: Bool { handle != nil }
    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
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
