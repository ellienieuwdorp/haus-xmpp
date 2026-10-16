import AppKit
import SwiftUI

/// A key that a bubble's text passes on to the timeline instead of handling it (`BubbleTextView`).
enum MacTimelineKey: Equatable {
    case scroll(MacTimelineController.KeyScroll)
    /// Up (false) or Down (true): keyboard focus goes back to the timeline and on to the next message.
    case focus(forward: Bool)
    case escape
    /// The text left the window with keyboard focus: the timeline takes it back.
    case refocus
}

/// One message row's link to its timeline, for what the bubble does for the keyboard and VoiceOver: the focus ring,
/// the menu Return opens, the keys its text passes on, and its place in the timeline's rotors. Equal for the same row
/// of the same timeline, so setting it on each update invalidates nothing.
struct MacTimelineRowContext: Equatable {
    weak var timeline: MacTimelineController?
    var id = ""
    /// The namespace of the timeline's rotors (`MacTimelineRotors`).
    var rotors: Namespace.ID?

    static func == (left: Self, right: Self) -> Bool {
        left.timeline === right.timeline && left.id == right.id && left.rotors == right.rotors
    }
}

extension EnvironmentValues {
    @Entry var timelineRow = MacTimelineRowContext()
}

/// The system's keyboard focus ring around the focused message's bubble, while the timeline has keyboard focus.
struct MacMessageFocusRing: View {
    let cornerRadius: CGFloat
    @Environment(\.timelineRow) private var context

    var body: some View {
        if let timeline = context.timeline, timeline.hasKeyboardFocus, timeline.focusedID == context.id {
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                .padding(-3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Behind the focused bubble only: opens its menu below it when the keyboard asks for it
/// (`MacTimelineController.openMenu`). The menu is the bubble's own (`MacMessageNSMenu`), followed by what a click on
/// the bubble does, which a keyboard cannot otherwise reach (`MacKeyboardMenuItems`).
struct MacMessageKeyboardMenu: View {
    /// The menu, built when it opens.
    let menu: () -> NSMenu
    @Environment(\.timelineRow) private var context

    var body: some View {
        if let timeline = context.timeline, timeline.focusedID == context.id {
            MacMessageKeyboardMenuAnchor(timeline: timeline, id: context.id, menu: menu)
        }
    }
}

/// The view the focused bubble's menu opens from. Also on appearing: focusing a message and asking for its menu
/// happen together.
private struct MacMessageKeyboardMenuAnchor: View {
    let timeline: MacTimelineController
    let id: String
    let menu: () -> NSMenu
    @State private var anchor = MacMenuAnchor.Box()

    var body: some View {
        MacMenuAnchor(box: anchor)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: timeline.pendingMenu, initial: true) { _, pending in
                guard pending == id else { return }
                timeline.menuOpened()
                // Not inside the update, and once the anchor is in its window: the menu runs its own event loop.
                DispatchQueue.main.async { open() }
            }
    }

    private func open() {
        guard let view = anchor.view, view.window != nil else { return }
        let menu = menu()
        #if DEBUG
        // A menu runs its own event loop, which nothing ends in a scripted run: the tour reads it instead.
        if MacUnobtrusive.isOn {
            MacDebugHooks.log("keyboard menu \(id): " + MacKeyboardMenuItems.titles(of: menu))
            return
        }
        #endif
        // Below the bubble's leading corner, as a menu opened from a control hangs below it.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }
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

/// VoiceOver's rotors over the open chat: every message, the links in them, and the starred messages. Each entry is
/// a message's row (`accessibilityRotorEntry` there), scrolled into view before VoiceOver moves to it, so rows the
/// lazy stack has not built yet are reachable too.
struct MacTimelineRotors: ViewModifier {
    let controller: MacTimelineController
    /// The contact's name in a direct chat (`TimelineMessage.senderName`).
    let contactName: String?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        // Read from the observed `items`, so a new, edited or starred message or a page of history updates the rotors.
        let messages = controller.items.compactMap { item -> TimelineMessage? in
            guard case .message(let row) = item else { return nil }
            return row.message
        }
        let links = Self.links(in: messages)
        return content
            .accessibilityRotor("Messages") {
                ForEach(messages) { message in entry(Self.label(for: message, contactName: contactName), message) }
            }
            .accessibilityRotor(.links) {
                ForEach(links) { link in entry(link.title, link.message) }
            }
            .accessibilityRotor("Starred Messages") {
                ForEach(messages.filter(\.isStarred)) { message in entry(Self.label(for: message, contactName: contactName), message) }
            }
    }

    private struct Link: Identifiable {
        let id: Int
        let title: String
        let message: TimelineMessage
    }

    /// Every link in the messages, oldest first, titled as the row's actions title them.
    private static func links(in messages: [TimelineMessage]) -> [Link] {
        messages.flatMap { message in message.links.map { (MessageActionMenu.linkAccessibilityTitle(for: $0), message) } }
            .enumerated().map { Link(id: $0.offset, title: $0.element.0, message: $0.element.1) }
    }

    private func entry(_ label: String, _ message: TimelineMessage) -> AccessibilityRotorEntry<String> {
        AccessibilityRotorEntry(Text(label), id: message.id, in: namespace) { [controller] in controller.reveal(message.id) }
    }

    /// Who and what, then the time: the start of what the row itself reads, short enough for the rotor's list.
    static func label(for message: TimelineMessage, contactName: String?) -> String {
        let speaker = message.isOutgoing ? "You" : message.senderName(contactName: contactName) ?? "Contact"
        let content = message.displayedText.isEmpty ? message.attachment.map { "\($0.kindLabel) \($0.name)" } ?? "" : message.displayedText
        let time = message.sentAt?.formatted(date: .omitted, time: .shortened)
        return [content.isEmpty ? speaker : "\(speaker): \(content)", time].compactMap { $0 }.joined(separator: ", ")
    }
}

extension TimelineMessage {
    /// Who sent a received message, by name: the group member, or in a direct chat the contact.
    func senderName(contactName: String?) -> String? {
        author.map { ContactName.display(for: $0, title: nil) } ?? contactName
    }
}
