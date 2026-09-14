import Foundation

/// A local, authenticated projection. Never serialize this into gateway traffic or logs.
public struct MessageNotification: Sendable, Equatable, CustomStringConvertible {
    public let latest: StoredMessage?
    public let chatTitle: String?
    public let messageCount: Int
    public let conversationCount: Int
    public let previewsEnabled: Bool
    public init(latest: StoredMessage?, chatTitle: String?, messageCount: Int, conversationCount: Int, previewsEnabled: Bool) {
        self.latest = latest; self.chatTitle = chatTitle; self.messageCount = messageCount
        self.conversationCount = conversationCount; self.previewsEnabled = previewsEnabled
    }
    public var description: String { "MessageNotification(<redacted>)" }
}
