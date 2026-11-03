import AppKit

enum MacTimelineKey: Equatable {
    case scroll(MacTimelineController.KeyScroll)
    case focus(forward: Bool)
    case escape
}

// What a click on a bubble does that its menu does not list, for a menu the keyboard opened.
@MainActor enum MacKeyboardMenuItems {
    static func add(to menu: NSMenu, message: TimelineMessage, openAttachment: @escaping () -> Void, openLink: @escaping (URL) -> Void,
                    showQuote: (() -> Void)?) {
        var items: [NSMenuItem] = []
        if let attachment = MessageActionMenu.attachmentAction(for: message) {
            items.append(MacMenuAction.item(attachment.title.capitalized, symbol: "eye", run: openAttachment))
        }
        for link in message.links {
            items.append(MacMenuAction.item(MessageActionMenu.linkAccessibilityTitle(for: link), symbol: "link") { openLink(link.url) })
        }
        if let showQuote { items.append(MacMenuAction.item(MacKeyboardMenuItems.showQuoteTitle, symbol: "text.quote", run: showQuote)) }
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }

    static let showQuoteTitle = "Show Quoted Message"

    #if DEBUG
    static func titles(of menu: NSMenu) -> String {
        menu.items.map { item in
            if item.isSeparatorItem { return "|" }
            if let palette = item.submenu, palette.presentationStyle == .palette { return "[\(palette.items.count) reactions]" }
            return item.title + (item.isEnabled ? "" : " (off)")
        }
        .joined(separator: " ")
    }
    #endif
}

extension TimelineMessage {
    func senderName(contactName: String?) -> String? {
        author.map { ContactName.display(for: $0, title: nil) } ?? contactName
    }
}
