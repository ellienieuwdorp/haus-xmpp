import Foundation

public struct StoredMessage: Identifiable, Equatable, Sendable {
    /// Application-generated stable identity, unique within an account. Not an untrusted stanza ID.
    public let id: String
    public let accountID: String
    public let chatID: String
    public let senderID: String
    public let body: String
    public let reply: MessageReply?
    public var encryptionProfile: String?
    public let wireID: String?
    public let wireIDAuthenticated: Bool
    public let sentAt: Date
    public let isOutgoing: Bool
    public var isStarred: Bool
    public var transportState: OutgoingTransportState?

    public init(id: String, accountID: String, chatID: String, senderID: String, body: String,
                sentAt: Date = Date(), isOutgoing: Bool = false, isStarred: Bool = false,
                transportState: OutgoingTransportState? = nil, reply: MessageReply? = nil, encryptionProfile: String? = nil, wireID: String? = nil, wireIDAuthenticated: Bool = false) {
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
}

public struct StoredChat: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let title: String
    public let isPinned: Bool
    public let lastMessage: StoredMessage?
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

    public init(messageID: String, senderID: String, body: String, wireID: String? = nil) {
        self.messageID = messageID
        self.wireID = wireID
        self.senderID = senderID
        self.body = body
    }
}

/// Opaque application encryption state, versioned for optimistic concurrency across owners.
public struct EncryptionState: Sendable, Equatable {
    public let revision: Int
    public let data: Data
}

public struct PendingEncryptedMessage: Sendable {
    public let sender: String
    public let digest: String
    public let wire: Data
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
}

/// One row of the durable update outbox: every outgoing stanza that is not a chat message.
/// The sealed wire is the exact bytes (or prepared envelope) that may ever be sent under this ID.
public struct StoredUpdate: Sendable, Equatable {
    /// `receipt` is a XEP-0184 `<received/>`, `marker` a XEP-0333 `<displayed/>`; both name a peer message.
    public enum Kind: String, Sendable { case reaction, keyTransport, receipt, marker }
    public let id: String
    public let accountID: String
    public let kind: Kind
    public let chatID: String
    public var transportState: OutgoingTransportState?
    public var targetMessageID: String? = nil
    public var targetWireID: String? = nil
}

/// Per-account switches. Receipt switches gate both what we ask for and what we send back.
public struct AccountPreferences: Sendable, Equatable {
    public var notificationPreviews = true
    public var deliveryReceipts = true
    public var readReceipts = true
    public init(notificationPreviews: Bool = true, deliveryReceipts: Bool = true, readReceipts: Bool = true) {
        self.notificationPreviews = notificationPreviews; self.deliveryReceipts = deliveryReceipts; self.readReceipts = readReceipts
    }
}

public struct UpdateSubmission: Sendable, Equatable {
    public let update: StoredUpdate
    public let wire: Data
    public let attemptID: String
}
