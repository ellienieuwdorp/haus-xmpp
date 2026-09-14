import SwiftUI

struct ConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var draft = ""
    @State private var query = ""
    @State private var showingSearch = false
    @State private var starredOnly = false
    @State private var retryMessageID: String?
    @FocusState private var composing: Bool

    private var messages: [ChatMessage] {
        model.messages.filter { message in
            (!starredOnly || message.isStarred) && (query.isEmpty || message.body.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Label(model.isDemo ? "Sample conversation" : "Lab messages · no end-to-end encryption", systemImage: "flask")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            if showingSearch {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search in this conversation", text: $query)
                        .accessibilityIdentifier("messageSearch")
                    Button("Close", systemImage: "xmark.circle.fill") { showingSearch = false; query = "" }
                        .labelStyle(.iconOnly)
                }.padding(.horizontal).padding(.bottom, 8)
            }
            if starredOnly {
                HStack {
                    Label("Starred messages", systemImage: "star.fill").font(.caption)
                    Spacer()
                    Button("Show all") { starredOnly = false }
                }.padding(.horizontal).padding(.bottom, 8)
            }
            ConversationTimeline(messages: messages.map {
                TimelineMessage(id: $0.id, body: $0.body, isOutgoing: $0.isOutgoing, isStarred: $0.isStarred,
                                sentAt: $0.sentAt, status: $0.transportState.flatMap { TimelineMessage.Status(rawValue: $0.rawValue) })
            }, onToggleStar: { id in Task { await model.toggleStar(id) } }, onRetryMessage: { retryMessageID = $0 })
            .overlay {
                if messages.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No messages yet" : "No matching messages", systemImage: "bubble.left")
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(model.chats.first(where: { $0.id == chatID })?.title ?? chatID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Search messages", systemImage: "magnifyingglass") { showingSearch = true }
                    Button("Starred messages", systemImage: "star") { starredOnly = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Conversation options")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(model.isDemo ? "Message" : (model.isConnected ? "Message" : "Message · sends when connected"), text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
                    .focused($composing)
                    .accessibilityIdentifier("messageComposer")
                Button {
                    let text = draft
                    let account = model.accountID
                    Task {
                        if await model.send(text, to: chatID), draft == text, model.accountID == account { draft = "" }
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(CircularGlassButtonStyle(diameter: 44))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
                .accessibilityLabel("Send message").accessibilityIdentifier("sendMessage")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .confirmationDialog("Send this message again?", isPresented: Binding(
            get: { retryMessageID != nil }, set: { if !$0 { retryMessageID = nil } }
        ), titleVisibility: .visible, presenting: retryMessageID) { id in
            Button("Send again") {
                Task { await model.retryMessage(id) }
                retryMessageID = nil
            }
            Button("Cancel", role: .cancel) { retryMessageID = nil }
        } message: { _ in
            Text("The recipient may already have it. Sending again could create a duplicate.")
        }
        .task(id: chatID) { await model.openChat(chatID) }
        .onDisappear { model.closeChat(chatID) }
    }
}
