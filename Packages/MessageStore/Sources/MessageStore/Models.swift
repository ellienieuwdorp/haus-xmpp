import Foundation

public struct StoredMessage: Identifiable, Equatable, Sendable {
    /// Application-generated stable identity, unique within an account. Not an untrusted stanza ID.
    public let id: String
    public let accountID: String
    public let chatID: String
    public let senderID: String
    public let body: String
    public let sentAt: Date
    public let isOutgoing: Bool
    public var isStarred: Bool

    public init(id: String, accountID: String, chatID: String, senderID: String, body: String,
                sentAt: Date = Date(), isOutgoing: Bool = false, isStarred: Bool = false) {
        self.id = id
        self.accountID = accountID
        self.chatID = chatID
        self.senderID = senderID
        self.body = body
        self.sentAt = sentAt
        self.isOutgoing = isOutgoing
        self.isStarred = isStarred
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
}
