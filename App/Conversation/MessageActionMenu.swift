import Foundation
import XMPPProtocol

/// One thing a message can do, with what doing it means on this platform.
struct MessageAction: Identifiable {
    enum Kind: String {
        case reply, copy, selectText, star, retry, edit, unsend, encryptionDetails
        /// The pressed link's actions, above the message's own: open it (call, for a phone number), message the
        /// number, copy it, share it.
        case openLink, messageNumber, copyLink, shareLink

        /// Choosing it presents nothing and focuses nothing, so the composer may take back the focus it had before the
        /// menu. Reply and edit focus the composer themselves; text selection and the unsend dialog must keep it away,
        /// and so must anything that opens a link or a share sheet.
        var returnsFocusToComposer: Bool {
            switch self {
            case .copy, .star, .retry, .copyLink: true
            case .reply, .edit, .selectText, .unsend, .encryptionDetails, .openLink, .messageNumber, .shareLink: false
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

    /// `link` is the link a long press landed on (in the text or on the preview card); its actions come first.
    static func items(for message: TimelineMessage, link: URL? = nil) -> [Item] {
        let own = messageItems(for: message)
        guard let link, !message.showsPlaceholder else { return own }
        return linkItems(for: link) + own
    }

    /// What a long press on `url` adds at the top of the message menu.
    static func linkItems(for url: URL) -> [Item] {
        switch LinkOpening.destination(for: url, inAppBrowser: false) {
        case .phone:
            [Item(kind: .openLink, title: "Call", symbol: "phone"),
             Item(kind: .messageNumber, title: "Send message", symbol: "message"),
             Item(kind: .copyLink, title: "Copy number", symbol: "number")]
        case .mail:
            [Item(kind: .openLink, title: "New mail", symbol: "envelope"),
             Item(kind: .copyLink, title: "Copy email address", symbol: "at"),
             Item(kind: .shareLink, title: "Share link", symbol: "square.and.arrow.up")]
        case .chat, .group:
            [Item(kind: .openLink, title: "Open chat", symbol: "bubble.left.and.bubble.right"),
             Item(kind: .copyLink, title: "Copy address", symbol: "at"),
             Item(kind: .shareLink, title: "Share link", symbol: "square.and.arrow.up")]
        case .map:
            [Item(kind: .openLink, title: "Open in Maps", symbol: "map"),
             Item(kind: .copyLink, title: "Copy link", symbol: "link"),
             Item(kind: .shareLink, title: "Share link", symbol: "square.and.arrow.up")]
        case .unsupported:
            [Item(kind: .copyLink, title: "Copy link", symbol: "link")]
        case .web:
            [Item(kind: .openLink, title: "Open link", symbol: "safari"),
             Item(kind: .copyLink, title: "Copy link", symbol: "link"),
             Item(kind: .shareLink, title: "Share link", symbol: "square.and.arrow.up")]
        }
    }

    /// The VoiceOver action that opens one link in the text, named after what it does and the link as written.
    static func linkAccessibilityTitle(for link: DetectedLink) -> String {
        switch link.kind {
        case .web: "Open link \(link.text)"
        case .phone: "Call \(link.text)"
        case .mail: "Email \(link.text)"
        case .xmpp: "Open chat \(link.text)"
        case .geo: "Open \(link.text) in Maps"
        }
    }

    private static func messageItems(for message: TimelineMessage) -> [Item] {
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
