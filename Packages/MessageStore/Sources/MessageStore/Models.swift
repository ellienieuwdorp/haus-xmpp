import Foundation
import CryptoKit

public struct StoredMessage: Identifiable, Equatable, Sendable {
    /// Application-generated stable identity, unique within an account. Not an untrusted stanza ID.
    public let id: String
    public let accountID: String
    public let chatID: String
    public let senderID: String
    /// The stored body is immutable; `applying(_:)` returns a copy carrying the sender's latest correction.
    public var body: String
    public let reply: MessageReply?
    public var encryptionProfile: String?
    public let wireID: String?
    public let wireIDAuthenticated: Bool
    public let sentAt: Date
    public let isOutgoing: Bool
    public var isStarred: Bool
    public var transportState: OutgoingTransportState?
    /// The one file this message shares; `body` is then its caption and may be empty.
    public var attachment: StoredAttachment?
    /// Set only on a placeholder row (`encryptionProfile == "unreadable"`, empty body): why this device cannot show it.
    public var unreadableReason: UnreadableReason?
    /// Projection flags, set only by `applying(_:)`; never persisted.
    public var isRetracted = false
    public var isEdited = false

    /// The message as its sender now asserts it: unsent, or carrying the latest correction body.
    /// `events` must come from `events`/`eventsForChat`, which already enforce who may say what.
    public func applying(_ events: [MessageEvent]) -> StoredMessage {
        var result = self
        for event in events where event.actorID == senderID {
            switch event.kind {
            case .retraction: result.isRetracted = true; result.isEdited = false; result.body = ""; result.attachment = nil
            case .correction: if !result.isRetracted, let body = MessageEvent.correctionBody(event.payload) { result.body = body; result.isEdited = true }
            default: break
            }
        }
        return result
    }

    public init(id: String, accountID: String, chatID: String, senderID: String, body: String,
                sentAt: Date = Date(), isOutgoing: Bool = false, isStarred: Bool = false,
                transportState: OutgoingTransportState? = nil, reply: MessageReply? = nil, encryptionProfile: String? = nil, wireID: String? = nil, wireIDAuthenticated: Bool = false,
                attachment: StoredAttachment? = nil, unreadableReason: UnreadableReason? = nil) {
        self.attachment = attachment
        self.unreadableReason = unreadableReason
        self.id = id
        self.accountID = accountID
        self.chatID = chatID
        self.senderID = senderID
        self.body = body
        self.reply = reply
        self.encryptionProfile = encryptionProfile
        self.wireID = wireID; self.wireIDAuthenticated = wireIDAuthenticated
        self.sentAt = sentAt
        self.isOutgoing = isOutgoing
        self.isStarred = isStarred
        self.transportState = transportState
    }

    /// The text a reply to this message quotes: its body, or for a file without a caption, the file's quote label.
    /// Replies store this snapshot (`MessageReply.body`), so the strip, the bubble and the wire all show the same words.
    public var quoteText: String {
        guard body.isEmpty, let attachment else { return body }
        return attachment.quoteLabel
    }
}

/// Metadata and transfer state of a shared file. Bytes live in the file cache keyed by `hash`,
/// never in the database; the key and IV are sealed by the encryption layer and opaque here.
public struct StoredAttachment: Sendable, Equatable, Codable {
    public enum UploadState: String, Sendable, Codable { case pending, uploaded }
    public var name: String
    public var mediaType: String
    public var size: Int
    public var width: Int?
    public var height: Int?
    /// Hex SHA-256 of the plaintext; empty when the sender gave none (legacy `aesgcm://`).
    public var hash: String
    public var cipherHash: String?
    public var secret: Data
    public var url: String?
    /// Nil for received files. A queued message is not sendable until this is `uploaded`.
    public var uploadState: UploadState?
    public var uploadTaskID: Int?
    /// The account spelling `secret` was sealed under when that differs from the row's key (v23 address migration).
    public var sealedAccount: String?

    public init(name: String, mediaType: String, size: Int, width: Int? = nil, height: Int? = nil, hash: String, cipherHash: String? = nil,
                secret: Data, url: String? = nil, uploadState: UploadState? = nil, uploadTaskID: Int? = nil) {
        self.name = name; self.mediaType = mediaType; self.size = size; self.width = width; self.height = height
        self.hash = hash; self.cipherHash = cipherHash; self.secret = secret; self.url = url; self.uploadState = uploadState; self.uploadTaskID = uploadTaskID
    }
    public var isImage: Bool { mediaType.hasPrefix("image/") }
    public var isVideo: Bool { mediaType.hasPrefix("video/") }
    /// Chat-list and notification stand-in for an empty caption.
    public var kindLabel: String { isImage ? "Photo" : isVideo ? "Video" : mediaType.hasPrefix("audio/") ? "Audio" : "File" }
    /// What a reply to this file quotes when it has no caption: the kind for media, the file name for a document.
    /// One line, because the quote is a one-line snapshot in the composer, the bubble and the wire fallback.
    public var quoteLabel: String {
        guard !isImage, !isVideo, !mediaType.hasPrefix("audio/") else { return kindLabel }
        let line = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? kindLabel : String(line.prefix(200))
    }
}

public struct StoredChat: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let title: String
    public let isPinned: Bool
    public let lastMessage: StoredMessage?
    /// SHA-1 of the verified avatar bytes on disk; nil when none is known.
    public var avatarHash: String? = nil
    /// Strongest receipt on an outgoing `lastMessage`: `.displayed`, `.delivered` or nil.
    public var lastMessageReceipt: MessageEventKind? = nil
    /// Local notification level and mute; the default when never changed.
    public var notification = ChatNotificationSetting()
    /// Incoming messages after the chat's read pointer (`MessageStore.unreadCounts`).
    public var unreadCount: Int = 0
}

/// A chat's read pointer: everything at or below this message (by `sentAt`, then id) has been read on some device.
public struct ReadPointer: Sendable, Equatable {
    public let messageID: String
    public let sentAt: Date
    /// A local read that XEP-0490 has not published yet.
    public let publishPending: Bool
}

/// Another device of this account displayed a peer message (XEP-0333 inside authenticated SCE content).
public struct OwnReadMarker: Sendable, Equatable {
    public let chatID: String
    public let targetWireID: String
    public init(chatID: String, targetWireID: String) { self.chatID = chatID; self.targetWireID = targetWireID }
}

/// One XEP-0490 item to publish: `chatID` read through the message the archive `by` named `stanzaID`.
/// `pointerMessageID` is the read pointer it was computed from, so a newer read is not cleared by an older publish.
public struct DisplayedSyncPublication: Sendable, Equatable {
    public let chatID: String
    public let stanzaID: String
    public let by: String
    public let pointerMessageID: String
    public init(chatID: String, stanzaID: String, by: String, pointerMessageID: String) {
        self.chatID = chatID; self.stanzaID = stanzaID; self.by = by; self.pointerMessageID = pointerMessageID
    }
}

public enum MessageStoreError: Error, Equatable, Sendable {
    case database(code: Int32, message: String)
    case conflictingIdentity
    case unsupportedSchema(Int)
    case invalidValue
    case invalidTransition
    case transportOwnershipRequired
    case transportOwnedElsewhere
    case closed
    /// Opened `currentOnly` over a store an older build wrote: only the app migrates it (after its snapshot).
    case upgradeRequired(Int)
    /// The database file was replaced (restored or moved) after this store opened it.
    case replaced
    /// A snapshot copy did not match its source: integrity, schema or row counts.
    case snapshotMismatch(String)
}

/// Local progress and authenticated stream acknowledgement. None proves peer delivery.
public enum OutgoingTransportState: String, Equatable, Sendable {
    case queued, submitting, unconfirmed, failed, serverAccepted
}

/// A claim token fences late callbacks after recovery and manual retry.
public struct OutboxSubmission: Equatable, Sendable {
    public let message: StoredMessage
    public let attemptID: String
}

/// Local snapshot of a selected message. This is not a validated incoming protocol reference.
public struct MessageReply: Codable, Sendable, Equatable {
    public let messageID: String
    public let wireID: String?
    public let senderID: String
    public let body: String
    /// The quoted file's media type, nil for text. Local only, never sent: it lets the quote keep a photo or video
    /// still's slot before that file is loaded or downloaded, so the bubble's width does not change when it arrives.
    public let mediaType: String?

    public init(messageID: String, senderID: String, body: String, wireID: String? = nil, mediaType: String? = nil) {
        self.messageID = messageID
        self.wireID = wireID
        self.senderID = senderID
        self.body = body
        self.mediaType = mediaType
    }
}

/// Opaque application encryption state, versioned for optimistic concurrency across owners.
public struct EncryptionState: Sendable, Equatable {
    public let revision: Int
    public let data: Data
    /// The account spelling `data` was sealed under when that differs from the row's key: set by the v23 address
    /// migration for state saved under the typed spelling, cleared by the next save.
    public var sealedAccount: String? = nil
}

public struct PendingEncryptedMessage: Sendable {
    public let sender: String
    public let digest: String
    public let wire: Data
    public let reason: PendingEncryptedReason
}

/// A pending row without its ciphertext. The optional fields are projected from the retained-envelope JSON that
/// OMEMO writes; they are untrusted strings for grouping and counting, never display content.
public struct PendingEncryptedSummary: Sendable, Equatable {
    public let sender: String
    public let digest: String
    /// The stored classification, raw (`trustPending`, `keysPending`); counting by reason needs no second query.
    public let reason: String
    /// Group envelopes: `$.message.room`.
    public let room: String?
    /// Group envelopes: `$.message.sender`.
    public let roomSender: String?
    /// Direct envelopes: `$.from`.
    public let from: String?
    /// Direct envelopes: `$.to`.
    public let to: String?
    /// Direct envelopes: `$.provenance` (`direct`, `receivedCarbon` or `sentCarbon`).
    public let provenance: String?
}

/// Why a message row is a placeholder and not content. Stored in `messages.unreadable_reason`.
public enum UnreadableReason: String, Sendable, Equatable, CaseIterable {
    /// The envelope carried no key for this device (own other-device send, history before this installation, or a peer that excluded this device).
    case notForThisDevice
    /// Encrypted with something this client does not implement (OpenPGP/OX, an unknown OMEMO namespace, an EME hint without an envelope).
    case unsupportedEncryption
    /// The envelope or its key material could not be parsed, or addressed this device ambiguously.
    case malformedContent
    /// A trusted sender device's ciphertext failed ratchet decrypt, payload authentication or content decoding.
    case decryptFailed
    /// The sender device is one the user blocked: its ciphertext is never opened and never kept for review.
    case rejectedDevice
    /// Not kept for review because its sender, or the account, already had as much ciphertext waiting as
    /// `MessageStore.pendingLimits` allows.
    case retentionLimit

    /// Whether an incoming placeholder may alert (plan D5). A blocked device was the user's own decision, and a limit is
    /// reached only by a sender whose earlier waiting messages already alerted, or by a flood: both stay quiet.
    public var alerts: Bool { self != .rejectedDevice && self != .retentionLimit }
}

/// What `MessageStore.retainEncryptedIncoming` records instead of a pending row when a retention limit leaves no room.
public struct RetentionOverflow: Sendable, Equatable {
    /// The conversation the ciphertext belongs to (the direct peer, or the room): whether the account took part in it
    /// decides whether the sender counts as known.
    public let chatID: String
    /// The `.retentionLimit` placeholder for ciphertext that would have been a bubble. Nil consumes the replay identity
    /// without a row (a key transport, reaction or receipt).
    public let placeholder: UnreadableMessage?
    /// The sender device is one the user approved: the row waits for a retry (a room read, a transient failure), not for
    /// a review, so only the account ceiling bounds it.
    public let senderApproved: Bool
    public init(chatID: String, placeholder: UnreadableMessage?, senderApproved: Bool = false) {
        self.chatID = chatID; self.placeholder = placeholder; self.senderApproved = senderApproved
    }
}

/// How much ciphertext `pending_encrypted_inbox` keeps for review, per account. A sender is known when it is the account
/// itself, when the account wrote in the conversation or in a direct chat with it, or when a message of theirs was
/// authenticated in their direct chat or in this room (so some device of theirs was approved). Everyone else is a
/// stranger. A row from an approved device (`RetentionOverflow.senderApproved`) meets only `perAccount`. The roster is not a signal:
/// it lives in memory for one connection and the notification extension never loads it.
public struct PendingRetentionLimits: Sendable, Equatable {
    /// Rows one known sender may hold (all its devices together).
    public let perKnownSender: Int
    /// Rows one stranger may hold.
    public let perStranger: Int
    /// A stranger's ciphertext is kept only while the account holds fewer rows than this, so strangers together can
    /// never take the room known contacts need.
    public let strangerCeiling: Int
    /// Rows the account may hold at all.
    public let perAccount: Int
}

/// Why a retained ciphertext is still in `pending_encrypted_inbox`.
public enum PendingEncryptedReason: String, Sendable, Equatable, CaseIterable {
    /// The sender device is known; its trust is undecided or changed.
    case trustPending
    /// The sender device is unknown, after a failed or completed device refresh.
    case keysPending
}

/// A durable "not shown here" marker. Never plaintext, never authenticated, never a reaction target.
public struct UnreadableMessage: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        /// Ciphertext identity from OMEMO (the addressed-key digest, or the unaddressed digest when no key exists).
        case ciphertext(sender: String, digest: String)
        /// A validated own-archive position whose inner content the parser rejected.
        case archive(archive: String, id: String)
    }
    public let accountID: String
    public let chatID: String
    public let senderID: String
    public let isOutgoing: Bool
    public let sentAt: Date
    public let reason: UnreadableReason
    public let key: Key

    public init(accountID: String, chatID: String, senderID: String, isOutgoing: Bool, sentAt: Date, reason: UnreadableReason, key: Key) {
        self.accountID = accountID; self.chatID = chatID; self.senderID = senderID
        self.isOutgoing = isOutgoing; self.sentAt = sentAt; self.reason = reason; self.key = key
    }

    /// `"unreadable-" + SHA-256 hex` of `"ciphertext\u{0}<sender>\u{0}<digest>"` or `"archive\u{0}<archive>\u{0}<id>"`.
    /// Deterministic, so a repeated observation of the same ciphertext or archive position maps to the same row.
    public var id: String {
        let material: String
        switch key {
        case let .ciphertext(sender, digest): material = "ciphertext\u{0}\(sender)\u{0}\(digest)"
        case let .archive(archive, id): material = "archive\u{0}\(archive)\u{0}\(id)"
        }
        return "unreadable-" + SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct EncryptionControl: Sendable {
    public let id: String
    public let recipient: String
    public let wire: Data
    public init(id: String, recipient: String, wire: Data) { self.id = id; self.recipient = recipient; self.wire = wire }
}

/// Opaque protocol-owned SM snapshot. Revision CAS and transport ownership fence stale saves.
public struct StreamManagementState: Sendable, Equatable {
    public let revision: Int
    public let data: Data
}

public struct ArchiveCheckpoint: Sendable, Equatable {
    public let revision: Int
    public let cursor: String
    /// The archive `<delay stamp>` of the entry `cursor` names: where a forward walk restarts by time when the server
    /// no longer holds the cursor. nil for checkpoints saved before schema 22.
    public let stamp: Date?
    public init(revision: Int, cursor: String, stamp: Date? = nil) { self.revision = revision; self.cursor = cursor; self.stamp = stamp }
}

/// A forward cursor the server no longer held (XEP-0313 `item-not-found`), recorded once per lost cursor. Entries
/// between `since` (the lost entry's archive time, when known) and the first entry fetched after it may have
/// expired from the server before this device fetched them; messages received live in that time are unaffected.
public struct ArchiveGap: Sendable, Equatable {
    public let archiveID: String
    public let since: Date?
    public let detectedAt: Date
    public init(archiveID: String, since: Date?, detectedAt: Date) { self.archiveID = archiveID; self.since = since; self.detectedAt = detectedAt }
}

/// The backward cursor of one archive's history backfill (newest-first sync).
public struct ArchiveBackfillCursor: Sendable, Equatable {
    public let revision: Int
    /// The oldest archive ID committed for this archive; the next backfill page ends before it.
    public let oldestID: String
    /// True once the server reported that nothing older exists.
    public let complete: Bool
    public init(revision: Int, oldestID: String, complete: Bool) { self.revision = revision; self.oldestID = oldestID; self.complete = complete }
}


/// A durable complete reaction set, separate from visible chat messages.
public struct StoredReactionUpdate: Sendable, Equatable {
    public let id: String
    public let accountID: String
    public let chatID: String
    public let targetMessageID: String
    public let targetWireID: String
    public let actorID: String
    public let reactions: [String]
    public let createdAt: Date
    public var transportState: OutgoingTransportState?
    public init(id: String, accountID: String, chatID: String, targetMessageID: String, targetWireID: String, actorID: String,
                reactions: [String], createdAt: Date = Date(), transportState: OutgoingTransportState? = nil) {
        self.id = id; self.accountID = accountID; self.chatID = chatID; self.targetMessageID = targetMessageID
        self.targetWireID = targetWireID; self.actorID = actorID; self.reactions = reactions.sorted()
        self.createdAt = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        self.transportState = transportState
    }
}

/// Actor and update time must come from authenticated encrypted content/provenance.
public struct AuthenticatedReaction: Sendable, Equatable {
    public let id: String
    public let chatID: String
    public let actorID: String
    public let targetWireID: String
    public let reactions: [String]
    public let updatedAt: Date
    public init(id: String, chatID: String, actorID: String, targetWireID: String, reactions: [String], updatedAt: Date) {
        self.id = id; self.chatID = chatID; self.actorID = actorID; self.targetWireID = targetWireID; self.reactions = reactions.sorted()
        self.updatedAt = Date(timeIntervalSince1970: (updatedAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    /// The projection row: reactions are one event kind among several.
    public init?(_ event: MessageEvent) {
        guard event.kind == .reaction, let values = try? JSONDecoder().decode([String].self, from: Data(event.payload.utf8)) else { return nil }
        self.init(id: event.id, chatID: event.chatID, actorID: event.actorID, targetWireID: event.targetWireID, reactions: values, updatedAt: event.updatedAt)
    }
    public func event() throws -> MessageEvent {
        MessageEvent(id: id, chatID: chatID, actorID: actorID, targetWireID: targetWireID, kind: .reaction,
                     payload: String(decoding: try JSONEncoder().encode(reactions), as: UTF8.self), updatedAt: updatedAt)
    }
}

/// Message-scoped events other peers or our own devices assert about a target message. Reactions
/// and receipts (`delivered`, `displayed`) are accepted; retraction and correction are reserved.
public enum MessageEventKind: String, Sendable, CaseIterable {
    case reaction, retraction, correction, delivered, displayed
}

/// One row of `message_events`: idempotent per (account, actor, id); the newest per (target, actor, kind) wins.
public struct MessageEvent: Sendable, Equatable {
    public let id: String
    public let chatID: String
    public let actorID: String
    public let targetWireID: String
    public let kind: MessageEventKind
    /// JSON whose shape is fixed per kind: a sorted emoji array for reactions.
    public let payload: String
    public let updatedAt: Date
    public init(id: String, chatID: String, actorID: String, targetWireID: String, kind: MessageEventKind, payload: String, updatedAt: Date) {
        self.id = id; self.chatID = chatID; self.actorID = actorID; self.targetWireID = targetWireID; self.kind = kind; self.payload = payload
        self.updatedAt = Date(timeIntervalSince1970: (updatedAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    /// A correction's payload is the replacement body as one JSON string; a retraction's is `{}`.
    public static func correctionPayload(_ body: String) throws -> String {
        guard !body.isEmpty, body.utf8.count <= 65_536 else { throw MessageStoreError.invalidValue }
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }
    public static func correctionBody(_ payload: String) -> String? {
        guard let body = try? JSONDecoder().decode(String.self, from: Data(payload.utf8)), !body.isEmpty, body.utf8.count <= 65_536 else { return nil }
        return body
    }
}

/// One row of the durable update outbox: every outgoing stanza that is not a chat message.
/// The sealed wire is the exact bytes (or prepared envelope) that may ever be sent under this ID.
public struct StoredUpdate: Sendable, Equatable {
    /// `receipt` is a XEP-0184 `<received/>`, `marker` a XEP-0333 `<displayed/>`; both name a peer message.
    public enum Kind: String, Sendable { case reaction, keyTransport, receipt, marker, retraction, correction }
    public let id: String
    public let accountID: String
    public let kind: Kind
    public let chatID: String
    public var transportState: OutgoingTransportState?
    /// Message-scoped kinds (reaction, receipt, marker, retraction, correction) name the message they were queued against.
    public var targetMessageID: String? = nil
    public var targetWireID: String? = nil
    /// The kind's own payload: a sorted emoji array for reactions, the JSON body for corrections.
    public var payload: String? = nil
}

/// Per-account switches. Receipt switches gate what we send back; requesting is unconditional.
/// `lastSeen` decides whether contacts may subscribe to our presence and learn when we were last active.
public struct AccountPreferences: Sendable, Equatable {
    public var notificationPreviews = true
    public var deliveryReceipts = true
    public var readReceipts = true
    public var lastSeen = true
    /// Others' authenticated reactions to this account's messages alert (plan D8). Defaults on.
    public var reactionNotifications = true
    public init(notificationPreviews: Bool = true, deliveryReceipts: Bool = true, readReceipts: Bool = true, lastSeen: Bool = true,
                reactionNotifications: Bool = true) {
        self.notificationPreviews = notificationPreviews; self.deliveryReceipts = deliveryReceipts; self.readReceipts = readReceipts
        self.lastSeen = lastSeen; self.reactionNotifications = reactionNotifications
    }
}

public struct UpdateSubmission: Sendable, Equatable {
    public let update: StoredUpdate
    public let wire: Data
    public let attemptID: String
}
