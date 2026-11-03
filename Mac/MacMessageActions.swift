import AppKit
import SwiftUI

// The row keeps what stays inside it (Select Text, the emoji picker) and passes the rest here.
struct MacMessageHandlers {
    // `link` is the link the menu was opened on, for its own items.
    let perform: (MessageAction.Kind, TimelineMessage, URL?) -> Void
    // Takes the reaction back when it is already the user's.
    let react: (String, TimelineMessage) -> Void
}

// The right-click menus (SwiftUI over the bubble, AppKit over its text), the hover toolbar's More menu and VoiceOver
// actions all read this, so they list the same things in the same order.
struct MacMessageMenu {
    let message: TimelineMessage
    var link: URL? = nil

    var items: [MessageActionMenu.Item] { MessageActionMenu.items(for: message, link: link) }

    var attachment: MacAttachmentMenu? { MacAttachmentMenu(message: message) }

    var showsReactions: Bool { !message.showsPlaceholder }

    var reactions: [(emoji: String, title: String, isSelected: Bool)] {
        let selected = Set(message.reactions.filter(\.isSelected).map(\.emoji))
        return TimelineReaction.choices.map { ($0, MessageActionMenu.reactionTitle($0, selected: selected.contains($0)), selected.contains($0)) }
    }

    // The Mac's ellipsis on the titles that ask something before they act.
    static func title(for item: MessageActionMenu.Item) -> String {
        switch item.kind {
        case .retry, .unsend, .report: item.title + "…"
        default: item.title
        }
    }

    static let moreReactionsTitle = "More reactions"

    static func separatesLink(at index: Int, in items: [MessageActionMenu.Item]) -> Bool {
        func isLink(_ kind: MessageAction.Kind) -> Bool { [.openLink, .messageNumber, .copyLink, .shareLink].contains(kind) }
        return isLink(items[index].kind) && items.indices.contains(index + 1) && !isLink(items[index + 1].kind)
    }
}

struct MacMessageMenuContent: View {
    let menu: MacMessageMenu
    let perform: (MessageAction.Kind, URL?) -> Void
    let react: (String) -> Void
    let moreReactions: () -> Void

    var body: some View {
        if menu.showsReactions {
            // A palette: the six quick reactions in one row, as on the iPhone's pill, then "+" for any other emoji.
            ControlGroup {
                ForEach(menu.reactions, id: \.emoji) { reaction in
                    Toggle(isOn: Binding(get: { reaction.isSelected }, set: { _ in react(reaction.emoji) })) {
                        Label { Text(reaction.title) } icon: { Image(nsImage: MacEmojiImage.image(reaction.emoji)) }
                    }
                }
                Button(MacMessageMenu.moreReactionsTitle, systemImage: "plus", action: moreReactions)
            }
            .controlGroupStyle(.palette)
            .disabled(!menu.message.canReact)
            if let reason = menu.message.reactionUnavailableReason {
                Text(reason)
            }
            Divider()
        }
        let items = menu.items
        ForEach(Array(items.enumerated()), id: \.element.kind) { index, item in
            if item.kind == .shareLink, let link = menu.link {
                ShareLink(item: link) { Label(item.title, systemImage: item.symbol) }
            } else {
                Button(MacMessageMenu.title(for: item), systemImage: item.symbol) { perform(item.kind, menu.link) }
            }
            if MacMessageMenu.separatesLink(at: index, in: items) { Divider() }
        }
        if let attachment = menu.attachment {
            Divider()
            ForEach(attachment.items, id: \.kind) { item in
                Button(item.title, systemImage: item.symbol) { attachment.perform(item.kind) }
            }
        }
    }
}

// For a right-click on the bubble's text, where AppKit, not SwiftUI, handles the click and knows which link it hit.
@MainActor enum MacMessageNSMenu {
    static func make(_ menu: MacMessageMenu, perform: @escaping (MessageAction.Kind, URL?) -> Void, react: @escaping (String) -> Void,
                     moreReactions: @escaping () -> Void) -> NSMenu {
        let result = NSMenu()
        result.autoenablesItems = false
        if menu.showsReactions {
            let palette = NSMenu()
            palette.presentationStyle = .palette
            palette.autoenablesItems = false
            for reaction in menu.reactions {
                let item = ActionItem(reaction.title, image: MacEmojiImage.image(reaction.emoji)) { react(reaction.emoji) }
                item.state = reaction.isSelected ? .on : .off
                palette.addItem(item)
            }
            palette.addItem(ActionItem(MacMessageMenu.moreReactionsTitle, image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil), action: moreReactions))
            for item in palette.items { item.isEnabled = menu.message.canReact }
            let holder = NSMenuItem(title: "React", action: nil, keyEquivalent: "")
            holder.submenu = palette
            result.addItem(holder)
            if let reason = menu.message.reactionUnavailableReason {
                let line = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
                line.isEnabled = false
                result.addItem(line)
            }
            result.addItem(.separator())
        }
        let items = menu.items
        for (index, item) in items.enumerated() {
            if item.kind == .shareLink, let link = menu.link {
                let share = NSSharingServicePicker(items: [link]).standardShareMenuItem
                share.title = item.title
                result.addItem(share)
            } else {
                result.addItem(ActionItem(MacMessageMenu.title(for: item), image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)) {
                    perform(item.kind, menu.link)
                })
            }
            if MacMessageMenu.separatesLink(at: index, in: items) { result.addItem(.separator()) }
        }
        if let attachment = menu.attachment {
            result.addItem(.separator())
            for item in attachment.items {
                result.addItem(ActionItem(item.title, image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)) {
                    attachment.perform(item.kind)
                })
            }
        }
        return result
    }

    // Its own target; the menu keeps it alive.
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void

        init(_ title: String, image: NSImage?, action handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
            self.image = image
        }

        required init(coder: NSCoder) { fatalError("not used") }

        @objc private func fire() { handler() }
    }
}

// For the places that take an image, not text: palette items in a menu.
@MainActor enum MacEmojiImage {
    private static var cache: [String: NSImage] = [:]

    static func image(_ emoji: String) -> NSImage {
        if let image = cache[emoji] { return image }
        let side: CGFloat = 18
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let text = NSAttributedString(string: emoji, attributes: attributes)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        image.accessibilityDescription = TimelineReaction.name(for: emoji)
        cache[emoji] = image
        return image
    }
}
