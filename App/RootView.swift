import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var chatPath: [ChatRoute] = []
    @State private var chatDetails: ChatDetailsRequest?
    // Kept until the sheet has gone, not cleared as it starts to leave.
    @State private var chatBehindDetails: String?
    @State private var showingConnection = false
    @State private var showingSettings = false

    var body: some View {
        if model.transferState == .none, model.upgradeState == .none, model.keyRecovery == nil {
            chats
        } else {
            Group {
                if model.transferState != .none { TransferBlockingView(model: model) }
                else if model.upgradeState != .none { UpgradeBlockingView(model: model) } else { KeyRecoveryView(model: model) }
            }
            // The transfer started from Settings: when the chats come back (a fresh install after Delete Data, or the
            // data taken back), they come back without that sheet, or a chat's details.
            .onAppear { showingSettings = false; showingConnection = false; chatDetails = nil; chatBehindDetails = nil }
            .alert("Something needs attention", isPresented: Binding(
                get: { model.error != nil }, set: { if !$0 { model.error = nil } }
            )) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }

    private var chats: some View {
        NavigationStack(path: $chatPath) {
            ChatListView(model: model, path: $chatPath, showingConnection: $showingConnection, showingSettings: $showingSettings)
        }
        .environment(\.chatBehindDetails, chatBehindDetails)
        .id(model.accountID)
        .onChange(of: model.accountID) { _, _ in chatPath.removeAll(); chatDetails = nil }
        .onChange(of: model.notificationRoute, initial: true) { _, route in
            guard let route else { return }
            model.consumeNotificationRoute(route.id)
            guard route.accountID == model.accountID else { return }
            showingConnection = false
            showingSettings = false
            chatDetails = nil
            chatPath = [.chat(route.chatID)]
        }
        // A chat's details and the pages under them open in a sheet over the chat; a chat is pushed.
        .onChange(of: model.requestedRoute) { _, route in
            guard let route else { return }
            model.requestedRoute = nil
            if let details = ChatDetailsRequest(route) {
                chatBehindDetails = details.chatID
                chatDetails = details
            } else {
                chatDetails = nil
                chatPath.append(route)
            }
        }
        .onChange(of: model.signInRequested) { _, requested in
            guard requested else { return }
            model.signInRequested = false
            chatDetails = nil
            showingConnection = true
        }
        .sheet(item: $chatDetails, onDismiss: { chatBehindDetails = chatDetails?.chatID }) { details in
            ChatDetailsSheet(model: model, request: details).themedRoot()
        }
        .sheet(isPresented: $showingConnection) { SignInView(model: model).themedRoot() }
        .alert("Transfer restored", isPresented: $model.transferRestored) {
            Button("OK") {}
        } message: {
            Text("Your chats are here. To finish the move, open Haus XMPP on the other device and choose Delete Data.")
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(model: model, showingConnection: $showingConnection)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
                    }
            }
            .themedRoot()
        }
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

// A shortcut to encryption or group details opens the chat's details with that page already pushed, so Back leads to
// the details and the close button to the chat.
struct ChatDetailsRequest: Identifiable {
    let id = UUID()
    let chatID: String
    let path: [ChatRoute]

    init?(_ route: ChatRoute) {
        switch route {
        case .chat: return nil
        case .details(let chatID), .encryption(let chatID), .groupDetails(let chatID): self.chatID = chatID
        }
        path = route == .details(chatID) ? [] : [route]
    }
}

// The chat stays on screen under the sheet, which keeps its own stack.
struct ChatDetailsSheet: View {
    let model: AppModel
    let chatID: String
    @State private var path: [ChatRoute]
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, request: ChatDetailsRequest) {
        self.model = model
        chatID = request.chatID
        _path = State(initialValue: request.path)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ChatDetailsView(model: model, chatID: chatID)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier("closeChatDetails")
                    }
                }
                .navigationDestination(for: ChatRoute.self) { route in
                    switch route {
                    case .encryption(let chatID): EncryptionDetailsView(model: model, chatID: chatID)
                    case .groupDetails(let room): GroupDetailsView(model: model, room: room)
                    // The chat is under the sheet; its details never link back to it.
                    case .chat, .details: EmptyView()
                    }
                }
        }
        .presentationDetents([.large])
    }
}

extension EnvironmentValues {
    // The chat under a details sheet, so it reads nothing meanwhile and opens search only once the sheet has gone.
    @Entry var chatBehindDetails: String?
}
