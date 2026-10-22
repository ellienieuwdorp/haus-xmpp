import SwiftUI

/// The sidebar: the account's chats with selection, filtered by the search field above them (`MacSidebarSearch`), the
/// own-device review card above them, and per-chat actions in a right-click menu. The iPhone's trailing swipe actions
/// (Read, Pin, Mute) are menu items here; a Mac list has no swipe actions.
struct MacChatList: View {
    @Bindable var model: AppModel
    @Bindable var window: MacWindowState
    /// Own devices the card was put off for with Later; a device not in here brings the card back.
    @State private var ownDevicesLater: Set<String> = []

    private var searchTerm: String { window.chatSearch.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The iPhone list's order.
    private var sortedChats: [ChatSummary] { ChatListOrder.sorted(model.chats) }

    private var visibleChats: [ChatSummary] {
        guard !searchTerm.isEmpty else { return sortedChats }
        return sortedChats.filter { $0.title.localizedCaseInsensitiveContains(searchTerm) || $0.id.localizedCaseInsensitiveContains(searchTerm) }
    }

    private var showsOwnDeviceReview: Bool {
        searchTerm.isEmpty && model.ownDeviceReview.contains { !ownDevicesLater.contains($0.id) }
    }

    /// A quiet line under sample chats (and, in DEBUG, lab chats).
    private var listCaption: String? {
        if model.isDemo { return "Sample conversations · stored on this Mac" }
        #if DEBUG
        if model.isLabAccount { return "Local development lab" }
        #endif
        return nil
    }

    var body: some View {
        List(selection: $window.selection) {
            // Account-level, so it sits above every chat: one decision here reaches all of them.
            if showsOwnDeviceReview {
                OwnDeviceReviewCard(candidates: model.ownDeviceReview,
                                    review: { window.reviewingOwnDevices = true },
                                    later: { withAnimation { ownDevicesLater.formUnion(model.ownDeviceReview.map(\.id)) } })
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 4)
            }
            ForEach(visibleChats) { chat in
                ChatRow(chat: chat, isGroup: model.isGroup(chat.id), avatar: model.avatars[chat.id], typing: model.typing[chat.id], avatarSize: 40,
                        isBlocked: model.isBlocked(chat.id))
                    .padding(.vertical, 4)
                    .tag(chat.id)
                    .task(id: "\(chat.id)|\(model.session.isReady)") { await model.loadAvatar(for: chat.id) }
                    .accessibilityValue([chat.isPinned ? "Pinned" : nil, chat.notification.isMuted() ? "Muted" : nil].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityIdentifier("chat.\(chat.id)")
                    .contextMenu { MacChatActionsMenu(actions: MacChatActions(chat: chat, model: model, window: window), placement: .contextMenu) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.chats.isEmpty {
                // As on the iPhone: quiet until storage has been read, so a signed-in launch never flashes "no chats".
                if model.hasLoadedChats {
                    ContentUnavailableView("No Chats", systemImage: "bubble.left.and.bubble.right")
                }
            } else if visibleChats.isEmpty {
                ContentUnavailableView.search(text: searchTerm)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let listCaption, !model.chats.isEmpty {
                Text(listCaption)
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }
}

/// New Chat (⌘N): an address field that filters the existing chats and, given a new address, starts a chat; and the
/// group join form. The iPhone's sheet, laid out for a Mac sheet.
struct MacNewChatSheet: View {
    @Bindable var model: AppModel
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var joiningGroup = false

    private var recipientTerm: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var suggestedChats: [ChatSummary] {
        let chats = model.chats.sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        guard !recipientTerm.isEmpty else { return chats }
        return chats.filter { $0.title.localizedCaseInsensitiveContains(recipientTerm) || $0.id.localizedCaseInsensitiveContains(recipientTerm) }
    }

    /// A typed address that is not already a chat can start one; createChat validates it.
    private var offersNewAddress: Bool {
        recipientTerm.contains("@") && !model.chats.contains { $0.id.caseInsensitiveCompare(recipientTerm) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name or address", text: $recipient)
                        .autocorrectionDisabled()
                        .onSubmit(startChat)
                        .accessibilityIdentifier("newChatAddress")
                    if offersNewAddress {
                        Button("Start Chat with \(recipientTerm)", systemImage: "plus.message", action: startChat)
                            .accessibilityIdentifier("startChat")
                    }
                    NavigationLink("Join a Group by Address") {
                        GroupJoinView(model: model) { room in open(room) }
                    }
                    .disabled(!model.session.isReady)
                    .accessibilityIdentifier("newGroup")
                }
                if !suggestedChats.isEmpty {
                    Section("Suggested") {
                        ForEach(suggestedChats) { chat in
                            Button { open(chat.id) } label: {
                                HStack(spacing: 10) {
                                    ChatAvatar(key: chat.id, name: chat.displayTitle, image: model.avatars[chat.id], isGroup: model.isGroup(chat.id), size: 28)
                                    VStack(alignment: .leading) {
                                        Text(chat.displayTitle)
                                        Text(chat.id).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 420, idealHeight: 520)
    }

    private func startChat() {
        guard offersNewAddress else { return }
        let address = recipientTerm
        Task { if let chat = await model.createChat(address) { open(chat) } }
    }
}
