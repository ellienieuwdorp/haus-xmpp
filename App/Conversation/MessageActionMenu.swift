import Foundation

/// One thing a message can do, with what doing it means on this platform.
struct MessageAction: Identifiable {
    enum Kind: String {
        case reply, copy, selectText, star, retry, edit, unsend, encryptionDetails

        /// Choosing it presents nothing and focuses nothing, so the composer may take back the focus it had before the
        /// menu. Reply and edit focus the composer themselves; text selection and the unsend dialog must keep it away.
        var returnsFocusToComposer: Bool {
            switch self {
            case .copy, .star, .retry: true
            case .reply, .edit, .selectText, .unsend, .encryptionDetails: false
            }
        }
    }
    let kind: Kind
    let title: String
    let symbol: String
    let perform: () -> Void
    var id: Kind { kind }

    init(kind: Kind, title: String, symbol: String, perform: @escaping () -> Void) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.perform = perform
    }

    init(_ item: MessageActionMenu.Item, perform: @escaping () -> Void) {
        self.init(kind: item.kind, title: item.title, symbol: item.symbol, perform: perform)
    }
}

/// Which actions a message offers and in which order. The long-press menu and VoiceOver read the same list, and a
/// Mac context menu reads it too; each platform only attaches what performing an action does.
enum MessageActionMenu {
    struct Item: Equatable, Sendable {
        let kind: MessageAction.Kind
        let title: String
        /// An SF Symbol name.
        let symbol: String
    }

    static func items(for message: TimelineMessage) -> [Item] {
        // A placeholder is a notice, not content: nothing to quote, copy, star or select; only why it is unreadable.
        if message.unreadable != nil {
            return [Item(kind: .encryptionDetails, title: "Encryption details", symbol: "lock.shield")]
        }
        let star = Item(kind: .star, title: message.isStarred ? "Unstar message" : "Star message", symbol: message.isStarred ? "star.slash" : "star")
        // An unsent bubble has no text to quote, copy or select.
        if message.isRetracted { return [star] }
        var items = [
            Item(kind: .reply, title: "Reply", symbol: "arrowshape.turn.up.left"),
            Item(kind: .copy, title: "Copy", symbol: "doc.on.doc"),
            star,
            Item(kind: .selectText, title: "Select text", symbol: "text.cursor"),
        ]
        if message.isOutgoing, message.status?.canRetry == true {
            items.append(Item(kind: .retry, title: "Retry message", symbol: "arrow.clockwise"))
        }
        if message.canEdit { items.append(Item(kind: .edit, title: "Edit", symbol: "pencil")) }
        if message.canUnsend { items.append(Item(kind: .unsend, title: "Unsend", symbol: "trash")) }
        return items
    }

    /// What a tap on the message's file does, when anything: open it once it is on disk, or fetch it when it waits for
    /// a tap or failed.
    enum AttachmentAction: Equatable {
        case open(URL)
        case download
    }

    static func attachmentAction(for message: TimelineMessage) -> (title: String, action: AttachmentAction)? {
        guard let attachment = message.attachment else { return nil }
        if let url = attachment.localURL { return ("Open \(attachment.kindLabel.lowercased())", .open(url)) }
        guard !message.showsPlaceholder, attachment.download.canRequest else { return nil }
        return ("Download \(attachment.kindLabel.lowercased())", .download)
    }

    /// One toggle per quick reaction, for assistive technologies; the visible menu shows them as a row of emoji.
    static func reactionToggles(for message: TimelineMessage) -> [(emoji: String, title: String)] {
        guard message.canReact else { return [] }
        let selected = Set(message.reactions.filter(\.isSelected).map(\.emoji))
        return TimelineReaction.choices.map { ($0, reactionTitle($0, selected: selected.contains($0))) }
    }

    static func reactionTitle(_ emoji: String, selected: Bool) -> String {
        "\(selected ? "Remove" : "Add") \(TimelineReaction.name(for: emoji)) reaction"
    }
}
