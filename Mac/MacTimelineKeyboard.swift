import AppKit

/// A key that a bubble's text passes on to the timeline instead of handling it (`BubbleTextView`).
enum MacTimelineKey: Equatable {
    case scroll(MacTimelineController.KeyScroll)
    /// Up (false) or Down (true): keyboard focus goes back to the timeline and on to the next message.
    case focus(forward: Bool)
    case escape
}

/// What a click on a bubble does that its menu does not list, added for a menu the keyboard opened: open or download
/// its file, open each link (a preview card opens one of them), show the quoted message.
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
    /// The menu's items as a tour logs them: the reaction palette, then each item, with separators as `|`.
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
    /// Who sent a received message, by name: the group member, or in a direct chat the contact.
    func senderName(contactName: String?) -> String? {
        author.map { ContactName.display(for: $0, title: nil) } ?? contactName
    }
}
