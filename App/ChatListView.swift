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

    var body: some View {
        Group {
            if model.chats.isEmpty {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(model.accountID.isEmpty
                         ? "Connect to the local lab in Settings, or explore sample conversations."
                         : "Tap the compose button to start a conversation.")
                } actions: {
                    if model.accountID.isEmpty {
                        Button("Explore sample conversations") { Task { await model.loadDemo() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    if model.isDemo || model.isLabAccount {
                        Text(model.isDemo ? "Sample conversations · stored on this device" : "Local development lab")
                            .font(.footnote).foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                    }
                    ForEach(visibleChats) { chat in
                        Button { path.append(.chat(chat.id)) } label: { ChatRow(chat: chat, isGroup: model.isGroup(chat.id)) }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
                            .accessibilityValue(chat.isPinned ? "Pinned" : "")
                            .accessibilityIdentifier("chat.\(chat.id)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin") {
                                    Task { await model.togglePin(chat) }
                                }.tint(Color(uiColor: AccentTheme.current.tint))
                            }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if visibleChats.isEmpty {
                        ContentUnavailableView.search(text: searchTerm)
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingConnection = true } label: {
                    ZStack {
                        Circle().fill(model.accountID.isEmpty ? Color(.systemGray3) : Color(uiColor: AvatarPalette.color(for: model.accountID)))
                        if let accountInitial {
                            Text(accountInitial).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        } else {
                            Image(systemName: "person.fill").font(.subheadline).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Account")
            }
            // Connection progress is a quiet spinner that disappears; only a setup failure gets a glyph.
            if model.isSettlingConnection {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView().controlSize(.small).accessibilityLabel("Connecting")
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
            Task { if await model.createChat(address) { openFromSheet(address) } }
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
                                    Avatar(chat: chat, isGroup: model.isGroup(chat.id), size: 40)
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

private struct Avatar: View {
    let chat: ChatSummary
    let isGroup: Bool
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: AvatarPalette.color(for: chat.displayTitle)))
            if isGroup { Image(systemName: "person.2.fill").font(.system(size: size * 0.38, weight: .semibold)) }
            else { Text(String(chat.displayTitle.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .semibold)) }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ChatRow: View {
    let chat: ChatSummary
    let isGroup: Bool

    private static let dayMonth: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM"; return f }()

    private var timeLabel: String? {
        guard let date = chat.lastMessageAt else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now)), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return Self.dayMonth.string(from: date)
    }

    private var stateGlyph: String? {
        guard chat.lastMessageIsOutgoing else { return nil }
        switch chat.lastMessageState {
        case .queued, .submitting, .unconfirmed: return "clock"
        case .failed: return "exclamationmark.circle"
        case .serverAccepted, nil: return "checkmark"
        }
    }

    private var preview: Text {
        let body = Text(chat.preview.isEmpty ? "Start a conversation" : chat.preview)
        guard let stateGlyph else { return body }
        return Text(Image(systemName: stateGlyph)) + Text(" ") + body
    }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(chat: chat, isGroup: isGroup)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(chat.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    if chat.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    if let timeLabel {
                        Text(timeLabel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                    }
                }
                preview.font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}
