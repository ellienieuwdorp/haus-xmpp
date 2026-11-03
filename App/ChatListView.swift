import MessageStore
import SwiftUI

struct ChatListView: View {
    @Bindable var model: AppModel
    @Binding var path: [ChatRoute]
    @Binding var showingConnection: Bool
    @Binding var showingSettings: Bool
    @State private var search = ""
    @State private var recipient = ""
    @State private var showingNewChat = false
    @State private var showingRestore = false
    @State private var newChatDetent: PresentationDetent = .medium
    @State private var muting: String?
    @State private var reviewingOwnDevices = false
    // A device not in here brings the card back.
    @State private var ownDevicesLater: Set<String> = []

    private var searchTerm: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sortedChats: [ChatSummary] { ChatListOrder.sorted(model.chats) }

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
        // The empty states are overlays: swapping the content view would crossfade the title bar and toolbar when the
        // first rows arrive.
        List {
            if let listCaption, !model.chats.isEmpty {
                Text(listCaption)
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            }
            if showsOwnDeviceReview {
                OwnDeviceReviewCard(candidates: model.ownDeviceReview,
                                    review: { reviewingOwnDevices = true },
                                    later: { withAnimation { ownDevicesLater.formUnion(model.ownDeviceReview.map(\.id)) } })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
            }
            // Identity includes the pin state, so List animates a pin as delete + insert (a fade in place); a real move
            // slides the row from below the last cell under its siblings (iOS 26.5, 27).
            ForEach(visibleChats, id: \.listIdentity) { chat in
                Button { path.append(.chat(chat.id)) } label: { ChatRow(chat: chat, isGroup: model.isGroup(chat.id), avatar: model.avatar(for: chat.id), typing: model.typing[chat.id], isBlocked: model.isBlocked(chat.id)) }
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
                                // Changing the list while the swipe action closes animates the still-open cell.
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
                            Button("Mute", systemImage: "bell.slash") { muting = chat.id }.tint(Color(.systemGray))
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.chats.isEmpty {
                // Quiet until storage is read: a signed-in cold start must not flash "no conversations".
                if model.hasLoadedChats {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(model.accountID.isEmpty ? signedOutHint : "Tap the compose button to start a conversation.")
                    } actions: {
                        if model.accountID.isEmpty {
                            Button("Explore sample conversations") { Task { await model.loadDemo() } }
                                .buttonStyle(.borderedProminent)
                            if model.canRestoreTransfer {
                                Button("Restore from a transfer…") { showingRestore = true }
                                    .accessibilityIdentifier("emptyRestoreTransfer")
                            }
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
                // A fixed glass circle: the bar's automatic shape is a capsule on iOS 27.
                Button { newChatDetent = .medium; showingNewChat = true } label: {
                    // The pencil tip extends the glyph's box upward; the offset centres the square on the circle.
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
        .sheet(isPresented: $showingRestore) { RestoreTransferView(model: model).themedRoot() }
        .sheet(isPresented: $reviewingOwnDevices) { OwnDeviceReviewSheet(model: model) }
    }

    private var recipientTerm: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var suggestedChats: [ChatSummary] {
        guard !recipientTerm.isEmpty else { return sortedChats }
        return sortedChats.filter { $0.title.localizedCaseInsensitiveContains(recipientTerm) || $0.id.localizedCaseInsensitiveContains(recipientTerm) }
    }

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
                                    ChatAvatar(key: chat.id, name: chat.displayTitle, image: model.avatar(for: chat.id), isGroup: model.isGroup(chat.id), size: 40)
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

// Must outlast the swipe action's close (~0.30 s on iOS 26.5 plus the highlight fade); not below 300 ms.
private let pinCommitDelay: Duration = .milliseconds(350)

private extension ChatSummary {
    var listIdentity: String { "\(id)|\(isPinned ? 1 : 0)" }
}
