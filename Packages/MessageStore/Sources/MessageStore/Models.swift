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
}

/// One row of the durable update outbox: every outgoing stanza that is not a chat message.
/// The sealed wire is the exact bytes (or prepared envelope) that may ever be sent under this ID.
public struct StoredUpdate: Sendable, Equatable {
    public enum Kind: String, Sendable { case reaction, keyTransport }
    public let id: String
    public let accountID: String
    public let kind: Kind
    public let chatID: String
    public var transportState: OutgoingTransportState?
}

public struct UpdateSubmission: Sendable, Equatable {
    public let update: StoredUpdate
    public let wire: Data
    public let attemptID: String
}
