import SwiftUI

/// The main window's sheets, alerts and routes, from a zero-sized view of their own in the window
/// (`MacShellController`), so following them never reruns a pane. The error alert shows over the split view or the
/// screen that replaces it; the chats' own (`MacChatsPresenter`) only with the split view, as they open, choose and
/// change chats.
struct MacWindowPresenter: View {
    @Bindable var model: AppModel
    let window: MacWindowState

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .alert("Something needs attention", isPresented: Binding(
                get: { model.error != nil }, set: { if !$0 { model.error = nil } }
            )) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .background { if !model.showsBlockingScreen { MacChatsPresenter(model: model, window: window) } }
            #if DEBUG
            .modifier(MacDebugPresentation(model: model, window: window))
            .background(MacUnobtrusive.Anchor())
            #endif
    }
}

/// The split view's sheets, confirmations and routes. Gone while the transfer, upgrade or key-recovery screen replaces
/// it: a sheet open then closes, and a notification's route waits until the chats are back.
private struct MacChatsPresenter: View {
    @Bindable var model: AppModel
    @Bindable var window: MacWindowState

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            // A Block or Report from the sidebar's menu or the Chat menu; here, so it shows with the sidebar collapsed too.
            .blockConfirmation(model: model, request: $window.blockRequest)
            .onChange(of: model.accountID) { _, _ in
                window.selection = nil
                window.inspectorShown = false
                window.chatSearch = ""
            }
            .onChange(of: window.selection) { previous, selection in
                if let previous { model.closeChat(previous) }
                // Pages of the chat just left; a route that also chose the new chat has already pushed its own.
                window.inspectorPath.removeAll { !Self.route($0, isFor: selection) }
            }
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
                    window.inspectorPath = route == .details(chatID) ? [] : [route]
                }
            }
            .onChange(of: model.signInRequested) { _, requested in
                guard requested else { return }
                model.signInRequested = false
                window.showingAccount = true
            }
            .alert("Transfer restored", isPresented: $model.transferRestored) {
                Button("OK") {}
            } message: {
                Text("Your chats are here. To finish the move, open Haus XMPP on the other device and choose Delete Data.")
            }
            .sheet(isPresented: $window.showingAccount) {
                SignInView(model: model)
                    .frame(minWidth: 440, idealWidth: 460, minHeight: 460, idealHeight: 520)
                    .themedRoot()
            }
            .sheet(isPresented: $window.showingRestore) { RestoreTransferView(model: model).themedRoot() }
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

    private static func route(_ route: ChatRoute, isFor chatID: String?) -> Bool {
        switch route {
        case .chat(let id), .details(let id), .encryption(let id), .groupDetails(let id): id == chatID
        }
    }
}

/// The split view's content: the open chat, or what to do with none open.
struct MacDetailPane: View {
    let model: AppModel
    let window: MacWindowState

    var body: some View {
        if let chatID = window.selection {
            MacConversationView(model: model, chatID: chatID)
                .id(chatID)
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
                    if model.canRestoreTransfer { Button("Restore from a Transfer…") { window.showingRestore = true } }
                }
            }
            .navigationTitle("Haus XMPP")
        }
    }
}

/// The inspector's pane: the open chat's details, from when the column first shows them until another chat is chosen
/// (`MacInspectorController`). Kept in the closed column, they open again with nothing to build.
struct MacInspectorPane: View {
    let model: AppModel
    @Bindable var window: MacWindowState
    let presence: MacColumnPresence

    var body: some View {
        if let chatID = window.selection, presence.onScreen || presence.shownChat == chatID {
            MacChatInspector(model: model, chatID: chatID, path: $window.inspectorPath)
                .id(chatID)
        }
    }
}

/// Chat details in the inspector, with the pages it links to (devices and encryption, group details) pushed inside it.
struct MacChatInspector: View {
    @Bindable var model: AppModel
    let chatID: String
    @Binding var path: [ChatRoute]

    var body: some View {
        NavigationStack(path: $path) {
            ChatDetailsView(model: model, chatID: chatID)
                .navigationDestination(for: ChatRoute.self) { route in
                    switch route {
                    case .encryption(let chatID): EncryptionDetailsView(model: model, chatID: chatID).macInspectorPage("Devices & Encryption")
                    case .groupDetails(let room): GroupDetailsView(model: model, room: room).macInspectorPage("Group details")
                    // The conversation is already the split view's content; details never link back to it.
                    case .chat, .details: EmptyView()
                    }
                }
        }
        .labelStyle(.listRow)
    }
}

/// A page pushed inside the inspector: its title and a Back button at the top of the inspector. The system's Back
/// button would sit in the window toolbar's leading area, beside the conversation's title, where it reads as the
/// conversation's own.
struct MacInspectorPage: ViewModifier {
    let title: String
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden()
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless)
                        .help("Back")
                    Text(title).font(.headline).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
    }
}

extension View {
    func macInspectorPage(_ title: String) -> some View { modifier(MacInspectorPage(title: title)) }
}
