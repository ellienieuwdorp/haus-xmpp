import Foundation
import CSQLite

/// Development plaintext store. Caller owns directory/file protection and transport identity validation.
/// Serializes access in this process only; it does not coordinate crypto or notification extensions.
public actor MessageStore {
    private let connection: Connection

    public init(url: URL) throws {
        connection = try Connection(url: url)
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA synchronous = FULL")
        let version = try connection.query("PRAGMA user_version").first?[0].integer ?? 0
        guard version <= 4 else { throw MessageStoreError.unsupportedSchema(version) }
        try connection.transaction {
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
            // The previous process might have written to the socket before termination. Never auto-replay.
            try connection.execute("UPDATE outbox SET state='unconfirmed', attempt_id=NULL WHERE state='submitting'")
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
            try connection.execute("UPDATE encryption_controls SET state='unconfirmed' WHERE state='submitting'")
            try connection.execute("PRAGMA user_version = 4")
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
              message.sentAt.timeIntervalSince1970.isFinite else { throw MessageStoreError.invalidValue }
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
            INSERT INTO messages(account_id,id,chat_id,sender_id,body,sent_at,outgoing,starred,reply_json,encryption_profile)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [.text(message.accountID), .text(message.id), .text(message.chatID), .text(message.senderID),
                  .text(message.body), .real(message.sentAt.timeIntervalSince1970),
                  .integer(message.isOutgoing ? 1 : 0), .integer(message.isStarred ? 1 : 0), replyJSON, message.encryptionProfile.map(Value.text) ?? .null])
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

    /// FIFO by durable enqueue order, independent of message timestamps.
    public func claimNextOutgoing(accountID: String, messageIDs: Set<String>? = nil) throws -> OutboxSubmission? {
        try Task.checkCancellation()
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
        try connection.transaction {
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
        try connection.transaction {
            try connection.execute("""
                UPDATE outbox SET state='unconfirmed',attempt_id=NULL
                WHERE account_id=? AND message_id=? AND state='submitting' AND attempt_id=?
                """, [.text(submission.message.accountID), .text(submission.message.id), .text(submission.attemptID)])
            return try connection.query("SELECT changes()").first?[0].integer == 1
        }
    }

    /// Only use after stopping/joining that account's sender. A new store performs the same recovery.
    public func recoverInterruptedSubmissions(accountID: String) throws {
        try connection.execute("UPDATE outbox SET state='unconfirmed',attempt_id=NULL WHERE account_id=? AND state='submitting'",
                               [.text(accountID)])
    }

    /// Caller must explicitly warn that retry can duplicate a message already accepted remotely.
    public func retryOutgoing(accountID: String, messageID: String) throws {
        try connection.transaction {
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
        try connection.transaction {
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

    public func encryptionState(accountID: String) throws -> EncryptionState? {
        guard let row = try connection.query("SELECT revision,snapshot FROM encryption_state WHERE account_id=?", [.text(accountID)]).first else { return nil }
        guard let data = row[1].data, !data.isEmpty else { throw MessageStoreError.invalidValue }
        return EncryptionState(revision: row[0].integer, data: data)
    }

    /// A failed comparison or any persistence error rolls back the whole operation. The caller
    /// must discard its mutated in-memory engine and reload; no crypto callback writes separately.
    public func saveEncryptionState(accountID: String, expectedRevision: Int?, data: Data) throws {
        try connection.transaction { try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: data) }
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
                                   expectedRevision: Int, state: Data, wire: Data) throws {
        guard !profile.isEmpty, !wire.isEmpty, wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard try encryptedOutgoing(accountID: accountID, messageID: messageID) == nil,
                  try connection.query("SELECT state FROM outbox WHERE account_id=? AND message_id=?", [.text(accountID), .text(messageID)]).first?[0].string == "queued" else { throw MessageStoreError.invalidTransition }
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: state)
            try connection.execute("INSERT INTO encrypted_outbox(account_id,message_id,wire) VALUES(?,?,?)", [.text(accountID), .text(messageID), .blob(wire)])
            try connection.execute("UPDATE messages SET encryption_profile=? WHERE account_id=? AND id=?", [.text(profile), .text(accountID), .text(messageID)])
        }
    }

    public func hasEncryptedIncoming(accountID: String, sender: String, digest: String) throws -> Bool {
        try !connection.query("SELECT 1 FROM encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)]).isEmpty
    }

    /// Authenticated plaintext, consumed prekeys/ratchet changes and replay outcome are inseparable.
    /// A key-transport-only message commits state and replay outcome without creating an empty bubble.
    public func commitEncryptedIncoming(accountID: String, sender: String, digest: String,
                                        expectedRevision: Int, state: Data, message: StoredMessage?, control: EncryptionControl? = nil) throws {
        guard !sender.isEmpty, !digest.isEmpty,
              message.map({ $0.accountID == accountID && $0.senderID == sender && $0.encryptionProfile != nil }) ?? true else { throw MessageStoreError.invalidValue }
        try connection.transaction {
            guard try !hasEncryptedIncoming(accountID: accountID, sender: sender, digest: digest) else { throw MessageStoreError.invalidTransition }
            try writeEncryptionState(accountID: accountID, expectedRevision: expectedRevision, data: state)
            if let message {
                try connection.execute("INSERT INTO chats(account_id,id,title) VALUES(?,?,?) ON CONFLICT(account_id,id) DO NOTHING", [.text(accountID), .text(message.chatID), .text(message.chatID)])
                _ = try insertMessageInTransaction(message)
            }
            try connection.execute("INSERT INTO encrypted_inbox(account_id,sender,digest) VALUES(?,?,?)", [.text(accountID), .text(sender), .text(digest)])
            try connection.execute("DELETE FROM pending_encrypted_inbox WHERE account_id=? AND sender=? AND digest=?", [.text(accountID), .text(sender), .text(digest)])
            if let control {
                guard !control.id.isEmpty, control.recipient == sender, !control.wire.isEmpty, control.wire.count <= 1_048_576 else { throw MessageStoreError.invalidValue }
                try connection.execute("INSERT INTO encryption_controls(account_id,id,recipient,wire) VALUES(?,?,?,?)", [.text(accountID), .text(control.id), .text(control.recipient), .blob(control.wire)])
            }
        }
    }

    public func claimEncryptionControl(accountID: String) throws -> EncryptionControl? {
        try connection.transaction {
            guard let row = try connection.query("SELECT id,recipient,wire FROM encryption_controls WHERE account_id=? AND state='queued' ORDER BY rowid LIMIT 1", [.text(accountID)]).first,
                  let wire = row[2].data else { return nil }
            try connection.execute("UPDATE encryption_controls SET state='submitting' WHERE account_id=? AND id=?", [.text(accountID), .text(row[0].string)])
            return EncryptionControl(id: row[0].string, recipient: row[1].string, wire: wire)
        }
    }

    public func finishEncryptionControl(accountID: String, id: String) throws {
        try connection.execute("UPDATE encryption_controls SET state='unconfirmed' WHERE account_id=? AND id=? AND state='submitting'", [.text(accountID), .text(id)])
    }

    private static let columns = """
        account_id,id,chat_id,sender_id,body,sent_at,outgoing,starred,
        (SELECT state FROM outbox WHERE outbox.account_id=messages.account_id AND outbox.message_id=messages.id),reply_json,encryption_profile
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
                      encryptionProfile: row[10].string.isEmpty ? nil : row[10].string)
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
    deinit { sqlite3_close(handle) }
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
