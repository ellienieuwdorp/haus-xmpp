import SwiftUI

/// The sidebar: the account's chats with selection and search, the own-device review card above them, and per-chat
/// actions in a right-click menu. The iPhone's trailing swipe actions (Read, Pin, Mute) are menu items here; a Mac
/// list has no swipe actions.
struct MacChatList: View {
    @Bindable var model: AppModel
    @Bindable var window: MacWindowState
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// Own devices the card was put off for with Later; a device not in here brings the card back.
    @State private var ownDevicesLater: Set<String> = []
    /// A Block or Report chosen from a chat's menu, waiting for its confirmation.
    @State private var blockRequest: BlockRequest?

    private var searchTerm: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Pinned first, then newest activity; ties keep the store's order. The iPhone list's order.
    private var sortedChats: [ChatSummary] {
        model.chats.enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }
            let da = a.element.lastMessageAt ?? .distantPast, db = b.element.lastMessageAt ?? .distantPast
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }

    private var visibleChats: [ChatSummary] {
        guard !searchTerm.isEmpty else { return sortedChats }
        return sortedChats.filter { $0.title.localizedCaseInsensitiveContains(searchTerm) || $0.id.localizedCaseInsensitiveContains(searchTerm) }
    }

    private var showsOwnDeviceReview: Bool {
        searchTerm.isEmpty && model.ownDeviceReview.contains { !ownDevicesLater.contains($0.id) }
    }

    private var accountInitial: String {
        String((model.accountID.split(separator: "@").first ?? "").prefix(1)).uppercased()
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
                    .contextMenu { actions(for: chat) }
            }
        }
        .listStyle(.sidebar)
        .blockConfirmation(model: model, request: $blockRequest)
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
            if model.isDemo || model.isLabAccount, !model.chats.isEmpty {
                Text(model.isDemo ? "Sample conversations · stored on this Mac" : "Local development lab")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: window.searchRequests) { _, _ in searchFocused = true }
        .navigationTitle("Chats")
        .toolbar {
            // In the sidebar's own bar, next to New Chat; `.navigation` would put it in front of the chat's title.
            ToolbarItem(placement: .primaryAction) {
                Button { window.showingAccount = true } label: {
                    ChatAvatar(key: model.accountID, name: accountInitial, image: model.avatars[model.accountID], size: 22)
                }
                .help(model.accountID.isEmpty ? "Sign in" : model.accountID)
                .accessibilityLabel("Account")
            }
            ToolbarItem(placement: .primaryAction) {
                // Connection progress is a quiet spinner that disappears; only a setup failure gets a glyph.
                if model.isSettlingConnection || model.isCatchingUp {
                    ProgressView().controlSize(.small).accessibilityLabel(model.isCatchingUp ? "Catching up" : "Connecting")
                } else if model.connectionNeedsAttention {
                    SettingsLink { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                        .help("Encryption setup needs attention")
                        .accessibilityLabel("Encryption setup needs attention")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { window.showingNewChat = true } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .help("New Chat (⌘N)")
                    .disabled(model.accountID.isEmpty)
            }
        }
    }

    /// The iPhone's trailing swipe actions, plus the chat's details.
    @ViewBuilder private func actions(for chat: ChatSummary) -> some View {
        if chat.unreadCount > 0 {
            Button("Mark as Read", systemImage: "envelope.open") { Task { await model.markChatRead(chat.id) } }
        }
        Button(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin") { Task { await model.togglePin(chat) } }
        if chat.notification.isMuted() {
            Button("Unmute", systemImage: "bell") { Task { await model.unmuteChat(chat.id) } }
        } else {
            // The durations the iPhone offers in its dialog; nothing changes until one is picked.
            Menu("Mute", systemImage: "bell.slash") {
                ForEach(MuteDuration.allCases) { duration in
                    Button(duration.dialogTitle) { Task { await model.muteChat(chat.id, for: duration) } }
                }
            }
        }
        if !model.isGroup(chat.id) {
            Divider()
            blockActions(for: chat)
        }
        Divider()
        Button("Chat Details", systemImage: "info.circle") {
            window.selection = chat.id
            window.inspectorShown = true
        }
    }

    /// The details' Block, Report and Unblock, as menu items; disabled without a server that blocks.
    @ViewBuilder private func blockActions(for chat: ChatSummary) -> some View {
        let available = model.blockingAvailability.isAvailable
        if model.isBlocked(chat.id) {
            Button("Unblock", systemImage: "hand.raised.slash") {
                Task { for entry in model.blockEntries(for: chat.id) { await model.unblock(entry) } }
            }
            .disabled(!available)
        } else {
            Button("Block…", systemImage: "hand.raised") { blockRequest = BlockRequest(kind: .block, chatID: chat.id, name: chat.displayTitle) }
                .disabled(!available)
            Button("Report…", systemImage: "exclamationmark.bubble") { blockRequest = BlockRequest(kind: .report, chatID: chat.id, name: chat.displayTitle) }
                .disabled(!available)
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
