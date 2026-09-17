import Foundation

/// A local, authenticated projection. Never serialize this into gateway traffic or logs.
public struct MessageNotification: Sendable, Equatable, CustomStringConvertible {
    public let latest: StoredMessage?
    public let chatTitle: String?
    /// The chat's verified avatar hash, for the extension to find the cached file.
    public let chatAvatarHash: String?
    public let messageCount: Int
    public let conversationCount: Int
    public let previewsEnabled: Bool
    public init(latest: StoredMessage?, chatTitle: String?, chatAvatarHash: String? = nil, messageCount: Int, conversationCount: Int, previewsEnabled: Bool) {
        self.latest = latest; self.chatTitle = chatTitle; self.chatAvatarHash = chatAvatarHash; self.messageCount = messageCount
        self.conversationCount = conversationCount; self.previewsEnabled = previewsEnabled
    }
    public var description: String { "MessageNotification(<redacted>)" }
}
