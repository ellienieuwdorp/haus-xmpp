import Foundation

public struct StoredMessage: Identifiable, Equatable, Sendable {
    /// Application-generated stable identity, unique within an account. Not an untrusted stanza ID.
    public let id: String
    public let accountID: String
    public let chatID: String
    public let senderID: String
    public let body: String
    public let reply: MessageReply?
    public let sentAt: Date
    public let isOutgoing: Bool
    public var isStarred: Bool
    public var transportState: OutgoingTransportState?

    public init(id: String, accountID: String, chatID: String, senderID: String, body: String,
                sentAt: Date = Date(), isOutgoing: Bool = false, isStarred: Bool = false,
                transportState: OutgoingTransportState? = nil, reply: MessageReply? = nil) {
        self.id = id
        self.accountID = accountID
        self.chatID = chatID
        self.senderID = senderID
        self.body = body
        self.reply = reply
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
}

/// Local transport progress only. None of these states proves receipt by a server or peer.
public enum OutgoingTransportState: String, Equatable, Sendable {
    case queued, submitting, unconfirmed, failed
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
