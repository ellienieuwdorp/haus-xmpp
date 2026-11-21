import Foundation

extension MessageStore {
    /// `markChatRead` for each chat, with nothing else running on the store in between. Returns the chats whose pointer
    /// moved, in the order given; each one's read state is then pending publication, as a single chat's is.
    @discardableResult public func markChatsRead(accountID: String, chatIDs: [String]) throws -> [String] {
        try chatIDs.filter { try markChatRead(accountID: accountID, chatID: $0) }
    }
}
