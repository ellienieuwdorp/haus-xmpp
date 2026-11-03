import Foundation

enum ChatListOrder {
    static func sorted(_ chats: [ChatSummary]) -> [ChatSummary] {
        chats.enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }
            let da = a.element.lastMessageAt ?? .distantPast, db = b.element.lastMessageAt ?? .distantPast
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }

    static func neighbour(of selection: String?, in ids: [String], forward: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selection, let index = ids.firstIndex(of: selection) else { return forward ? ids.first : ids.last }
        return ids[(index + (forward ? 1 : ids.count - 1)) % ids.count]
    }
}
