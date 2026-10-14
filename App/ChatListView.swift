import SwiftUI

struct ChatListView: View {
    @Bindable var model: AppModel
    @Binding var path: [ChatRoute]
    @Binding var showingConnection: Bool
    @Binding var showingSettings: Bool
    @State private var search = ""
    @State private var recipient = ""
    @State private var showingNewChat = false
    @State private var newChatDetent: PresentationDetent = .medium
    /// The chat whose Mute swipe action asked for a duration.
    @State private var muting: String?
    @State private var reviewingOwnDevices = false
    /// Own devices the card was put off for with Later; a device not in here brings the card back.
    @State private var ownDevicesLater: Set<String> = []

    private var searchTerm: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Pinned first, then newest activity; ties keep the store's order.
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

    private var accountInitial: String? {
        let local = model.accountID.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? nil : String(local.prefix(1)).uppercased()
    }

    private var showsOwnDeviceReview: Bool {
        searchTerm.isEmpty && model.ownDeviceReview.contains { !ownDevicesLater.contains($0.id) }
    }

    /// A quiet line above sample chats (and, in DEBUG, lab chats).
    private var listCaption: String? {
        if model.isDemo { return "Sample conversations · stored on this device" }
        #if DEBUG
        if model.isLabAccount { return "Local development lab" }
        #endif
        return nil
    }

    private var signedOutHint: String {
        #if DEBUG
        "Connect to the local lab in Settings, or explore sample conversations."
        #else
        "Sign in to your XMPP account in Settings, or explore sample conversations."
        #endif
    }

    var body: some View {
        // The list is always the content, with the empty states as overlays: swapping the content view would
        // crossfade the title bar and toolbar along with it whenever the first rows arrive.
        List {
            if let listCaption, !model.chats.isEmpty {
                Text(listCaption)
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            }
            // Account-level, so it sits above every chat: one decision here reaches all of them.
            if showsOwnDeviceReview {
                OwnDeviceReviewCard(candidates: model.ownDeviceReview,
                                    review: { reviewingOwnDevices = true },
                                    later: { withAnimation { ownDevicesLater.formUnion(model.ownDeviceReview.map(\.id)) } })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
            }
            // The row identity includes the pin state, so a pin change is a delete + insert (Signal's
            // same-section rule): List animates that as a fade in place, whereas a real move to the top
            // starts the row from below the last cell and slides it under its siblings (iOS 26.5 and 27).
            ForEach(visibleChats, id: \.listIdentity) { chat in
                Button { path.append(.chat(chat.id)) } label: { ChatRow(chat: chat, isGroup: model.isGroup(chat.id), avatar: model.avatars[chat.id], typing: model.typing[chat.id]) }
                    .buttonStyle(.plain)
                    .task(id: "\(chat.id)|\(model.session.isReady)") { await model.loadAvatar(for: chat.id) }
                    .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
                    .accessibilityValue([chat.isPinned ? "Pinned" : nil, chat.notification.isMuted() ? "Muted" : nil].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityIdentifier("chat.\(chat.id)")
                    .modifier(MuteDialog(model: model, chat: chat, muting: $muting))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if chat.unreadCount > 0 {
                            Button("Read", systemImage: "envelope.open") {
                                Task { try? await Task.sleep(for: pinCommitDelay); await model.markChatRead(chat.id) }
                            }.tint(.gray)
                        }
                        Button(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin") {
                            Task {
                                // Let the swipe action close first (~0.30 s on 26.5 plus the highlight
                                // fade); changing the list in the same turn animates the still-open cell.
                                try? await Task.sleep(for: pinCommitDelay)
                                await model.togglePin(chat)
                            }
                        }.tint(Color(uiColor: AccentTheme.current.tint))
                        // One neutral tint for both states, so it never reads as a second pin beside the accent.
                        if chat.notification.isMuted() {
                            Button("Unmute", systemImage: "bell") {
                                Task {
                                    try? await Task.sleep(for: pinCommitDelay)
                                    await model.unmuteChat(chat.id)
                                }
                            }.tint(Color(.systemGray))
                        } else {
                            // The durations are a choice, so they follow in a dialog; nothing changes until one is picked.
                            Button("Mute", systemImage: "bell.slash") { muting = chat.id }.tint(Color(.systemGray))
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.chats.isEmpty {
                // Until storage has been read (a cold start) the list stays quiet: a signed-in launch must not
                // flash "no conversations" a moment before its rows arrive.
                if model.hasLoadedChats {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(model.accountID.isEmpty ? signedOutHint : "Tap the compose button to start a conversation.")
                    } actions: {
                        if model.accountID.isEmpty {
                            Button("Explore sample conversations") { Task { await model.loadDemo() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else if visibleChats.isEmpty {
                ContentUnavailableView.search(text: searchTerm)
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingConnection = true } label: {
                    ChatAvatar(key: model.accountID, name: accountInitial ?? "", image: model.avatars[model.accountID], size: 30)
                }
                .accessibilityLabel("Account")
            }
            // Connection progress is a quiet spinner that disappears; only a setup failure gets a glyph.
            if model.isSettlingConnection || model.isCatchingUp {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView().controlSize(.small).accessibilityLabel(model.isCatchingUp ? "Catching up" : "Connecting")
                }
                .sharedBackgroundVisibility(.hidden)
            } else if model.connectionNeedsAttention {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                        .accessibilityLabel("Encryption setup needs attention")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("Settings")
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                // Our own fixed glass circle: the bar's automatic shape came out as a capsule on iOS 27.
                Button { newChatDetent = .medium; showingNewChat = true } label: {
                    // The pencil tip extends the glyph's box upward, so mathematical centring reads low.
                    // Nudge so the square, the visual anchor, sits on the circle's centre.
                    Image(systemName: "square.and.pencil").font(.title3.weight(.medium)).offset(x: 0.5, y: -1.5)
                }
                .buttonStyle(CircularGlassButtonStyle(diameter: 50, tinted: false))
                .accessibilityLabel("New conversation")
                .accessibilityIdentifier("newConversation")
                .disabled(model.accountID.isEmpty)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .navigationDestination(for: ChatRoute.self) { route in
            switch route {
            case .chat(let chatID): ConversationView(model: model, chatID: chatID)
            case .details(let chatID): ChatDetailsView(model: model, chatID: chatID)
            case .encryption(let chatID): EncryptionDetailsView(model: model, chatID: chatID)
            case .groupDetails(let room): GroupDetailsView(model: model, room: room)
            }
        }
        .sheet(isPresented: $showingNewChat) { newChatSheet }
        .sheet(isPresented: $reviewingOwnDevices) { OwnDeviceReviewSheet(model: model) }
    }

    private var recipientTerm: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var suggestedChats: [ChatSummary] {
        guard !recipientTerm.isEmpty else { return sortedChats }
        return sortedChats.filter { $0.title.localizedCaseInsensitiveContains(recipientTerm) || $0.id.localizedCaseInsensitiveContains(recipientTerm) }
    }

    /// A typed address that is not already a chat gets a "Start chat" row; createChat validates it.
    private var offersNewAddress: Bool {
        recipientTerm.contains("@") && !sortedChats.contains { $0.id.caseInsensitiveCompare(recipientTerm) == .orderedSame }
    }

    private var startChatRow: some View {
        Button {
            let address = recipientTerm
            Task { if let chat = await model.createChat(address) { openFromSheet(chat) } }
        } label: {
            Label {
                Text("Start chat with \(recipientTerm)").foregroundStyle(.primary).lineLimit(1)
            } icon: {
                Image(systemName: "plus.message.fill")
                    .foregroundStyle(Color(uiColor: AccentTheme.current.tint))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("startChat")
    }

    private func openFromSheet(_ chatID: String) {
        showingNewChat = false
        recipient = ""
        path.append(.chat(chatID))
    }

    private var newChatSheet: some View {
        NavigationStack {
            List {
                // An input row, not a search field: it filters Suggested and, given an address, starts a chat right below.
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "at").foregroundStyle(.secondary)
                        TextField("Name or address", text: $recipient)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .accessibilityIdentifier("newChatAddress")
                    }
                    if offersNewAddress {
                        startChatRow
                    }
                }
                Section {
                    NavigationLink {
                        GroupJoinView(model: model) { room in openFromSheet(room) }
                    } label: {
                        Label {
                            Text("Join a Group by Address")
                        } icon: {
                            Image(systemName: "person.2")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color(uiColor: AccentTheme.current.tint), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .disabled(!model.session.isReady)
                    .accessibilityIdentifier("newGroup")
                }
                if !suggestedChats.isEmpty {
                    Section("Suggested") {
                        ForEach(suggestedChats) { chat in
                            Button { openFromSheet(chat.id) } label: {
                                HStack(spacing: 12) {
                                    ChatAvatar(key: chat.id, name: chat.displayTitle, image: model.avatars[chat.id], isGroup: model.isGroup(chat.id), size: 40)
                                    VStack(alignment: .leading) {
                                        Text(chat.displayTitle).foregroundStyle(.primary)
                                        Text(chat.id).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNewChat = false } } }
        }
        .presentationDetents([.medium, .large], selection: $newChatDetent)
        .presentationDragIndicator(.visible)
        // Pinned so the sheet doesn't switch from glass to opaque when it reaches the top.
        .presentationBackground(Color(.systemGroupedBackground))
    }
}

/// Delay between the Pin/Unpin tap and the model change, so the swipe action finishes closing before the row moves.
/// Measured close: ~0.30 s on iOS 26.5, ~0.23 s on 27.0, plus the highlight fade; do not go below 300 ms.
private let pinCommitDelay: Duration = .milliseconds(350)

private extension ChatSummary {
    /// Changes with the pin state so that List animates a pin as a delete + insert rather than a move.
    var listIdentity: String { "\(id)|\(isPinned ? 1 : 0)" }
}
