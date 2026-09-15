import SwiftUI

struct ChatListView: View {
    @Bindable var model: AppModel
    @Binding var path: [String]
    @Binding var showingConnection: Bool
    @Binding var showingSettings: Bool
    @State private var search = ""
    @State private var recipient = ""
    @State private var showingNewChat = false
    @State private var newChatDetent: PresentationDetent = .medium

    private var searchTerm: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visibleChats: [ChatSummary] {
        guard !searchTerm.isEmpty else { return model.chats }
        return model.chats.filter { $0.title.localizedCaseInsensitiveContains(searchTerm) || $0.id.localizedCaseInsensitiveContains(searchTerm) }
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
                    Section {
                        Label(model.isDemo ? "Sample conversations · stored on this device" : "Local development lab", systemImage: "flask")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(visibleChats) { chat in
                        Button { path.append(chat.id) } label: {
                            HStack(spacing: 13) {
                                Group {
                                    if model.isGroup(chat.id) { Image(systemName: "person.2.fill") }
                                    else { Text(String(chat.title.prefix(1)).uppercased()) }
                                }
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.indigo)
                                    .frame(width: 48, height: 48)
                                    .background(.indigo.opacity(0.10), in: Circle())
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(chat.title).font(.headline).foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(chat.preview.isEmpty ? "Start a conversation" : chat.preview)
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if chat.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(chat.isPinned ? "Pinned" : "")
                        .accessibilityIdentifier("chat.\(chat.id)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin") {
                                Task { await model.togglePin(chat) }
                            }.tint(.indigo)
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
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search conversations")
        .navigationDestination(for: String.self) { chatID in
            ConversationView(model: model, chatID: chatID)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button { newChatDetent = .medium; showingNewChat = true } label: {
                    Image(systemName: "pencil")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
                    .buttonStyle(CircularGlassButtonStyle(diameter: 56))
                    .accessibilityLabel("New conversation")
                    .accessibilityIdentifier("newConversation")
                    .disabled(model.accountID.isEmpty)
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .sheet(isPresented: $showingNewChat) {
            NavigationStack {
                Form {
                    TextField("name@server", text: $recipient).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Create conversation") {
                        Task {
                            let address = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await model.createChat(address) {
                                showingNewChat = false
                                recipient = ""
                                path.append(address)
                            }
                        }
                    }.disabled(recipient.isEmpty)
                    Section {
                        NavigationLink {
                            GroupJoinView(model: model) { room in
                                showingNewChat = false
                                recipient = ""
                                path.append(room)
                            }.onAppear { newChatDetent = .large }
                        } label: { Label("Join a group", systemImage: "person.2") }
                        .disabled(!model.isConnected || !model.encryptionReady)
                        .accessibilityIdentifier("newGroup")
                    }
                }
                .navigationTitle("New conversation")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNewChat = false } } }
            }.presentationDetents([.medium, .large], selection: $newChatDetent)
        }
    }
}
