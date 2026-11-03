import Foundation

/// Every table of the store, each keyed by `account_id`, and what the account lifecycle does to its rows. Erasing an
/// account (`eraseLocalAccount`) deletes all of them and a snapshot (`writeSnapshot`) copies all of them; a transfer
/// and sign-out follow `policy`. A table the migrations create without a case here fails the store's tests.
public enum AccountTable: String, CaseIterable, Sendable {
    case chats, messages, outbox, attachments
    case encryptedOutbox = "encrypted_outbox", outgoingUpdates = "outgoing_updates", messageEvents = "message_events"
    case messageLinkPreviews = "message_link_previews"
    case groupMessageReferences = "group_message_references", groupCiphertextMessages = "group_ciphertext_messages"
    case encryptionState = "encryption_state", retiredOwnDevices = "retired_own_devices"
    case encryptedInbox = "encrypted_inbox", pendingEncryptedInbox = "pending_encrypted_inbox"
    case streamManagement = "stream_management", archiveCheckpoints = "archive_checkpoints", archiveBackfill = "archive_backfill"
    case archiveGaps = "archive_gaps", archiveRejections = "archive_rejections", chatReadState = "chat_read_state", readBaselines = "read_baselines"
    case accountPreferences = "account_preferences"
    case notificationCandidates = "notification_candidates", pendingNotificationCandidates = "pending_notification_candidates"
    case reactionNotificationCandidates = "reaction_notification_candidates", reactionNotificationsPosted = "reaction_notifications_posted"
    case linkPreviewCache = "link_preview_cache"
    case contactLinks = "contact_links"

    public enum Transfer: Sendable, Equatable {
        case copy
        /// Deleted from the transfer's copy before it is packed, and from an archive before its restore commits.
        case omit(reason: String)
    }

    public enum SignOut: Sendable, Equatable {
        case keep(reason: String)
        /// Deleted by `removeRowsAtSignOut(accountID:)`.
        case delete
    }

    public struct Policy: Sendable, Equatable {
        public let transfer: Transfer
        public let signOut: SignOut
    }

    public var policy: Policy {
        switch self {
        case .chats, .messages, .outbox, .attachments, .encryptedOutbox, .outgoingUpdates, .messageEvents, .messageLinkPreviews,
             .groupMessageReferences, .groupCiphertextMessages:
            Policy(transfer: .copy, signOut: .keep(reason: "signing in again finds the history, and queued sends go out then"))
        case .encryptionState, .retiredOwnDevices, .encryptedInbox, .pendingEncryptedInbox:
            Policy(transfer: .copy, signOut: .keep(reason: "an encryption identity is never replaced, and its replay ledger and retained ciphertext belong to it"))
        case .streamManagement, .archiveCheckpoints, .archiveBackfill, .archiveGaps, .archiveRejections, .chatReadState, .readBaselines:
            Policy(transfer: .copy, signOut: .keep(reason: "synchronisation goes on from where it stopped"))
        case .accountPreferences:
            Policy(transfer: .copy, signOut: .keep(reason: "the account's own settings"))
        case .notificationCandidates, .pendingNotificationCandidates, .reactionNotificationCandidates, .reactionNotificationsPosted:
            // Sign-out takes every delivered and pending notification off the system; what still waited goes with them.
            Policy(transfer: .copy, signOut: .delete)
        case .linkPreviewCache:
            Policy(transfer: .copy, signOut: .keep(reason: "the account's own fetches; the images live in its attachment folder"))
        case .contactLinks:
            Policy(transfer: .omit(reason: "a Contacts identifier means something only on the device that made the link"),
                   signOut: .keep(reason: "the link belongs to this device and this account"))
        }
    }
}

extension MessageStore {
    /// Deletes every account's rows from each table whose transfer policy (`AccountTable`) is `omit`, in a store copy
    /// nobody has open (an account transfer, before packing and before a restore commits). Deleted rows are overwritten,
    /// not left in free pages. Returns the contact-link photos no chat's verified avatar still names, whose files the
    /// caller leaves out; only well-formed hashes, as the copy may come from an archive.
    public static func removeDeviceLocalRows(fromSnapshotAt url: URL) throws -> [ContactLinkPhoto] {
        let copy = try Connection(url: url, create: false)
        defer { try? copy.close() }
        let present = Set(try copy.query("SELECT name FROM sqlite_master WHERE type='table'").map { $0[0].string })
        let omitted = AccountTable.allCases.filter { present.contains($0.rawValue) && $0.policy.transfer != .copy }
        guard !omitted.isEmpty else { return [] }
        try copy.execute("PRAGMA secure_delete = ON")
        return try copy.transaction {
            let photos = !omitted.contains(.contactLinks) ? [] : try copy.query("""
                SELECT DISTINCT account_id,image_hash FROM contact_links l WHERE image_hash IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM chats c WHERE c.account_id=l.account_id AND c.avatar_hash=l.image_hash)
                ORDER BY account_id,image_hash
                """).map { ContactLinkPhoto(accountID: $0[0].string, hash: $0[1].string) }.filter { ContactLink.isHash($0.hash) }
            try copy.execute("PRAGMA defer_foreign_keys = ON")
            for table in omitted { try copy.execute("DELETE FROM \"\(table.rawValue)\"") }
            return photos
        }
    }
}
