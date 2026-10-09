import SwiftUI

/// The main window. Like the iPhone's root, the upgrade and key-recovery screens replace everything until they are
/// settled; otherwise a split view: chats in the sidebar, the open chat as the detail, and its details in an inspector.
struct MacRootView: View {
    @Bindable var model: AppModel
    @Bindable var window: MacWindowState

    var body: some View {
        Group {
            if model.upgradeState == .none, model.keyRecovery == nil {
                split
            } else if model.upgradeState != .none {
                UpgradeBlockingView(model: model)
            } else {
                KeyRecoveryView(model: model)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        #if DEBUG
        .modifier(MacDebugPresentation(window: window))
        .modifier(MacScenePhaseLog(window: "main"))
        .background(MacUnobtrusive.Anchor())
        #endif
    }

    private var split: some View {
        NavigationSplitView {
            MacChatList(model: model, window: window)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            detail
        }
        .id(model.accountID)
        .onChange(of: model.accountID) { _, _ in window.selection = nil; window.inspectorShown = false }
        .onChange(of: window.selection) { previous, _ in if let previous { model.closeChat(previous) } }
        // The window closed (the app keeps running): nothing is on screen to read.
        .onDisappear { if let chatID = window.selection { model.closeChat(chatID) } }
        .onChange(of: model.notificationRoute, initial: true) { _, route in
            guard let route else { return }
            model.consumeNotificationRoute(route.id)
            guard route.accountID == model.accountID else { return }
            window.showingAccount = false
            window.selection = route.chatID
        }
        .onChange(of: model.requestedRoute) { _, route in
            guard let route else { return }
            model.requestedRoute = nil
            switch route {
            case .chat(let chatID): window.selection = chatID
            case .details(let chatID), .encryption(let chatID), .groupDetails(let chatID):
                window.selection = chatID
                window.inspectorShown = true
            }
        }
        .onChange(of: model.signInRequested) { _, requested in
            guard requested else { return }
            model.signInRequested = false
            window.showingAccount = true
        }
        .sheet(isPresented: $window.showingAccount) {
            SignInView(model: model)
                .frame(minWidth: 460, idealWidth: 480, minHeight: 560, idealHeight: 620)
                .themedRoot()
        }
        .sheet(isPresented: $window.showingNewChat) {
            MacNewChatSheet(model: model) { chatID in
                window.showingNewChat = false
                window.selection = chatID
            }
            .themedRoot()
        }
        .sheet(isPresented: $window.reviewingOwnDevices) {
            OwnDeviceReviewSheet(model: model)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
                .themedRoot()
        }
    }

    @ViewBuilder private var detail: some View {
        if let chatID = window.selection {
            MacConversationView(model: model, chatID: chatID) { window.inspectorShown = true }
                .id(chatID)
                .inspector(isPresented: $window.inspectorShown) {
                    MacChatInspector(model: model, chatID: chatID)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { window.inspectorShown.toggle() } label: { Label("Chat Details", systemImage: "info.circle") }
                            .help("Show or hide the chat's details")
                    }
                }
        } else {
            ContentUnavailableView {
                Label(model.chats.isEmpty ? "No conversations yet" : "No chat selected", systemImage: "bubble.left.and.bubble.right")
            } description: {
                if model.hasLoadedChats, model.chats.isEmpty {
                    Text(model.accountID.isEmpty
                         ? "Sign in to your XMPP account, or explore sample conversations."
                         : "Start a conversation with New Chat (⌘N).")
                } else {
                    Text("Choose a chat in the sidebar.")
                }
            } actions: {
                if model.hasLoadedChats, model.chats.isEmpty, model.accountID.isEmpty {
                    Button("Sign In…") { window.showingAccount = true }
                        .buttonStyle(.borderedProminent)
                    Button("Explore Sample Conversations") { Task { await model.loadDemo() } }
                }
            }
        }
    }
}

/// Chat details in the inspector, with the pages it links to (devices and encryption, group details) pushed inside it.
struct MacChatInspector: View {
    @Bindable var model: AppModel
    let chatID: String

    var body: some View {
        NavigationStack {
            ChatDetailsView(model: model, chatID: chatID)
                .navigationDestination(for: ChatRoute.self) { route in
                    switch route {
                    case .encryption(let chatID): EncryptionDetailsView(model: model, chatID: chatID)
                    case .groupDetails(let room): GroupDetailsView(model: model, room: room)
                    // The conversation is already the detail column; details never link back to it.
                    case .chat, .details: EmptyView()
                    }
                }
        }
        .labelStyle(.listRow)
    }
}
