import MessageStore
import SwiftUI

// The sidebar's right-click menu and the Chat menu both list these through `MacChatActionsMenu`, so the two match.
struct MacChatActions {
    enum Action: Hashable {
        case markRead, togglePin, mute(MuteDuration), unmute, block, unblock, report
        // Shows the details and starts there, where the flow and its confirmations live.
        case contact(ContactRowRequest.Kind)
        case showDetails
    }

    let chat: ChatSummary
    let isGroup: Bool
    let isBlocked: Bool
    let canLink: Bool
    let isLinked: Bool
    let canBlock: Bool
    let perform: (Action) -> Void

    // Block and Report ask first: they set `blockRequest`, which the main window confirms.
    @MainActor init(chat: ChatSummary, model: AppModel, window: MacWindowState) {
        self.chat = chat
        isGroup = model.isGroup(chat.id)
        isBlocked = model.isBlocked(chat.id)
        canLink = !isGroup && chat.id != model.accountID
        isLinked = model.contactLinks.links[chat.id] != nil
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
            case .contact(let kind):
                window.selection = chat.id
                window.inspectorShown = true
                model.contactLinks.request = ContactRowRequest(chatID: chat.id, kind: kind)
            }
        }
    }
}

// The right-click menu leaves out what does not apply, as menus over an item do; the menu bar keeps every item in
// place, disabled. Shortcuts belong to the menu bar only.
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
        if menuBar || actions?.canLink == true {
            Divider()
            contactItems
        }
        if menuBar || actions?.isGroup == false {
            Divider()
            blockItems
        }
        if !menuBar {
            Divider()
            Button("Chat Details", systemImage: "info.circle") { actions?.perform(.showDetails) }
        }
    }

    @ViewBuilder private var contactItems: some View {
        let available = actions?.canLink ?? false
        if actions?.isLinked == true {
            Button("Unlink Contact…", systemImage: "person.crop.circle.badge.minus") { actions?.perform(.contact(.unlink)) }
                .disabled(!available)
        } else {
            Button("Link to Contact…", systemImage: "person.crop.circle.badge.plus") { actions?.perform(.contact(.link)) }
                .disabled(!available)
            Button("Add to Contacts…", systemImage: "person.badge.plus") { actions?.perform(.contact(.add)) }
                .disabled(!available)
        }
    }

    @ViewBuilder private var blockItems: some View {
        let available = actions.map { $0.canBlock && !$0.isGroup } ?? false
        if actions?.isBlocked == true {
            Button("Unblock", systemImage: "hand.raised.slash") { actions?.perform(.unblock) }
                .disabled(!available)
        } else {
            Button("Block…", systemImage: "hand.raised") { actions?.perform(.block) }
                .disabled(!available)
        }
        // A blocked chat's report was made (or is moot) when it was blocked.
        if menuBar || actions?.isBlocked == false {
            Button("Report…", systemImage: "exclamationmark.bubble") { actions?.perform(.report) }
                .disabled(!available || actions?.isBlocked == true)
        }
    }
}

extension View {
    // The shortcut acts on the selected chat, not the one right-clicked, so context menus show none.
    @ViewBuilder func menuShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command, if applies: Bool = true) -> some View {
        if applies { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}
