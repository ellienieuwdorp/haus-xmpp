import Foundation

/// The chat list's order on every platform, and moving through it from the keyboard.
enum ChatListOrder {
    /// Pinned first, then newest activity; ties keep the store's order.
    static func sorted(_ chats: [ChatSummary]) -> [ChatSummary] {
        chats.enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }
            let da = a.element.lastMessageAt ?? .distantPast, db = b.element.lastMessageAt ?? .distantPast
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }

    /// The chat after `selection` in `ids` (before it, backwards), wrapping around at either end. With nothing selected,
    /// or a selection no longer listed, the first chat (the last, backwards); nil for an empty list.
    static func neighbour(of selection: String?, in ids: [String], forward: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selection, let index = ids.firstIndex(of: selection) else { return forward ? ids.first : ids.last }
        return ids[(index + (forward ? 1 : ids.count - 1)) % ids.count]
    }
}
