import SwiftUI

struct ConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var draft = ""
    @State private var query = ""
    @State private var showingSearch = false
    @State private var starredOnly = false
    @State private var retryMessageID: String?
    @State private var replyingTo: ChatMessage?
    @FocusState private var composing: Bool

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var messages: [ChatMessage] {
        model.messages.filter { message in
            (!starredOnly || message.isStarred) && (searchTerm.isEmpty || message.body.localizedCaseInsensitiveContains(searchTerm))
        }
    }

    private func authorName(_ sender: String) -> String {
        sender == model.accountID ? "you" : (model.chats.first(where: { $0.id == chatID })?.title ?? sender)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingSearch {
                ConversationSearchBar(query: $query) {
                    showingSearch = false
                    query = ""
                }
                .frame(height: 56)
                .padding(.horizontal, 4)
                if !searchTerm.isEmpty {
                    Text(messages.isEmpty ? "No results in this conversation" : "\(messages.count) \(messages.count == 1 ? "message" : "messages") found")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
            } else {
                Label(model.isDemo ? "Sample conversation" : "Lab messages · no end-to-end encryption", systemImage: "flask")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
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
                                sentAt: $0.sentAt, status: $0.transportState.flatMap { TimelineMessage.Status(rawValue: $0.rawValue) },
                                reply: $0.reply.map { TimelineReply(author: authorName($0.senderID), body: $0.body) })
            }, onToggleStar: { id in Task { await model.toggleStar(id) } }, onRetryMessage: { retryMessageID = $0 }, onReply: { id in
                guard let message = model.messages.first(where: { $0.id == id }) else { return }
                replyingTo = message
                showingSearch = false
                query = ""
                composing = true
            })
            .overlay {
                if messages.isEmpty {
                    ContentUnavailableView(!searchTerm.isEmpty ? "No matching messages" : (starredOnly ? "No starred messages" : "No messages yet"),
                                           systemImage: !searchTerm.isEmpty ? "magnifyingglass" : (starredOnly ? "star" : "bubble.left"))
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
                    Button("Search messages", systemImage: "magnifyingglass") { composing = false; showingSearch = true }
                    Button("Starred messages", systemImage: "star") { starredOnly = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Conversation options")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showingSearch {
              VStack(spacing: 0) {
                if let reply = replyingTo {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Replying to \(authorName(reply.senderID))").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                            Text(reply.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { replyingTo = nil } label: { Image(systemName: "xmark").font(.body) .frame(width: 44, height: 44) }
                            .accessibilityLabel("Cancel reply").accessibilityIdentifier("cancelReply")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16).padding(.trailing, 4).padding(.top, 10)
                }
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
                    let reply = replyingTo
                    Task {
                        if await model.send(text, to: chatID, replyingTo: reply), draft == text, model.accountID == account {
                            draft = ""
                            if replyingTo?.id == reply?.id { replyingTo = nil }
                        }
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
              }
              .background(.bar)
            }
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
