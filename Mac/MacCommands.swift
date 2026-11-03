import AppKit
import SwiftUI

// The Chat and Message menus act on the main window only while it is key and shows its chats (not during a transfer,
// upgrade or key recovery); the open chat's commands come from `MacMenuTargets` or a focused scene value.
@MainActor struct MacCommands: Commands {
    let model: AppModel
    let window: MacWindowState
    @FocusedValue(\.conversationFind) private var focusedConversation: MacConversationFindCommands?
    @FocusedValue(\.macMessageCommands) private var focusedMessageCommands: MacMessageCommands?

    // An unobtrusive run's window is never key, so there it always counts.
    private var actsOnMainWindow: Bool {
        guard !model.showsBlockingScreen else { return false }
        #if DEBUG
        if MacUnobtrusive.isOn { return true }
        #endif
        return window.isKey
    }

    private var conversation: MacConversationFindCommands? {
        focusedConversation ?? (actsOnMainWindow ? MacMenuTargets.shared.conversationFind.last?.make() : nil)
    }

    private var chatCommands: MacChatCommands? {
        actsOnMainWindow ? MacChatCommands(model: model, window: window) : nil
    }

    private var messageCommands: MacMessageCommands? {
        focusedMessageCommands ?? (actsOnMainWindow ? MacMenuTargets.shared.messageCommands.last?.make() : nil)
    }

    var body: some Commands {
        let conversation = conversation
        CommandGroup(replacing: .appInfo) {
            Button("About Haus XMPP") { MacAboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                showMainWindow()
                window.showingNewChat = true
            }
            .keyboardShortcut("n")
            .disabled(model.showsBlockingScreen)
        }
        // As in Mail: ⌘F searches what is open, ⌥⌘F the list beside it.
        CommandGroup(after: .textEditing) {
            Button("Find in Conversation…") { conversation?.find() }
                .keyboardShortcut("f")
                .disabled(conversation == nil)
            Button("Find Chat…") {
                showMainWindow()
                window.searchRequests += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(model.showsBlockingScreen)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Starred Messages", isOn: Binding(get: { conversation?.starredOnly ?? false },
                                                     set: { conversation?.setStarredOnly($0) }))
                .disabled(conversation == nil)
        }
        ImportFromDevicesCommands()
        // Listed by name, as Messages and Mail list theirs, so it reopens the window after it was closed.
        CommandGroup(before: .windowList) {
            Button("Haus XMPP") { showMainWindow() }
                .keyboardShortcut("0")
        }
        CommandMenu("Chat") { MacChatMenu(commands: chatCommands) }
        CommandMenu("Message") { MacMessageMenuCommands(commands: messageCommands) }
        // The app has no help book; Help offers the support site and mail instead of "Help isn't available".
        CommandGroup(replacing: .help) {
            Button("Haus XMPP Support") { NSWorkspace.shared.open(AppInfo.support) }
            Button("Contact Support…") { NSWorkspace.shared.open(AppInfo.supportMail) }
        }
    }

    private func showMainWindow() {
        window.showMainWindow()
    }
}

struct MacChatCommands {
    let selected: MacChatActions?
    let detailsShown: Bool
    let chats: [(id: String, title: String)]
    let selection: String?
    let select: (String) -> Void
    let toggleDetails: () -> Void

    @MainActor init(model: AppModel, window: MacWindowState) {
        let ordered = ChatListOrder.sorted(model.chats)
        selected = window.selection.flatMap { id in ordered.first { $0.id == id } }.map { MacChatActions(chat: $0, model: model, window: window) }
        detailsShown = window.inspectorShown
        chats = ordered.map { ($0.id, $0.displayTitle) }
        selection = window.selection
        select = { window.selection = $0 }
        toggleDetails = { window.inspectorShown.toggle() }
    }

    func neighbour(forward: Bool) -> String? { ChatListOrder.neighbour(of: selection, in: chats.map(\.id), forward: forward) }
}

struct MacMessageCommands {
    let targets: LastMessageTargets
    let isFocused: Bool
    // A blocked chat has no composer and sends nothing, so it neither replies, edits nor reacts.
    let isBlocked: Bool
    let handlers: MacMessageHandlers

    var reply: TimelineMessage? { isBlocked ? nil : targets.reply }
    var edit: TimelineMessage? { isBlocked ? nil : targets.edit }
    var react: TimelineMessage? { isBlocked ? nil : targets.react }
    var star: TimelineMessage? { targets.star }
}

extension FocusedValues {
    @Entry var macMessageCommands: MacMessageCommands?
}

// The main window's content is hosted in AppKit views, where a focused scene value need not reach the menu bar, so the
// commands read these too. SwiftUI may build a view twice and drop the copies in any order; the newest left counts.
@Observable @MainActor final class MacMenuTargets {
    static let shared = MacMenuTargets()

    var conversationFind: [(token: UUID, make: () -> MacConversationFindCommands)] = []
    var messageCommands: [(token: UUID, make: () -> MacMessageCommands)] = []
}

// ⌃⇥ and ⌃⇧⇥ step through chats as they step through tabs elsewhere on the Mac; Details is ⌥⌘I, as ⌘I is italic.
struct MacChatMenu: View {
    let commands: MacChatCommands?

    var body: some View {
        MacChatActionsMenu(actions: commands?.selected, placement: .menuBar)
        Divider()
        Button(commands?.detailsShown == true ? "Hide Chat Details" : "Show Chat Details", systemImage: "info.circle") { commands?.toggleDetails() }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(commands?.selected == nil)
        Divider()
        Button("Next Chat") { if let next = commands?.neighbour(forward: true) { commands?.select(next) } }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled((commands?.chats.count ?? 0) < (commands?.selection == nil ? 1 : 2))
        Button("Previous Chat") { if let previous = commands?.neighbour(forward: false) { commands?.select(previous) } }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled((commands?.chats.count ?? 0) < (commands?.selection == nil ? 1 : 2))
        if let chats = commands?.chats, !chats.isEmpty {
            Divider()
            ForEach(Array(chats.prefix(9).enumerated()), id: \.element.id) { index, chat in
                Button(chat.title) { commands?.select(chat.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
    }
}

// ⌘R replies, as in Mail; ⇧⌘E edits, as ⌘E is Use Selection for Find.
struct MacMessageMenuCommands: View {
    let commands: MacMessageCommands?

    var body: some View {
        let focused = commands?.isFocused == true
        Button(focused ? "Reply" : "Reply to Last Message", systemImage: "arrowshape.turn.up.left") { act(.reply, on: commands?.reply) }
            .keyboardShortcut("r")
            .disabled(commands?.reply == nil)
        Button(focused ? "Edit" : "Edit Last Message", systemImage: "pencil") { act(.edit, on: commands?.edit) }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(commands?.edit == nil)
        // `.disabled` on a Menu does not reach its menu bar item, so without a target it is a plain disabled item.
        if let message = commands?.react {
            Menu(focused ? "React" : "React to Last Message", systemImage: "face.smiling") {
                ForEach(MacMessageMenu(message: message).reactions, id: \.emoji) { reaction in
                    Toggle(isOn: Binding(get: { reaction.isSelected }, set: { _ in commands?.handlers.react(reaction.emoji, message) })) {
                        Text(Self.reactionLabel(reaction.emoji))
                    }
                    .accessibilityLabel(reaction.title)
                }
            }
        } else {
            Button(focused ? "React" : "React to Last Message", systemImage: "face.smiling") {}
                .disabled(true)
        }
        Divider()
        let starred = commands?.star?.isStarred == true
        Button((starred ? "Unstar" : "Star") + (focused ? "" : " Last Message"), systemImage: starred ? "star.slash" : "star") { act(.star, on: commands?.star) }
            .disabled(commands?.star == nil)
    }

    private func act(_ kind: MessageAction.Kind, on message: TimelineMessage?) {
        guard let commands, let message else { return }
        commands.handlers.perform(kind, message, nil)
    }

    static func reactionLabel(_ emoji: String) -> String {
        let name = TimelineReaction.name(for: emoji)
        return "\(emoji)  \(name.prefix(1).uppercased() + name.dropFirst())"
    }
}

enum MacAboutPanel {
    @MainActor static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let text = NSMutableAttributedString(string: AppInfo.warranty + "\n", attributes: base)
        let links = [("Source code", AppInfo.sourceCode), ("Privacy policy", AppInfo.privacyPolicy), ("Support", AppInfo.support)]
        for (index, link) in links.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " · ", attributes: base)) }
            var attributes = base
            attributes[.link] = link.1
            text.append(NSAttributedString(string: link.0, attributes: attributes))
        }
        return text
    }
}
