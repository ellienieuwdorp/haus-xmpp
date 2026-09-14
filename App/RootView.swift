import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var selectedTab = 0
    @State private var showingConnection = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: 0) {
                NavigationStack {
                    ChatListView(model: model)
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
                        Section("Development preview") {
                            Text("Received lab messages: \(model.receivedCount)")
                                .accessibilityIdentifier("labReceivedCount")
                            Text("This first build supports local test messages. End-to-end encryption is not implemented yet.")
                                .foregroundStyle(.secondary)
                            Button("Explore sample conversations") { Task { await model.loadDemo() } }
                        }
                    }
                    .navigationTitle("Settings")
                }
            }
        }
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
    @State private var search = ""
    @State private var recipient = ""
    @State private var showingNewChat = false

    private var visibleChats: [ChatSummary] {
        guard !search.isEmpty else { return model.chats }
        return model.chats.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if model.chats.isEmpty {
                ContentUnavailableView {
                    Label("A little closer", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Your conversations will live here. Connect to the local lab from Settings, or explore the interface with sample messages.")
                } actions: {
                    Button("Explore sample conversations") { Task { await model.loadDemo() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        Label(model.isDemo ? "Sample conversations · stored on this device" : "Local lab · not end-to-end encrypted", systemImage: "flask")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(visibleChats) { chat in
                        NavigationLink(value: chat.id) {
                            HStack(spacing: 13) {
                                Text(String(chat.title.prefix(1)).uppercased())
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.indigo)
                                    .frame(width: 48, height: 48)
                                    .background(.indigo.opacity(0.10), in: Circle())
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(chat.title).font(.headline)
                                        Spacer()
                                        if chat.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Text(chat.preview.isEmpty ? "Start a conversation" : chat.preview)
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .swipeActions(edge: .leading) {
                            Button(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin") {
                                Task { await model.togglePin(chat) }
                            }.tint(.indigo)
                        }
                        .contextMenu {
                            Button(chat.isPinned ? "Unpin chat" : "Pin chat", systemImage: "pin") {
                                Task { await model.togglePin(chat) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Chats")
        .searchable(text: $search, prompt: "Find a conversation")
        .navigationDestination(for: String.self) { chatID in
            ConversationView(model: model, chatID: chatID)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button { showingNewChat = true } label: {
                    Image(systemName: "square.and.pencil")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                }
                    .buttonStyle(CircularGlassButtonStyle(diameter: 48))
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
                            if await model.createChat(recipient) { showingNewChat = false; recipient = "" }
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
                    Text("Connect a disposable account on the local development server. Messages use TLS but are not end-to-end encrypted.")
                    TextField("Username (without @localhost)", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("labUsername")
                    SecureField("Password", text: $password).accessibilityIdentifier("labPassword")
                    Toggle("Use unencrypted lab messages", isOn: $consent)
                        .accessibilityIdentifier("labConsent")
                } footer: {
                    Text("localhost:5223 · Direct TLS. The lab certificate must be trusted in this simulator. Passwords stay in memory for this session.")
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
            .navigationTitle("Local lab")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
