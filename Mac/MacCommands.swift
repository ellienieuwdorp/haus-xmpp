import AppKit
import SwiftUI

/// Menu commands of the main window. Settings (⌘,) comes with the Settings scene. The Chat and Message menus act on the
/// main window while it is the key window: its chats from the model, the open chat's find and message commands from
/// what the conversation registers (`MacMenuTargets`), or publishes as a focused scene value. They are disabled while
/// another window is in front or the main window is closed.
@MainActor struct MacCommands: Commands {
    let model: AppModel
    let window: MacWindowState
    /// The open chat's search and starred filter; nil while no chat is shown.
    @FocusedValue(\.conversationFind) private var focusedConversation: MacConversationFindCommands?
    @FocusedValue(\.macMessageCommands) private var focusedMessageCommands: MacMessageCommands?

    /// The main window is in front. An unobtrusive run's window is never key, so there it always counts.
    private var actsOnMainWindow: Bool {
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
        }
        CommandGroup(after: .sidebar) {
            Toggle("Starred Messages", isOn: Binding(get: { conversation?.starredOnly ?? false },
                                                     set: { conversation?.setStarredOnly($0) }))
                .disabled(conversation == nil)
        }
        // File > Import from iPhone or iPad: Continuity Camera into the open chat's composer, as the attach menu offers.
        ImportFromDevicesCommands()
        // The main window by name, as Messages and Mail list theirs: it opens the window again after it was closed.
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

    /// The commands work with the main window closed too: they bring it back first.
    private func showMainWindow() {
        window.showMainWindow()
    }
}

/// The main window's chats, for the Chat menu: the selected chat's actions, and moving between chats.
struct MacChatCommands {
    /// The selected chat's actions; nil with no chat selected.
    let selected: MacChatActions?
    let detailsShown: Bool
    /// The sidebar's chats in its order (`ChatListOrder`).
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

/// The open conversation's message commands, for the Message menu: on the message with the timeline's keyboard focus,
/// else on the last messages. They act as the bubble's menu does on that message: reply and edit through the composer,
/// star and reactions through the conversation.
struct MacMessageCommands {
    let targets: LastMessageTargets
    /// The targets are the focused message, not the last ones; the items say so.
    let isFocused: Bool
    /// A blocked chat has no composer and sends nothing, so it neither replies, edits nor reacts.
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

/// The open chat's menu targets, registered by its views while they are shown. The main window's content is hosted in
/// AppKit views, where a focused scene value need not reach the menu bar's commands, so the commands read these too.
/// SwiftUI may build a view twice and take the copies down in any order; the newest one left counts.
@Observable @MainActor final class MacMenuTargets {
    static let shared = MacMenuTargets()

    var conversationFind: [(token: UUID, make: () -> MacConversationFindCommands?)] = []
    var messageCommands: [(token: UUID, make: () -> MacMessageCommands)] = []
}

/// The Chat menu: the selected chat's actions (`MacChatActionsMenu`, as in the sidebar's right-click menu), its details,
/// then moving between chats: ⌃⇥ and ⌃⇧⇥ step to the next and previous chat as they step through tabs elsewhere on the
/// Mac, and ⌘1 to ⌘9 go to the sidebar's first nine. Details is ⌥⌘I, as ⌘I is italic wherever text is edited.
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

/// The Message menu: the composer's and the bubble's actions on the message with the timeline's keyboard focus, else
/// on the conversation's last message (`LastMessageTargets`), each disabled when no loaded message offers it; the items
/// name the last message only when that is what they act on. ⌘R replies, as Mail's Reply does; ⇧⌘E edits, as plain ⌘E
/// is Use Selection for Find (Up-arrow in an empty composer edits too).
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

    /// "❤️ Heart": the emoji and its name, as a menu item reads best.
    static func reactionLabel(_ emoji: String) -> String {
        let name = TimelineReaction.name(for: emoji)
        return "\(emoji)  \(name.prefix(1).uppercased() + name.dropFirst())"
    }
}

/// The standard About panel (name, icon, version and the Info.plist copyright) with the licence notice and the
/// source, privacy and support links as its credits. The licence texts are in Settings > About.
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
