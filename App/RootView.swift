import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var selectedTab = 0
    @State private var chatPath: [String] = []
    @State private var showingConnection = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: 0) {
                NavigationStack(path: $chatPath) {
                    ChatListView(model: model, path: $chatPath)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Account", systemImage: "person.crop.circle") { showingConnection = true }
                            }
                        }
                }.id(model.accountID)
            }
            Tab("Settings", systemImage: "gearshape", value: 1) {
                NavigationStack {
                    List {
                        Section("Account") {
                            LabeledContent("Connection", value: model.connectionStatus)
                            Button("Connect to local lab") { showingConnection = true }
                            if model.isConnected {
                                Button("Disconnect") { Task { await model.disconnect() } }
                            }
                        }
                        if model.accountID.hasSuffix("@staging.example.net") {
                            Section("Notifications") {
                                LabeledContent("Status", value: model.notificationStatus)
                                Button("Enable notifications") { Task { await model.enableNotifications() } }
                                    .disabled(!model.isConnected || !model.encryptionReady)
                                    .accessibilityIdentifier("enableNotifications")
                            }
                        }
                        Section("Development preview") {
                            Text("Received lab messages: \(model.receivedCount)")
                                .accessibilityIdentifier("labReceivedCount")
                            Text("This development build supports encrypted direct messages between local test accounts. Archive recovery is enabled. Push delivery is being validated on the staging server.")
                                .foregroundStyle(.secondary)
                            Button("Explore sample conversations") { Task { await model.loadDemo() } }
                        }
                    }
                    .navigationTitle("Settings")
                }
            }
        }
        .onChange(of: model.accountID) { _, _ in chatPath.removeAll() }
        .sheet(isPresented: $showingConnection) { ConnectionView(model: model) }
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct ChatListView: View {
    @Bindable var model: AppModel
    @Binding var path: [String]
    @State private var search = ""
    @State private var recipient = ""
    @State private var showingNewChat = false

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
                                Text(String(chat.title.prefix(1)).uppercased())
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
                Button { showingNewChat = true } label: {
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
                }
                .navigationTitle("New conversation")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNewChat = false } } }
            }.presentationDetents([.medium])
        }
    }
}

struct ConnectionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var consent = false

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-lab-ui-test") {
            _username = State(initialValue: ProcessInfo.processInfo.environment["XMPP_LAB_USERNAME"] ?? "")
            _password = State(initialValue: ProcessInfo.processInfo.environment["XMPP_LAB_PASSWORD"] ?? "")
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Connect a disposable account on the local development server. New messages require end-to-end encryption and approved recipient devices.")
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("labUsername")
                    SecureField("Password", text: $password).accessibilityIdentifier("labPassword")
                    Toggle("Use a disposable lab account", isOn: $consent)
                        .accessibilityIdentifier("labConsent")
                } footer: {
                    Text("\(DevelopmentEndpoint.host):5223 · Direct TLS. The lab certificate must be trusted by this connection. Enabling notifications stores this account in this device’s protected Keychain for background synchronization.")
                }
                Section {
                    Button(model.isConnecting ? "Connecting…" : "Connect") {
                        Task {
                            if await model.connect(username: username, password: password) {
                                password = ""
                                dismiss()
                            }
                        }
                    }.disabled(!consent || username.isEmpty || password.isEmpty || model.isConnecting)
                    Text(model.connectionStatus).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(DevelopmentEndpoint.domain == "localhost" ? "Local lab" : "Staging lab")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
