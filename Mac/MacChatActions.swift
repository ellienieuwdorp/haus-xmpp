import SwiftUI

/// One chat's actions: the iPhone's trailing swipe actions (Read, Pin, Mute) and its details' Block, Report and Unblock.
/// The sidebar's right-click menu offers them for any chat and the Chat menu for the selected one, both through
/// `MacChatActionsMenu`, so the two list the same things in the same order.
struct MacChatActions {
    enum Action: Hashable {
        case markRead, togglePin, mute(MuteDuration), unmute, block, unblock, report
        /// Selects the chat and shows its details.
        case showDetails
    }

    let chat: ChatSummary
    let isGroup: Bool
    let isBlocked: Bool
    /// The server blocks; without it Block, Report and Unblock are disabled.
    let canBlock: Bool
    let perform: (Action) -> Void

    /// Block and Report ask first: they set the window's `blockRequest`, which the main window confirms.
    @MainActor init(chat: ChatSummary, model: AppModel, window: MacWindowState) {
        self.chat = chat
        isGroup = model.isGroup(chat.id)
        isBlocked = model.isBlocked(chat.id)
        canBlock = model.blockingAvailability.isAvailable
        perform = { action in
            switch action {
            case .markRead: Task { await model.markChatRead(chat.id) }
            case .togglePin: Task { await model.togglePin(chat) }
            case .mute(let duration): Task { await model.muteChat(chat.id, for: duration) }
            case .unmute: Task { await model.unmuteChat(chat.id) }
            case .block: window.blockRequest = BlockRequest(kind: .block, chatID: chat.id, name: chat.displayTitle)
            case .report: window.blockRequest = BlockRequest(kind: .report, chatID: chat.id, name: chat.displayTitle)
            case .unblock: Task { for entry in model.blockEntries(for: chat.id) { await model.unblock(entry) } }
            case .showDetails:
                window.selection = chat.id
                window.inspectorShown = true
            }
        }
    }
}

/// `MacChatActions` as menu items. The right-click menu leaves out what does not apply to its chat, as menus over an
/// item do; the menu bar keeps every item in its place and disables what does not apply, and with no chat selected
/// (`actions` nil) disables them all. Shortcuts belong to the menu bar only.
struct MacChatActionsMenu: View {
    enum Placement { case contextMenu, menuBar }

    let actions: MacChatActions?
    let placement: Placement

    private var menuBar: Bool { placement == .menuBar }

    var body: some View {
        let chat = actions?.chat
        let unread = (chat?.unreadCount ?? 0) > 0
        if menuBar || unread {
            Button("Mark as Read", systemImage: "envelope.open") { actions?.perform(.markRead) }
                .menuShortcut("u", modifiers: [.command, .shift], if: menuBar)
                .disabled(!unread)
        }
        Button(chat?.isPinned == true ? "Unpin" : "Pin", systemImage: chat?.isPinned == true ? "pin.slash" : "pin") { actions?.perform(.togglePin) }
            .disabled(actions == nil)
        if chat?.notification.isMuted() == true {
            Button("Unmute", systemImage: "bell") { actions?.perform(.unmute) }
        } else {
            // The durations the iPhone offers in its dialog; nothing changes until one is picked.
            Menu("Mute", systemImage: "bell.slash") {
                ForEach(MuteDuration.allCases) { duration in
                    Button(duration.dialogTitle) { actions?.perform(.mute(duration)) }
                }
            }
            .disabled(actions == nil)
        }
        // A group has no one to block; the menu bar keeps the items, disabled.
        if menuBar || actions?.isGroup == false {
            Divider()
            blockItems
        }
        if !menuBar {
            Divider()
            Button("Chat Details", systemImage: "info.circle") { actions?.perform(.showDetails) }
        }
    }

    /// The details' Block, Report and Unblock; disabled without a server that blocks.
    @ViewBuilder private var blockItems: some View {
        let available = actions.map { $0.canBlock && !$0.isGroup } ?? false
        if actions?.isBlocked == true {
            Button("Unblock", systemImage: "hand.raised.slash") { actions?.perform(.unblock) }
                .disabled(!available)
        } else {
            Button("Block…", systemImage: "hand.raised") { actions?.perform(.block) }
                .disabled(!available)
        }
        // A blocked chat's report was made (or is moot) when it was blocked; the menu bar keeps the item, disabled.
        if menuBar || actions?.isBlocked == false {
            Button("Report…", systemImage: "exclamationmark.bubble") { actions?.perform(.report) }
                .disabled(!available || actions?.isBlocked == true)
        }
    }
}

extension View {
    /// A keyboard shortcut in the menu bar; a right-click menu shows none, as the shortcut acts on the selected chat and
    /// not on the one clicked.
    @ViewBuilder func menuShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command, if applies: Bool = true) -> some View {
        if applies { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}
